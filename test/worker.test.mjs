import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
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

test('receipt defaults to chatgpt attribution in coordinated upstream mode', async t => {
  const script = String.raw`
const fs = await import('node:fs/promises');
const fileIndex = process.argv.indexOf('--file');
const harnessIndex = process.argv.indexOf('--harness');
const body = JSON.parse(await fs.readFile(process.argv[fileIndex + 1], 'utf8'));
console.log(JSON.stringify({status:'ok', harness:process.argv[harnessIndex + 1], body}));
`;
  const { bridge } = await fixture(t, script);
  const result = await bridge.execute('brain_receipt', {
    event_id:'chatgpt-receipt',
    summary:'Synthetic bridge receipt.',
    refs:['notes/result.md']
  });
  assert.equal(result.harness, 'chatgpt');
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
