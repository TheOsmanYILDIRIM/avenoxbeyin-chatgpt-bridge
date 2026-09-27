import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, rm, mkdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createHash } from 'node:crypto';
import { Bridge } from '../src/worker.mjs';

async function fixture(t, script = 'console.log(JSON.stringify({status:"ok"}))') {
  const vault = await mkdtemp(join(tmpdir(), 'avenox-bridge-test-'));
  t.after(() => rm(vault, { recursive:true, force:true }));
  await writeFile(join(vault, 'beyin.py'), script, 'utf8');
  const bridge = new Bridge({
    vault_root: vault,
    python: process.execPath,
    max_source_bytes: 262144,
    poll_interval_ms: 5
  });
  return { vault, bridge };
}

function sha(text) {
  return createHash('sha256').update(text).digest('hex');
}

test('exact source access blocks remote-private and companion sources', async t => {
  const { vault, bridge } = await fixture(t);
  const allowed = '---\nvisibility: internal\n---\nAllowed';
  await writeFile(join(vault, 'allowed.md'), allowed);
  assert.equal((await bridge.sourceGet('allowed.md')).content, allowed);

  const blocked = [
    ['private.md', '---\nvisibility: private\n---\nPRIVATE_CANARY'],
    ['local.md', '---\nremote_allowed: false\n---\nLOCAL_ONLY'],
    ['sensitive.md', '---\nsensitivity: sensitive\n---\nSENSITIVE'],
    ['Core.md', '# Companion identity']
  ];
  for (const [name, body] of blocked) {
    await writeFile(join(vault, name), body);
    await assert.rejects(
      () => bridge.sourceGet(name),
      error => error?.code === 'access_denied_private_source'
    );
  }
});

test('exact source update cannot declassify a blocked source', async t => {
  const { vault, bridge } = await fixture(t);
  const current = '---\nvisibility: private\n---\nsecret';
  await writeFile(join(vault, 'private.md'), current);
  await assert.rejects(
    () => bridge.sourceUpdate({
      source:'private.md',
      expected_sha256:sha(current),
      content:'---\nvisibility: internal\n---\nchanged'
    }),
    error => error?.code === 'access_denied_private_source'
  );
});

test('allowed source update keeps CAS and sync behavior', async t => {
  const { vault, bridge } = await fixture(t);
  const current = '---\nvisibility: internal\n---\nold';
  const next = '---\nvisibility: internal\n---\nnew';
  await writeFile(join(vault, 'note.md'), current);
  const result = await bridge.sourceUpdate({
    source:'note.md',
    expected_sha256:sha(current),
    content:next
  });
  assert.equal(result.previous_sha256, sha(current));
  assert.equal(result.sha256, sha(next));
  assert.equal(result.sync.status, 'ok');
});

test('Brain structured stderr maps conflicts and validation failures', async t => {
  const script = String.raw`
const sub = process.argv[2];
if (sub === 'conflict') {
  console.error(JSON.stringify({error:'RevisionConflict',message:'stale revision conflict'}));
  process.exit(1);
}
if (sub === 'invalid') {
  console.error(JSON.stringify({error:'ValueError',message:'invalid payload'}));
  process.exit(1);
}
console.log(JSON.stringify({status:'ok'}));
`;
  const { bridge } = await fixture(t, script);

  await assert.rejects(
    () => bridge.runBeyin('conflict'),
    error => error?.code === 'conflict' && error?.brain_error === 'RevisionConflict'
  );
  await assert.rejects(
    () => bridge.runBeyin('invalid'),
    error => error?.code === 'validation_error' && error?.brain_error === 'ValueError'
  );
});

test('capability discovery probes commands missing from top-level help safely', async t => {
  const script = String.raw`
const args = process.argv.slice(2);
if (args[0] === '-h') {
  console.log('usage: beyin.py {context,sync,doctor}');
  process.exit(0);
}
if (args[1] === '--help' && ['update','rollback','recover'].includes(args[0])) {
  console.log('usage: ' + args[0]);
  process.exit(0);
}
process.exit(2);
`;
  const { bridge } = await fixture(t, script);
  const caps = await bridge.runtimeCapabilities();
  const byName = new Map(caps.map(x => [x.name, x]));

  assert.equal(byName.get('brain_context').available, true);
  assert.equal(byName.get('brain_sync').available, true);
  assert.equal(byName.get('brain_doctor').available, true);
  assert.equal(byName.get('brain_update').available, true);
  assert.equal(byName.get('brain_update_check').available, true);
  assert.equal(byName.get('brain_update_dismiss').available, true);
  assert.equal(byName.get('brain_rollback').available, true);
  assert.equal(byName.get('brain_recover').available, true);
  assert.equal(byName.get('brain_task_create').available, false);
});


test('transport contract accepts required schema and dynamic RPC names', async t => {
  const { bridge } = await fixture(t);
  bridge.rpc = async name => {
    assert.equal(name, 'bridge_transport_contract');
    return {
      schema_version: 9,
      claim_rpc: 'claim_dynamic',
      finish_rpc: 'finish_dynamic',
      command_terminal_statuses: ['completed','failed','conflict']
    };
  };

  const contract = await bridge.transportContract();
  assert.equal(contract.schema_version, 9);
  assert.equal(contract.claim_rpc, 'claim_dynamic');
  assert.equal(contract.finish_rpc, 'finish_dynamic');
});

test('transport contract rejects old schema before command handling', async t => {
  const { bridge } = await fixture(t);
  bridge.rpc = async () => ({
    schema_version: 8,
    claim_rpc: 'claim_dynamic',
    finish_rpc: 'finish_dynamic'
  });

  await assert.rejects(
    () => bridge.transportContract(),
    error => error?.code === 'transport_schema_mismatch'
  );
});

test('transport contract rejects missing RPC names', async t => {
  const { bridge } = await fixture(t);
  bridge.rpc = async () => ({ schema_version: 9 });

  await assert.rejects(
    () => bridge.transportContract(),
    error => error?.code === 'transport_contract_invalid'
  );
});

test('claim and finish use RPC names from live transport contract', async t => {
  const { bridge } = await fixture(t);
  const calls = [];
  bridge._transportContract = {
    schema_version: 9,
    claim_rpc: 'claim_dynamic',
    finish_rpc: 'finish_dynamic'
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
    kind:'doctor',
    text:'{}',
    refs:[]
  });

  assert.deepEqual(calls.map(x => x.name), ['claim_dynamic','finish_dynamic']);
  assert.equal(calls[1].body.p.id, 'cmd-1');
});

test('bootstrap always includes versioned bridge_skill plus core skill and manifest', async t => {
  const { vault, bridge } = await fixture(t);
  const coreDir = join(vault, '.agents', 'skills', 'beyin');
  await mkdir(coreDir, { recursive:true });
  await writeFile(join(coreDir, 'SKILL.md'), '---\nname: beyin\ndescription: Core brain skill\n---\n# Core\n');
  await writeFile(join(vault, '.beyin-version'), '3.4.0\n');
  bridge.runtimeCapabilities = async () => [];

  const result = await bridge.bootstrap('test');
  assert.equal(result.bridge_skill.name, 'avenox-chatgpt-bridge');
  assert.match(result.bridge_skill.content, /# Avenox ChatGPT Bridge/);
  assert.match(result.bridge_skill.sha256, /^[a-f0-9]{64}$/);
  assert.equal(result.core_skill.name, 'beyin');
  assert.equal(result.skills_manifest.some(x => x.name === 'beyin'), true);
});
