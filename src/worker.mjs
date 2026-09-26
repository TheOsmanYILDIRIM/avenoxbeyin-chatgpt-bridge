import { readFile, readdir, stat, realpath } from 'node:fs/promises';
import { resolve, relative, basename, isAbsolute, extname, sep } from 'node:path';
import { createHash } from 'node:crypto';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);

const OPS = new Set([
  'brain_context','brain_note_create','brain_task_create','brain_task_update',
  'brain_receipt','brain_doctor','avenox_bootstrap','avenox_skill_get','brain_source_get'
]);

export class Bridge {
  constructor(config) {
    this.c = config;
    this.token = null;
  }

  async auth() {
    const password = process.env[this.c.worker_password_env];
    if (!password) throw new Error(`missing env ${this.c.worker_password_env}`);

    const r = await fetch(`${this.c.supabase_url}/auth/v1/token?grant_type=password`, {
      method: 'POST',
      headers: {
        apikey: this.c.supabase_publishable_key,
        'content-type': 'application/json'
      },
      body: JSON.stringify({ email: this.c.worker_email, password })
    });

    if (!r.ok) throw new Error(`auth failed ${r.status}`);
    const j = await r.json();
    this.token = j.access_token;
  }

  headers() {
    return {
      apikey: this.c.supabase_publishable_key,
      authorization: `Bearer ${this.token}`,
      'content-type': 'application/json'
    };
  }

  async rpc(name, body = {}) {
    if (!this.token) await this.auth();

    const r = await fetch(`${this.c.supabase_url}/rest/v1/rpc/${name}`, {
      method: 'POST',
      headers: this.headers(),
      body: JSON.stringify(body)
    });

    if (r.status === 401) {
      this.token = null;
      await this.auth();
      return this.rpc(name, body);
    }

    if (!r.ok) throw new Error(`${name} failed ${r.status}: ${await r.text()}`);
    const text = await r.text();
    return text ? JSON.parse(text) : null;
  }

  async doctor() {
    return {
      vault_root: this.c.vault_root,
      poll_interval_ms: this.c.poll_interval_ms,
      operations: [...OPS]
    };
  }

  async run() {
    for (;;) {
      try {
        const cmd = await this.rpc('claim_next_brain_command');
        if (cmd) await this.handle(cmd);
      } catch (e) {
        console.error('[bridge]', e.message);
      }
      await new Promise(r => setTimeout(r, this.c.poll_interval_ms || 5000));
    }
  }

  async handle(cmd) {
    if (!OPS.has(cmd.operation)) {
      return this.finish(cmd, 'failed', null, { message: 'unsupported operation' });
    }

    try {
      const result = await this.execute(cmd.operation, cmd.payload || {});
      const p = this.project(cmd.operation, result);
      await this.finish(cmd, 'completed', result, null, p);
    } catch (e) {
      await this.finish(cmd, 'failed', null, { name: e.name, message: e.message });
    }
  }

  async finish(cmd, status, result, error, p = {}) {
    return this.rpc('finish_brain_command', {
      p_id: cmd.id,
      p_status: status,
      p_result: result,
      p_error: error,
      p_response_text: p.text ?? null,
      p_source_refs: p.refs ?? [],
      p_response_kind: p.kind ?? null
    });
  }

  beyinArgs(sub, args = []) {
    return [resolve(this.c.vault_root, 'beyin.py'), sub, ...args, '--json'];
  }

  async runBeyin(sub, args = []) {
    const { stdout } = await execFileAsync(
      this.c.python || (process.platform === 'win32' ? 'py' : 'python3'),
      process.platform === 'win32' && (this.c.python || '') === '' ? ['-3', ...this.beyinArgs(sub, args)] : this.beyinArgs(sub, args),
      {
        cwd: this.c.vault_root,
        windowsHide: true,
        maxBuffer: 16 * 1024 * 1024
      }
    );
    return JSON.parse(stdout);
  }

  async execute(op, payload) {
    if (op === 'brain_context') {
      const args = [];
      if (payload.query) args.push(payload.query);
      if (payload.project) args.push('--project', payload.project);
      if (payload.limit) args.push('--limit', String(payload.limit));
      if (payload.budget_chars) args.push('--budget-chars', String(payload.budget_chars));
      return this.runBeyin('context', args);
    }

    if (op === 'brain_doctor') return this.runBeyin('doctor');
    if (op === 'avenox_bootstrap') return this.bootstrap(payload.task || '');
    if (op === 'avenox_skill_get') return this.skillGet(payload.name);
    if (op === 'brain_source_get') return this.sourceGet(payload.source);

    throw new Error(`${op} adapter not enabled in generic worker yet`);
  }

