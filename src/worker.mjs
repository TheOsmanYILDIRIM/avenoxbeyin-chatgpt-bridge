import {
  readFile, readdir, stat, realpath, writeFile, mkdtemp, rm, rename, chmod
} from 'node:fs/promises';
import {
  resolve, relative, basename, isAbsolute, extname, sep, dirname, join
} from 'node:path';
import { tmpdir } from 'node:os';
import { createHash } from 'node:crypto';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';
import { CAPABILITIES, CAPABILITY_MAP, BRIDGE_API_VERSION } from './capabilities.mjs';

const execFileAsync = promisify(execFile);
const HERE = dirname(fileURLToPath(import.meta.url));
const BRIDGE_SKILL_PATH = resolve(HERE, '..', 'skills', 'avenox-chatgpt-bridge', 'SKILL.md');
const RECEIPT_HARNESSES = new Set(['codex','claude','antigravity','hermes','opencode','omp']);
const JEV_FEATURES = new Set(['context','review','answer','auto_context']);
const REMOTE_PROTECTED_BASENAMES = new Set([
  'Core.md','Soul.md','Kurallar.md','Last-Session.md','Threads.md','Journal.md',
  'AGENTS.md','CLAUDE.md'
]);

export class Bridge {
  constructor(config) {
    this.c = config;
    this.token = null;
    this._runtimeCapabilities = null;
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
    this.token = (await r.json()).access_token;
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
      bridge_api_version: BRIDGE_API_VERSION,
      vault_root: this.c.vault_root,
      poll_interval_ms: this.c.poll_interval_ms,
      operations: await this.runtimeCapabilities()
    };
  }

  async runtimeCapabilities() {
    if (this._runtimeCapabilities) return this._runtimeCapabilities;

    const needsCli = new Map([
      ['brain_context','context'],
      ['brain_note_create','note-create'],
      ['brain_task_create','task-create'],
      ['brain_task_update','task-update'],
      ['brain_receipt','receipt'],
      ['brain_sync','sync'],
      ['brain_history','history'],
      ['brain_skill_sync','skill-sync'],
      ['brain_companion_compact','companion-compact'],
      ['brain_preferences_get','preferences'],
      ['brain_preferences_update','preferences'],
      ['brain_doctor','doctor'],
      ['brain_update_check','update'],
      ['brain_update','update'],
      ['brain_update_dismiss','update'],
      ['brain_rollback','rollback'],
      ['brain_recover','recover'],
      ['brain_jev_status','jev'],
      ['brain_jev_config','jev'],
      ['brain_jev_memory','jev-memory']
    ]);

    const cli = new Set();
    const py = this.pythonInvocation();
    try {
      const { stdout, stderr } = await execFileAsync(
        py.cmd,
        [...py.prefix, resolve(this.c.vault_root, 'beyin.py'), '-h'],
        {
          cwd:this.c.vault_root,
          windowsHide:true,
          maxBuffer:2 * 1024 * 1024,
          timeout:Number(this.c.capability_probe_timeout_ms || 3000),
          killSignal:'SIGKILL'
        }
      );
      const match = `${stdout || ''}\n${stderr || ''}`.match(/\{([^}]+)\}/);
      if (match) {
        for (const name of match[1].split(',').map(x => x.trim()).filter(Boolean)) cli.add(name);
      }
    } catch {}

    // Installed V3 dispatches update/rollback/recover before the normal CLI parser,
    // so they may be absent from top-level -h. Probe only missing commands with
    // --help; argparse exits before executing the command, so this has no side effect.
    const missing = [...new Set(needsCli.values())].filter(name => !cli.has(name));
    for (const name of missing) {
      if (await this.cliCommandExists(name)) cli.add(name);
    }

    this._runtimeCapabilities = CAPABILITIES.map(cap => {
      const cliName = needsCli.get(cap.name);
      return { ...cap, available: cliName ? cli.has(cliName) : true };
    });
    return this._runtimeCapabilities;
  }

  async cliCommandExists(name) {
    const py = this.pythonInvocation();
    try {
      await execFileAsync(
        py.cmd,
        [...py.prefix, resolve(this.c.vault_root, 'beyin.py'), name, '--help'],
        {
          cwd:this.c.vault_root,
          windowsHide:true,
          maxBuffer:2 * 1024 * 1024,
          timeout:Number(this.c.capability_probe_timeout_ms || 3000),
          killSignal:'SIGKILL'
        }
      );
      return true;
    } catch {
      return false;
    }
  }

  async supportedCapabilityMap() {
    const caps = await this.runtimeCapabilities();
    return new Map(caps.filter(x => x.available !== false).map(x => [x.name, x]));
  }

  async run() {
    for (;;) {
      try {
        const cmd = await this.rpc('claim_next_brain_command_v2');
        if (cmd) await this.handle(cmd);
      } catch (e) {
        console.error('[bridge]', e.message);
      }
      await new Promise(r => setTimeout(r, this.c.poll_interval_ms || 5000));
    }
  }

  async handle(cmd) {
    const timeoutMs = Number(this.c.operation_timeout_ms || 15000);
    let outcome;
    try {
      outcome = await withTimeout((async () => {
        const supported = await this.supportedCapabilityMap();
        if (!supported.has(cmd.operation)) {
          const caps = await this.runtimeCapabilities();
          return {
            terminal_status: 'failed',
            result: null,
            error: {
              error: 'invalid_operation',
              requested_operation: cmd.operation,
              allowed_operations: caps.filter(x => x.available !== false).map(x => x.name),
              unavailable_operations: caps.filter(x => x.available === false).map(x => ({
                name: x.name,
                reason: x.unavailable_reason
              }))
            },
            projection: {}
          };
        }

        const result = await this.execute(cmd.operation, cmd.payload || {});
        return {
          terminal_status: 'completed',
          result,
          error: null,
          projection: this.project(cmd.operation, result)
        };
      })(), timeoutMs, cmd.operation);
    } catch (e) {
      const error = {
        error: e.code || 'operation_failed',
        message: e.message
      };
      if (e.brain_error) error.brain_error = e.brain_error;
      outcome = {
        terminal_status: e.code === 'conflict' ? 'conflict' : 'failed',
        result: null,
        error,
        projection: {}
      };
    }

    await this.finish(
      cmd,
      outcome.terminal_status,
      outcome.result,
      outcome.error,
      outcome.projection
    );
  }

  async finish(cmd, status, result, error, p = {}) {
    return this.rpc('finish_brain_command_v2', {
      p: {
        id: cmd.id,
        status,
        result,
        error,
        response_text: p.text ?? null,
        source_refs: p.refs ?? [],
        response_kind: p.kind ?? null
      }
    });
  }

  pythonInvocation() {
    if (this.c.python) return { cmd: this.c.python, prefix: [] };
    if (process.platform === 'win32') return { cmd: 'py', prefix: ['-3'] };
    return { cmd: 'python3', prefix: [] };
  }

  beyinArgs(sub, args = []) {
    return [resolve(this.c.vault_root, 'beyin.py'), sub, ...args, '--json'];
  }

  async runBeyin(sub, args = []) {
    const py = this.pythonInvocation();
    try {
      const { stdout } = await execFileAsync(
        py.cmd,
        [...py.prefix, ...this.beyinArgs(sub, args)],
        {
          cwd: this.c.vault_root,
          windowsHide: true,
          maxBuffer: 16 * 1024 * 1024
        }
      );
      return JSON.parse(stdout);
    } catch (e) {
      throw parseBeyinFailure(e);
    }
  }

  async withTempJson(value, fn) {
    const dir = await mkdtemp(join(tmpdir(), 'avenox-bridge-'));
    const path = join(dir, 'payload.json');
    try {
      await writeFile(path, JSON.stringify(value), { encoding: 'utf8', mode: 0o600 });
      return await fn(path);
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  }

  async execute(op, payload) {
    switch (op) {
      case 'brain_context': {
        const args = [requiredString(payload.query, 'query')];
        if (payload.project) args.push('--project', requiredString(payload.project, 'project'));
        if (payload.limit != null) args.push('--limit', String(intInRange(payload.limit, 1, 100, 'limit')));
        if (payload.budget_chars != null) args.push('--budget-chars', String(intInRange(payload.budget_chars, 1000, 100000, 'budget_chars')));
        if (payload.jev === true) args.push('--jev');
        if (payload.audience != null) {
          if (payload.audience !== 'public') throw new Error('audience must be public');
          args.push('--audience', 'public');
        }
        return this.runBeyin('context', args);
      }

      case 'brain_source_get':
        return this.sourceGet(payload.source);

      case 'brain_source_update':
        return this.sourceUpdate(payload);

      case 'brain_note_create':
        return this.withTempJson(validateCreatePayload(payload), p => this.runBeyin('note-create', ['--file', p]));

      case 'brain_task_create':
        return this.withTempJson(validateCreatePayload(payload), p => this.runBeyin('task-create', ['--file', p]));

      case 'brain_task_update': {
        const body = {
          id: requiredString(payload.id, 'id'),
          expected_revision: intInRange(payload.expected_revision, 1, Number.MAX_SAFE_INTEGER, 'expected_revision'),
          changes: requiredObject(payload.changes, 'changes')
        };
        return this.withTempJson(body, p => this.runBeyin('task-update', ['--file', p]));
      }

      case 'brain_receipt': {
        const harness = payload.harness || 'codex';
        if (!RECEIPT_HARNESSES.has(harness)) throw new Error('invalid receipt harness');
        const body = {
          event_id: requiredString(payload.event_id, 'event_id'),
          summary: requiredString(payload.summary, 'summary'),
          refs: requiredStringArray(payload.refs, 'refs')
        };
        if (payload.session != null) body.session = requiredString(payload.session, 'session');
        return this.withTempJson(body, p => this.runBeyin('receipt', ['--file', p, '--harness', harness]));
      }

      case 'brain_sync':
        return this.runBeyin('sync');

      case 'brain_history':
        return this.runBeyin('history', [requiredString(payload.id, 'id')]);

      case 'brain_skill_sync':
        return this.runBeyin('skill-sync');

      case 'brain_companion_compact':
        return this.runBeyin('companion-compact', payload.dry_run === true ? ['--dry-run'] : []);

      case 'brain_preferences_get':
        return this.runBeyin('preferences');

      case 'brain_preferences_update':
        return this.runBeyin('preferences', preferenceArgs(payload));

      case 'brain_doctor':
        return this.runBeyin('doctor');

      case 'brain_update_check':
        return this.runBeyin('update', ['--check', '--metadata-only']);

      case 'brain_update':
        return this.runBeyin('update');

      case 'brain_update_dismiss':
        return this.runBeyin('update', ['--dismiss', requiredVersion(payload.version)]);

      case 'brain_rollback': {
        const rollback = await this.runBeyin('rollback');
        const doctor = await this.runBeyin('doctor');
        return { rollback, doctor };
      }

      case 'brain_recover':
        return this.runBeyin('recover');

      case 'brain_jev_status':
        return this.runBeyin('jev', payload.check === true ? ['status', '--check'] : ['status']);

      case 'brain_jev_config':
        return this.runBeyin('jev', jevArgs(payload));

      case 'brain_jev_memory':
        return this.withTempJson(requiredObject(payload.proposal, 'proposal'), p =>
          this.runBeyin('jev-memory', ['--project', requiredString(payload.project, 'project'), '--file', p])
        );

      case 'avenox_bootstrap':
        return this.bootstrap(payload.task || '');

      case 'avenox_skill_get':
        return this.skillGet(payload.name);

      default:
        throw new Error(`unsupported operation: ${op}`);
    }
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

  async bridgeSkill() {
    const content = await readFile(BRIDGE_SKILL_PATH, 'utf8');
    const description = (content.match(/^description:\s*(.+)$/m) || [])[1] || '';
    return {
      name: 'avenox-chatgpt-bridge',
      description,
      sha256: sha(content),
      content,
      source: 'skills/avenox-chatgpt-bridge/SKILL.md'
    };
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
      .filter(e => e.isDirectory()).map(e => e.name).sort();
    const manifest = [];
    for (const name of names) {
      try {
        const s = await this.skillGet(name);
        manifest.push({ name: s.name, description: s.description, sha256: s.sha256 });
      } catch {}
    }
    const bridgeSkill = await this.bridgeSkill();
    const core = await this.skillGet('beyin');
    let version = 'unknown';
    try {
      version = (await readFile(resolve(this.c.vault_root, '.beyin-version'), 'utf8')).trim();
    } catch {}
    return {
      task,
      brain_version: version,
      bridge_api_version: BRIDGE_API_VERSION,
      bridge_skill: bridgeSkill,
      bridge_capabilities: await this.runtimeCapabilities(),
      core_skill: core,
      skills_manifest: manifest
    };
  }

  async safeMarkdownPath(source) {
    if (
      typeof source !== 'string' || !source || source.includes('\0') ||
      isAbsolute(source) || source.split(/[\\/]/).includes('..') ||
      extname(source).toLowerCase() !== '.md'
    ) throw new Error('invalid source');

    const root = await realpath(this.c.vault_root);
    let path;
    if (source.includes('/') || source.includes('\\')) {
      path = resolve(root, source);
    } else {
      const matches = (await this.walk(root)).filter(
        p => basename(p) === source && extname(p).toLowerCase() === '.md'
      );
      if (matches.length === 0) throw coded('source_not_found', 'source not found');
      if (matches.length > 1) throw coded(
        'conflict',
        `source ambiguous: ${matches.map(p => relative(root, p)).join(', ')}`
      );
      path = matches[0];
    }
    const real = await realpath(path);
    if (!(real === root || real.startsWith(root + sep))) throw new Error('source escapes vault');
    return { root, real };
  }

  async sourceGet(source) {
    const { root, real } = await this.safeMarkdownPath(source);
    const s = await stat(real);
    if (s.size > (this.c.max_source_bytes || 262144)) throw new Error('source too large');
    const content = await readFile(real, 'utf8');
    const rel = relative(root, real).split(sep).join('/');
    assertRemoteSourceAllowed(rel, content);
    return {
      source: rel,
      size_bytes: s.size,
      sha256: sha(content),
      content
    };
  }

  async sourceUpdate(payload) {
    const source = requiredString(payload.source, 'source');
    const expected = requiredSha(payload.expected_sha256);
    const content = requiredStringAllowEmpty(payload.content, 'content');
    const { root, real } = await this.safeMarkdownPath(source);
    const current = await readFile(real, 'utf8');
    const rel = relative(root, real).split(sep).join('/');
    assertRemoteSourceAllowed(rel, current);
    if (sha(current) !== expected) throw coded('conflict', 'source hash changed');
    if (/(^|\/)tasks\//i.test(rel) || /^---[\s\S]{0,4096}?^kind:\s*task\s*$/mi.test(current)) {
      throw new Error('task sources must use brain_task_update');
    }

    const s = await stat(real);
    const temp = resolve(dirname(real), `.avenox-bridge-${process.pid}-${Date.now()}.tmp`);
    await writeFile(temp, content, { encoding: 'utf8' });
    await chmod(temp, s.mode);
    await rename(temp, real);

    try {
      const sync = await this.runBeyin('sync');
      return {
        source: rel,
        previous_sha256: expected,
        sha256: sha(content),
        size_bytes: Buffer.byteLength(content, 'utf8'),
        sync
      };
    } catch (e) {
      const restore = resolve(dirname(real), `.avenox-bridge-restore-${process.pid}-${Date.now()}.tmp`);
      await writeFile(restore, current, { encoding: 'utf8' });
      await chmod(restore, s.mode);
      await rename(restore, real);
      try { await this.runBeyin('sync'); } catch {}
      throw e;
    }
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

    if (op === 'avenox_skill_get') return { kind:'skill', refs:[result.source], text:result.content };
    if (op === 'brain_source_get') return { kind:'source', refs:[result.source], text:result.content };

    if (op === 'avenox_bootstrap') {
      return {
        kind: 'bootstrap',
        refs: [result.bridge_skill.source, result.core_skill.source],
        text:
          `# Avenox Bootstrap\n- Brain: ${result.brain_version}\n- Bridge API: ${result.bridge_api_version}\n- Skills: ${result.skills_manifest.length}\n\n` +
          `## Bridge Skill\n${result.bridge_skill.content}\n\n` +
          `## Bridge Capabilities\n${JSON.stringify(result.bridge_capabilities, null, 2)}\n\n` +
          `## Core Skill\n${result.core_skill.content}\n\n## Skills Manifest\n` +
          result.skills_manifest.map(
            s => `- **${s.name}** (${s.sha256.slice(0,12)}): ${s.description}`
          ).join('\n')
      };
    }

    if (op === 'brain_doctor' || op === 'brain_preferences_get' || op === 'brain_history' ||
        op === 'brain_update_check' || op === 'brain_jev_status') {
      return { kind:'doctor', refs:[], text:JSON.stringify(result, null, 2) };
    }

    return { kind:'mutation', refs:extractRefs(result), text:JSON.stringify(result, null, 2) };
  }
}

function extractRefs(value) {
  const refs = new Set();
  const walk = x => {
    if (!x) return;
    if (Array.isArray(x)) return x.forEach(walk);
    if (typeof x !== 'object') return;
    for (const [k,v] of Object.entries(x)) {
      if (k === 'source' && typeof v === 'string') refs.add(v);
      else if ((k === 'refs' || k === 'evidence_refs') && Array.isArray(v)) {
        v.filter(y => typeof y === 'string').forEach(y => refs.add(y));
      }
      walk(v);
    }
  };
  walk(value);
  return [...refs];
}

function assertRemoteSourceAllowed(source, content) {
  const reason = remoteSourceBlockReason(source, content);
  if (reason) throw coded('access_denied_private_source', 'source is not available to remote clients');
}

function remoteSourceBlockReason(source, content) {
  if (REMOTE_PROTECTED_BASENAMES.has(basename(source))) return 'protected_name';
  const fm = frontmatter(content);
  if (!fm) return null;
  if (/^\s*visibility\s*:\s*['"]?private['"]?\s*$/im.test(fm) ||
      /["']visibility["']\s*:\s*["']private["']/i.test(fm)) return 'private_visibility';
  if (/^\s*remote_allowed\s*:\s*false\s*$/im.test(fm) ||
      /["']remote_allowed["']\s*:\s*false\b/i.test(fm)) return 'remote_disabled';
  const yamlSensitivity = fm.match(/^\s*sensitivity\s*:\s*['"]?([^'"\s]+)['"]?\s*$/im);
  const jsonSensitivity = fm.match(/["']sensitivity["']\s*:\s*["']([^"']+)["']/i);
  const sensitivity = (yamlSensitivity?.[1] || jsonSensitivity?.[1] || '').toLowerCase();
  if (sensitivity && !['public','internal','normal'].includes(sensitivity)) return 'sensitive';
  return null;
}

function frontmatter(content) {
  if (typeof content !== 'string' || !content.startsWith('---')) return '';
  const end = content.indexOf('\n---', 3);
  return end < 0 ? '' : content.slice(3, end);
}

function parseBeyinFailure(error) {
  const detail = lastJsonObject(error?.stderr) || lastJsonObject(error?.stdout);
  if (!detail) return coded('beyin_process_error', error?.message || 'beyin command failed');

  const brainError = String(detail.error || 'BeyinError');
  const message = String(detail.message || brainError);
  const combined = `${brainError} ${message}`;
  const code = /conflict/i.test(combined)
    ? 'conflict'
    : brainError === 'ValueError'
      ? 'validation_error'
      : 'beyin_error';
  const result = coded(code, message);
  result.brain_error = brainError;
  return result;
}

function lastJsonObject(value) {
  const lines = String(value || '').trim().split(/\r?\n/).reverse();
  for (const line of lines) {
    try {
      const parsed = JSON.parse(line);
      if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) return parsed;
    } catch {}
  }
  return null;
}

function validateCreatePayload(payload) {
  return {
    source: requiredString(payload.source, 'source'),
    text: requiredStringAllowEmpty(payload.text, 'text'),
    metadata: requiredObject(payload.metadata, 'metadata')
  };
}

function preferenceArgs(p) {
  const args = [];
  const allowed = new Set([
    'profile','interval_minutes','context_mode','context_chars','auto_sync',
    'secret_filter','last_session_chars','threads_chars','update_notifications'
  ]);
  for (const k of Object.keys(p)) if (!allowed.has(k)) throw new Error(`unsupported preference: ${k}`);
  if (p.profile != null) {
    if (!['normal','economical','manual'].includes(p.profile)) throw new Error('invalid profile');
    args.push('--profile', p.profile);
  }
  if (p.interval_minutes != null) args.push('--interval-minutes', String(intInRange(p.interval_minutes,0,1440,'interval_minutes')));
  if (p.context_mode != null) {
    if (!['turn','session','off'].includes(p.context_mode)) throw new Error('invalid context_mode');
    args.push('--context-mode', p.context_mode);
  }
  if (p.context_chars != null) args.push('--context-chars', String(intInRange(p.context_chars,1000,12000,'context_chars')));
  if (p.auto_sync != null) args.push('--auto-sync', p.auto_sync ? 'on' : 'off');
  if (p.secret_filter != null) args.push('--secret-filter', p.secret_filter ? 'on' : 'off');
  if (p.last_session_chars != null) args.push('--last-session-chars', String(intInRange(p.last_session_chars,0,200000,'last_session_chars')));
  if (p.threads_chars != null) args.push('--threads-chars', String(intInRange(p.threads_chars,0,200000,'threads_chars')));
  if (p.update_notifications != null) args.push('--update-notifications', p.update_notifications ? 'on' : 'off');
  if (args.length === 0) throw new Error('no preference changes supplied');
  return args;
}

function jevArgs(p) {
  if (!['off','shadow','on'].includes(p.mode)) throw new Error('invalid Jev mode');
  const args = [p.mode];
  for (const name of p.enable || []) {
    if (!JEV_FEATURES.has(name)) throw new Error('invalid Jev enable feature');
    args.push('--enable', name);
  }
  for (const name of p.disable || []) {
    if (!JEV_FEATURES.has(name)) throw new Error('invalid Jev disable feature');
    args.push('--disable', name);
  }
  if (p.provider != null) {
    if (!['typesafe','vercel','laya'].includes(p.provider)) throw new Error('invalid Jev provider');
    args.push('--provider', p.provider);
  }
  if (p.model != null) {
    if (!['multilingual','english'].includes(p.model)) throw new Error('invalid Laya model');
    args.push('--model', p.model);
  }
  if (p.base_url != null) {
    const u = new URL(p.base_url);
    if (!['127.0.0.1','[::1]','::1'].includes(u.hostname) || u.protocol !== 'http:') {
      throw new Error('Laya base_url must be loopback HTTP');
    }
    args.push('--base-url', p.base_url);
  }
  return args;
}

function requiredVersion(v) {
  const s = requiredString(v, 'version');
  if (!/^\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?$/.test(s)) throw new Error('invalid version');
  return s;
}
function requiredSha(v) {
  const s = requiredString(v, 'expected_sha256').toLowerCase();
  if (!/^[a-f0-9]{64}$/.test(s)) throw new Error('invalid sha256');
  return s;
}
function requiredString(v, name) {
  if (typeof v !== 'string' || !v.trim()) throw new Error(`${name} required`);
  return v;
}
function requiredStringAllowEmpty(v, name) {
  if (typeof v !== 'string') throw new Error(`${name} must be string`);
  return v;
}
function requiredObject(v, name) {
  if (!v || typeof v !== 'object' || Array.isArray(v)) throw new Error(`${name} must be object`);
  return v;
}
function requiredStringArray(v, name) {
  if (!Array.isArray(v) || v.some(x => typeof x !== 'string')) throw new Error(`${name} must be string array`);
  return v;
}
function intInRange(v, min, max, name) {
  if (!Number.isInteger(v) || v < min || v > max) throw new Error(`${name} out of range`);
  return v;
}
function coded(code, message) {
  const e = new Error(message);
  e.code = code;
  return e;
}
function withTimeout(promise, ms, operation) {
  let timer;
  return Promise.race([
    promise,
    new Promise((_, reject) => {
      timer = setTimeout(() => {
        reject(coded('operation_timeout', `${operation} exceeded ${ms}ms`));
      }, ms);
    })
  ]).finally(() => clearTimeout(timer));
}
function sha(value) {
  return createHash('sha256').update(value).digest('hex');
}
