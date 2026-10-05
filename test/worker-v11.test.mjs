import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, rm, mkdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createHash } from 'node:crypto';
import { Bridge } from '../src/worker.mjs';

async function fixture(t, script = `
const args = process.argv.slice(2);
if (args[0] === '-h') {
  console.log('usage: beyin.py {context,note-create,task-create,task-update,receipt,sync,history,skill-sync,companion-compact,preferences,doctor,update,rollback,recover,jev,jev-memory}');
  process.exit(0);
}
console.log(JSON.stringify({status:"ok"}));
`) {
  const vault = await mkdtemp(join(tmpdir(), 'avenox-bridge-v11-test-'));
  t.after(() => rm(vault, { recursive:true, force:true }));
  await writeFile(join(vault, 'beyin.py'), script, 'utf8');
  const bridge = new Bridge({
    vault_root: vault,
    python: process.execPath,
    max_source_bytes: 262144,
    max_vault_file_bytes: 1048576,
    poll_interval_ms: 5,
    hook_state_path: join(vault, '.bridge-hook-state.json')
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

test('cached v4 transport promotes remote Brain operations to direct Supabase RPC', async t => {
  const { bridge } = await fixture(t, String.raw`
const args = process.argv.slice(2);
if (args[0] === '-h') {
  console.log('usage: beyin.py {context,sync,doctor}');
  process.exit(0);
}
process.exit(2);
`);
  bridge._transportContract = {
    schema_version:12,
    claim_rpc:'claim_next_brain_command_v2',
    finish_rpc:'finish_brain_command_v2',
    vault_transport:'trusted_supabase_queue',
    remote_vault_transport:'versioned_remote_vault_v1',
    remote_vault:{ rpc:'brain_remote_rpc', replica_rpc:'brain_remote_replica_rpc' }
  };
  const caps = await bridge.runtimeCapabilities();
  const byName = new Map(caps.map(x => [x.name,x]));
  for (const name of [
    'brain_context','brain_vault_list','brain_vault_find','brain_vault_search',
    'brain_vault_read_range','brain_vault_get','brain_vault_update','brain_remote_conflicts'
  ]) {
    assert.equal(byName.get(name).transport, 'direct_supabase_rpc');
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

test('bootstrap uses remote-first v4 bridge skill and contains no pairing requirement', async t => {
  const { vault, bridge } = await fixture(t);
  const coreDir = join(vault, '.agents', 'skills', 'beyin');
  await mkdir(coreDir, { recursive:true });
  await writeFile(join(coreDir, 'SKILL.md'), '---\nname: beyin\ndescription: Core brain skill\n---\n# Core\n');
  await writeFile(join(vault, '.beyin-version'), '3.4.0\n');
  bridge.runtimeCapabilities = async () => [];

  const result = await bridge.bootstrap('test');
  assert.equal(result.bridge_api_version, 4);
  assert.match(result.bridge_skill.source, /SKILL\.v4\.md$/);
  assert.match(result.bridge_skill.content, /## Remote-first Brain/i);
  assert.equal('secure_transport' in result, false);
  assert.doesNotMatch(result.bridge_skill.content, /AVX3\./);
  assert.deepEqual(result.recent_task_journal, []);
});

test('bootstrap includes recent_task_journal from Supabase and projects it into text', async t => {
  const { vault, bridge } = await fixture(t);
  const coreDir = join(vault, '.agents', 'skills', 'beyin');
  await mkdir(coreDir, { recursive:true });
  await writeFile(join(coreDir, 'SKILL.md'), '---\nname: beyin\ndescription: Core brain skill\n---\n# Core\n');
  await writeFile(join(vault, '.beyin-version'), '3.4.0\n');
  bridge.runtimeCapabilities = async () => [];

  const mockJournal = [
    {
      id: 'c1111111-1111-1111-1111-111111111111',
      idempotency_key: 'idem-1',
      operation: 'brain_task_update',
      status: 'completed',
      target_ref: 'tasks/study.md',
      task_id: 'study-task',
      summary: 'done',
      source_refs: ['notes/summary.md'],
      response_kind: 'mutation',
      error_code: null,
      created_at: '2026-09-30T10:00:00Z',
      completed_at: '2026-09-30T10:00:01Z'
    },
    {
      id: 'c2222222-2222-2222-2222-222222222222',
      idempotency_key: 'idem-2',
      operation: 'brain_receipt',
      status: 'completed',
      target_ref: 'evt-123',
      task_id: 'evt-123',
      summary: 'Refactored module',
      source_refs: ['notes/refactor.md'],
      response_kind: 'mutation',
      error_code: null,
      created_at: '2026-09-30T09:00:00Z',
      completed_at: '2026-09-30T09:00:01Z'
    }
  ];

  bridge.rpc = async (name, body) => {
    if (name === 'get_recent_task_journal') {
      assert.equal(body.p_limit, 30);
      return mockJournal;
    }
    throw new Error(`unexpected rpc ${name}`);
  };

  const result = await bridge.bootstrap('test recovery');
  assert.deepEqual(result.recent_task_journal, mockJournal);

  const projection = bridge.project('avenox_bootstrap', result);
  assert.equal(projection.kind, 'bootstrap');
  assert.match(projection.text, /## Recent Task Journal/);
  assert.match(projection.text, /- \[completed\] brain_task_update \(c1111111\) ref: tasks\/study\.md - done/);
  assert.match(projection.text, /- \[completed\] brain_receipt \(c2222222\) ref: evt-123 - Refactored module/);
  assert.match(projection.text, /- Recent Tasks: 2/);
});

test('getRecentTaskJournal handles rpc error gracefully', async t => {
  const { bridge } = await fixture(t);
  bridge.rpc = async () => { throw new Error('rpc failed'); };
  const journal = await bridge.getRecentTaskJournal(30);
  assert.deepEqual(journal, []);
});

test('avenox_turn_context returns chatgpt-beyin-hook, recent journal and persistence capabilities subset only', async t => {
  const { vault, bridge } = await fixture(t);
  const mockJournal = [
    {
      id: 'c3333333-3333-3333-3333-333333333333',
      idempotency_key: 'idem-3',
      operation: 'brain_task_update',
      status: 'completed',
      target_ref: 'tasks/feature.md',
      task_id: 'feature-task',
      summary: 'active',
      source_refs: ['notes/spec.md'],
      response_kind: 'mutation',
      error_code: null,
      created_at: '2026-09-30T11:00:00Z',
      completed_at: '2026-09-30T11:00:01Z'
    }
  ];

  bridge.rpc = async (name, body) => {
    if (name === 'get_recent_task_journal') {
      assert.equal(body.p_limit, 30);
      return mockJournal;
    }
    throw new Error(`unexpected rpc ${name}`);
  };

  const result = await bridge.turnContext({ task: 'fix login bug', project: 'auth-service' });
  assert.equal(result.task, 'fix login bug');
  assert.equal(result.project, 'auth-service');
  assert.equal(result.hook_skill.name, 'chatgpt-beyin-hook');
  assert.match(result.hook_skill.content, /chatgpt-beyin-hook/);
  assert.deepEqual(result.recent_task_journal, mockJournal);

  // Must NOT include full manifest or core skill
  assert.equal(result.skills_manifest, undefined);
  assert.equal(result.core_skill, undefined);
  assert.equal(result.bridge_skill, undefined);

  // Must include only persistence/recovery capabilities subset
  const opNames = result.capabilities.map(c => c.name);
  assert.ok(opNames.includes('brain_receipt'));
  assert.ok(opNames.includes('brain_note_create'));
  assert.ok(opNames.includes('brain_task_create'));
  assert.ok(opNames.includes('brain_task_update'));
  assert.ok(opNames.includes('brain_vault_get'));
  assert.ok(opNames.includes('brain_vault_update'));
  assert.ok(opNames.includes('brain_sync'));
  assert.ok(opNames.includes('brain_companion_compact'));
  assert.ok(opNames.includes('brain_source_get'));
  assert.ok(opNames.includes('brain_source_update'));
  assert.ok(opNames.includes('brain_history'));
  assert.ok(opNames.includes('avenox_turn_context'));

  // Must NOT include maintenance/update/admin operations not needed for turn persistence
  assert.ok(!opNames.includes('avenox_bootstrap'));
  assert.ok(!opNames.includes('brain_doctor'));
  assert.ok(!opNames.includes('brain_update'));
  assert.ok(!opNames.includes('brain_rollback'));
  assert.ok(!opNames.includes('brain_recover'));
  assert.ok(!opNames.includes('brain_preferences_update'));

  // Test projection
  const projection = bridge.project('avenox_turn_context', result);
  assert.equal(projection.kind, 'turn_context');
  assert.match(projection.text, /# Avenox Turn Context/);
  assert.match(projection.text, /- Task: fix login bug/);
  assert.match(projection.text, /- Project: auth-service/);
  assert.match(projection.text, /## Hook Skill/);
  assert.match(projection.text, /## Live Persistence Capabilities/);
  assert.match(projection.text, /## Recent Task Journal/);
  assert.match(projection.text, /- \[completed\] brain_task_update \(c3333333\) ref: tasks\/feature\.md - active/);
});

test('avenox_turn_context validates payload schema and rejects unknown fields', async t => {
  const { bridge } = await fixture(t);
  bridge.rpc = async () => [];

  // Valid empty payload
  const resEmpty = await bridge.turnContext({});
  assert.equal(resEmpty.task, null);
  assert.equal(resEmpty.project, null);

  // Valid task only
  const resTask = await bridge.turnContext({ task: 'some task' });
  assert.equal(resTask.task, 'some task');
  assert.equal(resTask.project, null);

  // Rejects invalid task type
  await assert.rejects(
    () => bridge.turnContext({ task: 123 }),
    /task required/
  );

  // Rejects invalid project type
  await assert.rejects(
    () => bridge.turnContext({ project: 123 }),
    /project required/
  );

  // Rejects unsupported properties
  await assert.rejects(
    () => bridge.turnContext({ unknown_field: 'value' }),
    /unsupported property: unknown_field/
  );
});

test('brain_receipt accepts chatgpt as valid harness and rejects invalid harness', async t => {
  const { bridge } = await fixture(t);

  // chatgpt harness accepted
  const res = await bridge.execute('brain_receipt', {
    event_id: 'evt-chatgpt-1',
    summary: 'Completed work item in ChatGPT',
    refs: ['notes/item.md'],
    harness: 'chatgpt'
  });
  assert.deepEqual(res, { status: 'ok' });

  // Invalid harness rejected
  await assert.rejects(
    () => bridge.execute('brain_receipt', {
      event_id: 'evt-chatgpt-2',
      summary: 'Invalid harness test',
      refs: ['notes/item.md'],
      harness: 'unsupported_agent'
    }),
    /invalid receipt harness/
  );
});

test('periodic chatgpt hook injection appends hook every 4 eligible responses and resets cadence', async t => {
  const { vault, bridge } = await fixture(t);
  const hookSkill = await bridge.hookSkill();
  assert.ok(hookSkill?.content?.length > 0);

  const calls = [];
  bridge.finish = async (cmd, status, result, error, projection) => {
    calls.push({ cmd, status, result, error, projection });
  };

  const fileContent = '# Note\nsome content';
  await writeFile(join(vault, 'Note.md'), fileContent);

  // Response 1: eligible (brain_vault_get)
  await bridge.handle({
    id: 'cmd-1',
    operation: 'brain_vault_get',
    payload: { source: 'Note.md' }
  });
  assert.equal(calls.length, 1);
  assert.equal(calls[0].status, 'completed');
  assert.equal(calls[0].projection.text, fileContent);
  assert.equal(calls[0].projection.text.includes('AVENOX CONTRACT CAPSULE'), false);

  // Response 2: eligible (brain_receipt)
  await bridge.handle({
    id: 'cmd-2',
    operation: 'brain_receipt',
    payload: {
      event_id: 'evt-2',
      summary: 'Task completed',
      refs: ['Note.md'],
      harness: 'chatgpt'
    }
  });
  assert.equal(calls.length, 2);
  assert.equal(calls[1].status, 'completed');
  assert.equal(calls[1].projection.text.includes('AVENOX CONTRACT CAPSULE'), false);

  // Response 3: eligible (brain_vault_get)
  await bridge.handle({
    id: 'cmd-3',
    operation: 'brain_vault_get',
    payload: { source: 'Note.md' }
  });
  assert.equal(calls.length, 3);
  assert.equal(calls[2].status, 'completed');
  assert.equal(calls[2].projection.text.includes('AVENOX CONTRACT CAPSULE'), false);

  // Response 4: eligible (brain_receipt) -> MUST INJECT HOOK
  await bridge.handle({
    id: 'cmd-4',
    operation: 'brain_receipt',
    payload: {
      event_id: 'evt-4',
      summary: 'Fourth response',
      refs: ['Note.md'],
      harness: 'chatgpt'
    }
  });
  assert.equal(calls.length, 4);
  assert.equal(calls[3].status, 'completed');
  // Hook delimiter and managed content appended to projected response_text
  assert.equal(calls[3].projection.text.includes('AVENOX CONTRACT CAPSULE'), true);
  assert.equal(calls[3].projection.text.includes('contract='), true);
  assert.match(calls[3].projection.text, /contract=/);
  // Does NOT inject core Beyin skill
  assert.equal(calls[3].projection.text.includes('Core brain skill'), false);
  // Preserves result and refs semantics completely
  assert.deepEqual(calls[3].result, { status: 'ok' });
  assert.deepEqual(calls[3].projection.refs, []);

  // Response 5: eligible (brain_vault_get) -> MUST RESET CADENCE (no injection)
  await bridge.handle({
    id: 'cmd-5',
    operation: 'brain_vault_get',
    payload: { source: 'Note.md' }
  });
  assert.equal(calls.length, 5);
  assert.equal(calls[4].status, 'completed');
  assert.equal(calls[4].projection.text, fileContent);
  assert.equal(calls[4].projection.text.includes('AVENOX CONTRACT CAPSULE'), false);
});

test('only eligible ChatGPT responses count towards hook injection cadence', async t => {
  const { vault, bridge } = await fixture(t);
  const hookSkill = await bridge.hookSkill();

  const calls = [];
  bridge.finish = async (cmd, status, result, error, projection) => {
    calls.push({ cmd, status, result, error, projection });
  };

  await writeFile(join(vault, 'Note.md'), '# Note\ncontent');

  // Response 1 (eligible: count = 1)
  await bridge.handle({
    id: 'cmd-e1',
    operation: 'brain_vault_get',
    payload: { source: 'Note.md' }
  });
  assert.equal(calls.at(-1).projection.text.includes('AVENOX CONTRACT CAPSULE'), false);

  // Response 2 (eligible: count = 2)
  await bridge.handle({
    id: 'cmd-e2',
    operation: 'brain_vault_get',
    payload: { source: 'Note.md' }
  });
  assert.equal(calls.at(-1).projection.text.includes('AVENOX CONTRACT CAPSULE'), false);

  // Ineligible 1: maintenance sync
  await bridge.handle({
    id: 'cmd-m1',
    operation: 'brain_sync',
    payload: {}
  });
  assert.equal(calls.at(-1).projection.text.includes('AVENOX CONTRACT CAPSULE'), false);

  // Ineligible 2: doctor diagnostic
  await bridge.handle({
    id: 'cmd-m2',
    operation: 'brain_doctor',
    payload: {}
  });
  assert.equal(calls.at(-1).projection.text.includes('AVENOX CONTRACT CAPSULE'), false);

  // Ineligible 3: failed operation
  await bridge.handle({
    id: 'cmd-f1',
    operation: 'invalid_op_test',
    payload: {}
  });
  assert.equal(calls.at(-1).status, 'failed');
  assert.equal((calls.at(-1).projection?.text || '').includes('AVENOX CONTRACT CAPSULE'), false);

  // Response 3 (eligible: count = 3)
  await bridge.handle({
    id: 'cmd-e3',
    operation: 'brain_vault_get',
    payload: { source: 'Note.md' }
  });
  assert.equal(calls.at(-1).projection.text.includes('AVENOX CONTRACT CAPSULE'), false);

  // Response 4 (eligible: count = 4) -> INJECTS!
  await bridge.handle({
    id: 'cmd-e4',
    operation: 'brain_receipt',
    payload: {
      event_id: 'evt-e4',
      summary: 'Fourth eligible response',
      refs: ['Note.md'],
      harness: 'chatgpt'
    }
  });
  assert.equal(calls.at(-1).projection.text.includes('AVENOX CONTRACT CAPSULE'), true);
  assert.equal(calls.at(-1).projection.text.includes('contract='), true);
  assert.deepEqual(calls.at(-1).result, { status: 'ok' });
});

test('cadence is configurable and counter persists across bridge instances', async t => {
  const { vault } = await fixture(t);
  await writeFile(join(vault, 'Note.md'), '# Note\ncontent');
  const hookStatePath = join(vault, '.bridge-hook-state.json');

  // Custom cadence = 2
  const bridge1 = new Bridge({
    vault_root: vault,
    python: process.execPath,
    chatgpt_hook_cadence: 2,
    hook_state_path: hookStatePath
  });

  const calls1 = [];
  bridge1.finish = async (cmd, status, result, error, projection) => {
    calls1.push({ cmd, status, result, error, projection });
  };

  // Response 1 on bridge1 (count = 1, no injection)
  await bridge1.handle({
    id: 'b1-cmd-1',
    operation: 'brain_vault_get',
    payload: { source: 'Note.md' }
  });
  assert.equal(calls1.length, 1);
  assert.equal(calls1[0].projection.text.includes('AVENOX CONTRACT CAPSULE'), false);

  // Simulate worker restart: new Bridge instance pointing to same root and hook_state_path
  const bridge2 = new Bridge({
    vault_root: vault,
    python: process.execPath,
    chatgpt_hook_cadence: 2,
    hook_state_path: hookStatePath
  });

  const calls2 = [];
  bridge2.finish = async (cmd, status, result, error, projection) => {
    calls2.push({ cmd, status, result, error, projection });
  };

  // Response 2 on bridge2 (count was 1, now 2 -> INJECTS!)
  await bridge2.handle({
    id: 'b2-cmd-2',
    operation: 'brain_vault_get',
    payload: { source: 'Note.md' }
  });
  assert.equal(calls2.length, 1);
  assert.equal(calls2[0].projection.text.includes('AVENOX CONTRACT CAPSULE'), true);
});

test('local beyin CLI and runtime scripts support chatgpt harness end-to-end', async t => {
  const { execFile } = await import('node:child_process');
  const { promisify } = await import('node:util');
  const execFileAsync = promisify(execFile);
  const cliScript = '/data/data/com.termux/files/home/vault/.claude/scripts/beyin_v3_cli.py';
  const { access } = await import('node:fs/promises');
  try { await access(cliScript); } catch { t.skip('Termux-local Beyin CLI is not present on GitHub runner'); return; }

  // Test CLI help shows chatgpt in harness choices
  const { stdout } = await execFileAsync('python3', [cliScript, 'receipt', '--help']);
  assert.match(stdout, /chatgpt/);
});

test('avenox_turn_context opens turn record, returns turn_id, and includes finalization reminder', async t => {
  const { bridge } = await fixture(t);
  let openRpcCalled = false;
  bridge.rpc = async (method, params) => {
    if (method === 'open_chatgpt_turn') {
      openRpcCalled = true;
      return {
        turn_id: params.p_turn_id || 'generated-turn-id',
        previous_unfinalized_turn: null
      };
    }
    return [];
  };

  const res = await bridge.turnContext({ task: 'audit auth flow', project: 'avenox' });
  assert.equal(openRpcCalled, true);
  assert.ok(res.turn_id);
  assert.equal(res.previous_unfinalized_turn, null);
  assert.equal(res.task, 'audit auth flow');
  assert.equal(res.project, 'avenox');

  const proj = bridge.project('avenox_turn_context', res);
  assert.equal(proj.kind, 'turn_context');
  assert.match(proj.text, /Turn ID: /);
  assert.match(proj.text, /FINALIZATION GUARD/);
  assert.match(proj.text, /avenox_turn_finalize/);
});

test('avenox_turn_finalize validates state_changed=true requires non-empty refs', async t => {
  const { bridge } = await fixture(t);

  // Reject empty refs when state_changed is true
  await assert.rejects(
    () => bridge.turnFinalize({
      turn_id: 'turn-123',
      state_changed: true,
      summary: 'Updated memory files',
      refs: []
    }),
    error => error?.code === 'validation_error' && error.message.includes('refs')
  );

  // Reject whitespace-only refs
  await assert.rejects(
    () => bridge.turnFinalize({
      turn_id: 'turn-123',
      state_changed: true,
      summary: 'Updated memory files',
      refs: ['  ', '']
    }),
    error => error?.code === 'validation_error'
  );

  // Accept valid refs when state_changed is true
  let finalizeParams = null;
  bridge.rpc = async (method, params) => {
    if (method === 'finalize_chatgpt_turn') {
      finalizeParams = params;
      return { status: 'finalized', turn_id: params.p_turn_id, idempotent: false };
    }
    return {};
  };

  const valid = await bridge.turnFinalize({
    turn_id: 'turn-123',
    state_changed: true,
    summary: 'Updated Last-Session.md',
    refs: ['Last-Session.md']
  });
  assert.equal(valid.status, 'finalized');
  assert.equal(valid.turn_id, 'turn-123');
  assert.equal(valid.state_changed, true);
  assert.deepEqual(valid.refs, ['Last-Session.md']);
  assert.equal(finalizeParams.p_turn_id, 'turn-123');
  assert.equal(finalizeParams.p_state_changed, true);
  assert.deepEqual(finalizeParams.p_refs, ['Last-Session.md']);

  const proj = bridge.project('avenox_turn_finalize', valid);
  assert.equal(proj.kind, 'turn_finalize');
  assert.match(proj.text, /Turn turn-123 finalized/);
});

test('avenox_turn_finalize succeeds with state_changed=false and empty refs', async t => {
  const { bridge } = await fixture(t);
  let finalizeParams = null;
  bridge.rpc = async (method, params) => {
    if (method === 'finalize_chatgpt_turn') {
      finalizeParams = params;
      return { status: 'finalized', turn_id: params.p_turn_id, idempotent: false };
    }
    return {};
  };

  const res = await bridge.turnFinalize({
    turn_id: 'turn-ro-1',
    state_changed: false,
    summary: 'Answered user question about codebase structure without state changes',
    refs: []
  });
  assert.equal(res.status, 'finalized');
  assert.equal(res.turn_id, 'turn-ro-1');
  assert.equal(res.state_changed, false);
  assert.deepEqual(res.refs, []);
  assert.equal(finalizeParams.p_state_changed, false);
  assert.deepEqual(finalizeParams.p_refs, []);
});

test('avenox_turn_context surfaces previous unfinalized turn as warning', async t => {
  const { bridge } = await fixture(t);
  bridge.rpc = async (method, params) => {
    if (method === 'open_chatgpt_turn') {
      return {
        turn_id: 'turn-new-2',
        previous_unfinalized_turn: {
          turn_id: 'turn-old-1',
          task: 'refactor tokenizer',
          created_at: '2026-09-30T12:00:00Z'
        }
      };
    }
    return [];
  };

  const res = await bridge.turnContext({ task: 'continue work' });
  assert.equal(res.turn_id, 'turn-new-2');
  assert.ok(res.previous_unfinalized_turn);
  assert.equal(res.previous_unfinalized_turn.turn_id, 'turn-old-1');

  const proj = bridge.project('avenox_turn_context', res);
  assert.match(proj.text, /WARNING: UNFINALIZED PREVIOUS TURN DETECTED/);
  assert.match(proj.text, /turn-old-1/);
  assert.match(proj.text, /refactor tokenizer/);
});

test('duplicate finalize calls are idempotent', async t => {
  const { bridge } = await fixture(t);
  let callCount = 0;
  bridge.rpc = async (method, params) => {
    if (method === 'finalize_chatgpt_turn') {
      callCount++;
      return {
        status: 'finalized',
        turn_id: params.p_turn_id,
        idempotent: callCount > 1
      };
    }
    return {};
  };

  const first = await bridge.turnFinalize({
    turn_id: 'turn-idem-1',
    state_changed: false,
    summary: 'Done',
    refs: []
  });
  assert.equal(first.status, 'finalized');
  assert.equal(first.idempotent, false);

  const second = await bridge.turnFinalize({
    turn_id: 'turn-idem-1',
    state_changed: false,
    summary: 'Done again',
    refs: []
  });
  assert.equal(second.status, 'finalized');
  assert.equal(second.idempotent, true);
});
