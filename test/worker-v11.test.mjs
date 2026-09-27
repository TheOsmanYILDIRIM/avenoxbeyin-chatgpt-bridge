import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, rm, mkdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createHash } from 'node:crypto';
import { Bridge } from '../src/worker.mjs';

async function fixture(t, script = 'console.log(JSON.stringify({status:"ok"}))') {
  const vault = await mkdtemp(join(tmpdir(), 'avenox-bridge-v11-test-'));
  t.after(() => rm(vault, { recursive:true, force:true }));
  await writeFile(join(vault, 'beyin.py'), script, 'utf8');
  const bridge = new Bridge({
    vault_root: vault,
    python: process.execPath,
    max_source_bytes: 262144,
    max_vault_file_bytes: 1048576,
    poll_interval_ms: 5
  });
  return { vault, bridge };
}

function sha(text) {
  return createHash('sha256').update(text).digest('hex');
}

test('trusted vault can read companion content while generic source gate stays conservative', async t => {
  const { vault, bridge } = await fixture(t);
  const body = '# Threads\n\nOpen work';
  await writeFile(join(vault, 'Threads.md'), body);

  await assert.rejects(
    () => bridge.sourceGet('Threads.md'),
    error => error?.code === 'access_denied_private_source'
  );

  const full = await bridge.vaultGet('Threads.md');
  assert.equal(full.content, body);
  assert.equal(full.writable, true);
});

test('trusted vault still blocks credential/runtime paths', async t => {
  const { vault, bridge } = await fixture(t);
  await writeFile(join(vault, '.env'), 'SECRET=canary');
  await writeFile(join(vault, 'credentials.json'), '{"token":"canary"}');

  for (const source of ['.env', 'credentials.json']) {
    await assert.rejects(
      () => bridge.vaultGet(source),
      error => error?.code === 'vault_access_denied'
    );
  }
});

test('trusted vault update keeps CAS, sync rollback boundary and task revision rule', async t => {
  const { vault, bridge } = await fixture(t);
  const current = '# Last Session\nold';
  const next = '# Last Session\nnew';
  await writeFile(join(vault, 'Last-Session.md'), current);

  const updated = await bridge.vaultUpdate({
    source:'Last-Session.md',
    expected_sha256:sha(current),
    content:next
  });
  assert.equal(updated.previous_sha256, sha(current));
  assert.equal(updated.sha256, sha(next));
  assert.equal(updated.sync.status, 'ok');

  await assert.rejects(
    () => bridge.vaultUpdate({
      source:'Last-Session.md',
      expected_sha256:sha(current),
      content:'stale'
    }),
    error => error?.code === 'conflict'
  );

  await mkdir(join(vault, 'tasks'), { recursive:true });
  const task = '---\nkind: task\nrevision: 1\n---\nwork';
  await writeFile(join(vault, 'tasks', 'one.md'), task);
  await assert.rejects(
    () => bridge.vaultUpdate({
      source:'tasks/one.md',
      expected_sha256:sha(task),
      content:task + '\nchanged'
    }),
    /task sources must use brain_task_update/
  );
});

test('vault find discovers files by path substring without exposing denied paths', async t => {
  const { vault, bridge } = await fixture(t);
  await mkdir(join(vault, '10-Projects'), { recursive:true });
  await writeFile(join(vault, '10-Projects', 'StudyTracker.md'), '# Study');
  await writeFile(join(vault, '10-Projects', 'other.md'), '# Other');
  await writeFile(join(vault, '.env'), 'STUDYTRACKER_SECRET=1');

  const result = await bridge.vaultFind({ query:'studytracker', path:'.' });
  assert.deepEqual(result.matches.map(x => x.source), ['10-Projects/StudyTracker.md']);
});

test('vault search is literal, bounded and skips denied or binary files', async t => {
  const { vault, bridge } = await fixture(t);
  await mkdir(join(vault, 'notes'), { recursive:true });
  await writeFile(join(vault, 'notes', 'a.md'), 'alpha\nNeedle value\nneedle again\nomega\n');
  await writeFile(join(vault, 'notes', 'b.md'), 'regex .* is literal here\n');
  await writeFile(join(vault, '.env'), 'needle=secret\n');
  await writeFile(join(vault, 'notes', 'binary.dat'), Buffer.from([0,1,2,3]));

  const insensitive = await bridge.vaultSearch({
    query:'needle',
    path:'notes',
    max_results:10,
    max_matches_per_file:10
  });
  assert.deepEqual(insensitive.matches.map(x => [x.source,x.line]), [
    ['notes/a.md',2],
    ['notes/a.md',3]
  ]);

  const literal = await bridge.vaultSearch({
    query:'.*',
    path:'notes',
    case_sensitive:true,
    extensions:['.md']
  });
  assert.equal(literal.matches.length, 1);
  assert.equal(literal.matches[0].source, 'notes/b.md');
});