  async walk(dir, out = []) {
    for (const e of await readdir(dir, { withFileTypes: true })) {
      const p = resolve(dir, e.name);
      if (e.isSymbolicLink()) continue;
      if (e.isDirectory()) await this.walk(p, out);
      else out.push(p);
    }
    return out;
  }

  skillRoot() {
    return resolve(this.c.vault_root, '.agents', 'skills');
  }

  async skillGet(name) {
    if (!/^[A-Za-z0-9_-]+$/.test(name || '')) throw new Error('invalid skill name');

    const root = await realpath(this.skillRoot());
    const path = resolve(root, name, 'SKILL.md');
    const real = await realpath(path);

    if (!real.startsWith(root + sep)) throw new Error('skill escapes root');

    const content = await readFile(real, 'utf8');
    const description = (content.match(/^description:\s*(.+)$/m) || [])[1] || '';

    return {
      name,
      description,
      sha256: sha(content),
      content,
      source: relative(this.c.vault_root, real).split(sep).join('/')
    };
  }

  async bootstrap(task) {
    const root = this.skillRoot();
    const names = (await readdir(root, { withFileTypes: true }))
      .filter(e => e.isDirectory())
      .map(e => e.name)
      .sort();

    const manifest = [];
    for (const name of names) {
      try {
        const s = await this.skillGet(name);
        manifest.push({ name: s.name, description: s.description, sha256: s.sha256 });
      } catch {}
    }

    const core = await this.skillGet('beyin');
    let version = 'unknown';
    try {
      version = (await readFile(resolve(this.c.vault_root, '.beyin-version'), 'utf8')).trim();
    } catch {}

    return {
      task,
      brain_version: version,
      core_skill: core,
      skills_manifest: manifest
    };
  }

  async sourceGet(source) {
    if (
      typeof source !== 'string' ||
      !source ||
      source.includes('\0') ||
      isAbsolute(source) ||
      source.split(/[\\/]/).includes('..') ||
      extname(source).toLowerCase() !== '.md'
    ) {
      throw new Error('invalid source');
    }

    const root = await realpath(this.c.vault_root);
    let path;

    if (source.includes('/') || source.includes('\\')) {
      path = resolve(root, source);
    } else {
      const matches = (await this.walk(root)).filter(
        p => basename(p) === source && extname(p).toLowerCase() === '.md'
      );

      if (matches.length === 0) throw new Error('source not found');
      if (matches.length > 1) {
        throw new Error(
          `source ambiguous: ${matches.map(p => relative(root, p)).join(', ')}`
        );
      }
      path = matches[0];
    }

    const real = await realpath(path);
    if (!(real === root || real.startsWith(root + sep))) {
      throw new Error('source escapes vault');
    }

    const s = await stat(real);
    if (s.size > (this.c.max_source_bytes || 262144)) {
      throw new Error('source too large');
    }

    const content = await readFile(real, 'utf8');

    return {
      source: relative(root, real).split(sep).join('/'),
      size_bytes: s.size,
      sha256: sha(content),
      content
    };
  }

  project(op, result) {
    if (op === 'brain_context') {
      return {
        kind: 'context',
        refs: [...(result.citations || [])].map(x => x.source).filter(Boolean),
        text: (result.records || [])
          .map(r => `## ${r.source}\n\n${r.text || ''}`)
          .join('\n\n---\n\n') || 'Eşleşen kaynak bulunamadı.'
      };
    }

    if (op === 'brain_doctor') {
      return { kind: 'doctor', refs: [], text: JSON.stringify(result, null, 2) };
    }

    if (op === 'avenox_skill_get') {
      return { kind: 'skill', refs: [result.source], text: result.content };
    }

    if (op === 'brain_source_get') {
      return { kind: 'source', refs: [result.source], text: result.content };
    }

    if (op === 'avenox_bootstrap') {
      return {
        kind: 'bootstrap',
        refs: [result.core_skill.source],
        text:
          `# Avenox Bootstrap\n- Brain: ${result.brain_version}\n- Skills: ${result.skills_manifest.length}\n\n` +
          `## Core Skill\n${result.core_skill.content}\n\n## Skills Manifest\n` +
          result.skills_manifest
            .map(s => `- **${s.name}** (${s.sha256.slice(0, 12)}): ${s.description}`)
            .join('\n')
      };
    }

    return { kind: 'mutation', refs: [], text: JSON.stringify(result, null, 2) };
  }
}

function sha(value) {
  return createHash('sha256').update(value).digest('hex');
}