test('vault ranged read returns exact bounded lines and whole-file sha', async t => {
  const { vault, bridge } = await fixture(t);
  const body = 'one\ntwo\nthree\nfour\nfive';
  await writeFile(join(vault, 'sample.md'), body);

  const result = await bridge.vaultReadRange({
    source:'sample.md',
    start_line:2,
    end_line:4
  });
  assert.equal(result.content, 'two\nthree\nfour');
  assert.equal(result.total_lines, 5);
  assert.equal(result.start_line, 2);
  assert.equal(result.end_line, 4);
  assert.equal(result.sha256, sha(body));

  await assert.rejects(
    () => bridge.vaultReadRange({ source:'sample.md', start_line:1, end_line:501 }),
    /exceeds 500 lines/
  );
});

test('transport contract requires schema v11 trusted vault transport', async t => {
  const { bridge } = await fixture(t);
  bridge.rpc = async name => {
    assert.equal(name, 'bridge_transport_contract');
    return {
      schema_version: 11,
      claim_rpc: 'claim_dynamic',
      finish_rpc: 'finish_dynamic',
      command_terminal_statuses: ['completed','failed','conflict'],
      vault_transport: 'trusted_supabase_queue'
    };
  };

  const contract = await bridge.transportContract();
  assert.equal(contract.schema_version, 11);
  assert.equal(contract.vault_transport, 'trusted_supabase_queue');
});

test('transport contract rejects old or mismatched vault transport', async t => {
  const { bridge } = await fixture(t);

  bridge.rpc = async () => ({
    schema_version: 10,
    claim_rpc: 'claim_dynamic',
    finish_rpc: 'finish_dynamic',
    vault_transport: 'trusted_supabase_queue'
  });
  await assert.rejects(
    () => bridge.transportContract(),
    error => error?.code === 'transport_schema_mismatch'
  );

  bridge._transportContract = null;
  bridge.rpc = async () => ({
    schema_version: 11,
    claim_rpc: 'claim_dynamic',
    finish_rpc: 'finish_dynamic',
    vault_transport: 'other'
  });
  await assert.rejects(
    () => bridge.transportContract(),
    error => error?.code === 'transport_contract_invalid'
  );
});

test('claim and finish use live RPC names', async t => {
  const { bridge } = await fixture(t);
  const calls = [];
  bridge._transportContract = {
    schema_version: 11,
    claim_rpc: 'claim_dynamic',
    finish_rpc: 'finish_dynamic',
    vault_transport: 'trusted_supabase_queue'
  };
  bridge.rpc = async (name, body = {}) => {
    calls.push({ name, body });
    if (name === 'claim_dynamic') return { id:'cmd-1', operation:'brain_preferences_get', payload:{} };
    if (name === 'finish_dynamic') return { ok:true };
    throw new Error('unexpected rpc ' + name);
  };

  const cmd = await bridge.claimNext();
  assert.equal(cmd.id, 'cmd-1');
  await bridge.finish(cmd, 'completed', { status:'ok' }, null, {
    kind:'doctor', text:'{}', refs:[]
  });
  assert.deepEqual(calls.map(x => x.name), ['claim_dynamic','finish_dynamic']);
});

test('live capability contract normalizes vault operations to trusted queue', async t => {
  const { bridge } = await fixture(t, String.raw`
const args = process.argv.slice(2);
if (args[0] === '-h') {
  console.log('usage: beyin.py {context,sync,doctor}');
  process.exit(0);
}
process.exit(2);
`);
  const caps = await bridge.runtimeCapabilities();
  const byName = new Map(caps.map(x => [x.name, x]));
  for (const name of [
    'brain_vault_list','brain_vault_find','brain_vault_search','brain_vault_read_range',
    'brain_vault_get','brain_vault_update'
  ]) {
    const cap = byName.get(name);
    assert.equal(cap.available, true);
    assert.equal(cap.transport, 'trusted_supabase_queue');
    assert.equal('secure_transport_required' in cap, false);
  }
});

test('normal worker handling returns vault result through standard projection', async t => {
  const { vault, bridge } = await fixture(t);
  const content = '# Core\ntrusted vault content';
  await writeFile(join(vault, 'Core.md'), content);

  let finished;
  bridge.finish = async (cmd, status, result, error, projection) => {
    finished = { cmd, status, result, error, projection };
  };

  await bridge.handle({
    id:'vault-command-1',
    operation:'brain_vault_get',
    payload:{ source:'Core.md' }
  });

  assert.equal(finished.status, 'completed');
  assert.equal(finished.error, null);
  assert.equal(finished.result.content, content);
  assert.equal(finished.projection.kind, 'source');
  assert.equal(finished.projection.text, content);
});

test('bootstrap uses simplified v3 bridge skill and contains no pairing requirement', async t => {
  const { vault, bridge } = await fixture(t);
  const coreDir = join(vault, '.agents', 'skills', 'beyin');
  await mkdir(coreDir, { recursive:true });
  await writeFile(join(coreDir, 'SKILL.md'), '---\nname: beyin\ndescription: Core brain skill\n---\n# Core\n');
  await writeFile(join(vault, '.beyin-version'), '3.4.0\n');
  bridge.runtimeCapabilities = async () => [];

  const result = await bridge.bootstrap('test');
  assert.equal(result.bridge_api_version, 3);
  assert.match(result.bridge_skill.source, /SKILL\.v3\.md$/);
  assert.match(result.bridge_skill.content, /## Full vault/);
  assert.equal('secure_transport' in result, false);
  assert.doesNotMatch(result.bridge_skill.content, /AVX3\./);
});
