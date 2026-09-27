import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { appendCommandLog, readCommandLog, COMMAND_LOG_FILE } from '../src/telemetry.mjs';
import { Bridge } from '../src/worker.mjs';

async function tempRoot(t, prefix) {
  const root = await mkdtemp(join(tmpdir(), prefix));
  t.after(() => rm(root, { recursive:true, force:true }));
  return root;
}

test('telemetry appends JSONL and returns only the requested tail', async t => {
  const root = await tempRoot(t, 'avenox-telemetry-');
  for (let i = 0; i < 5; i++) {
    await appendCommandLog(root, { command_id:'c' + i, operation:'op', execution_ms:i });
  }
  const rows = await readCommandLog(root, { limit:2 });
  assert.deepEqual(rows.map(x => x.command_id), ['c3','c4']);
});

test('telemetry rotates locally without losing the newest entry', async t => {
  const root = await tempRoot(t, 'avenox-telemetry-');
  await appendCommandLog(root, { command_id:'old', pad:'x'.repeat(200) }, { maxBytes:220 });
  await appendCommandLog(root, { command_id:'new', pad:'y'.repeat(200) }, { maxBytes:220 });

  const current = await readCommandLog(root, { limit:10 });
  assert.equal(current.at(-1).command_id, 'new');

  const rotated = await readFile(join(root, COMMAND_LOG_FILE + '.1'), 'utf8');
  assert.match(rotated, /"command_id":"old"/);
});

test('worker telemetry records timings and metadata but never payload or result content', async t => {
  const vault = await tempRoot(t, 'avenox-telemetry-vault-');
  const bridgeRoot = await tempRoot(t, 'avenox-telemetry-root-');
  await writeFile(join(vault, 'beyin.py'), 'console.log(JSON.stringify({status:"ok"}))\n', 'utf8');
  await writeFile(join(vault, '.beyin-version'), '3.4.0\n', 'utf8');
  await writeFile(join(vault, 'Core.md'), '# Core\nSECRET_PAYLOAD_CANARY\n', 'utf8');

  const bridge = new Bridge({
    vault_root:vault,
    bridge_root:bridgeRoot,
    python:process.execPath,
    max_vault_file_bytes:1048576
  });
  bridge._runtimeCapabilities = [{
    name:'brain_vault_get',
    available:true
  }];
  bridge.finish = async () => ({ ok:true });

  const createdAt = new Date(Date.now() - 80).toISOString();
  const claimedAt = new Date(Date.now() - 40).toISOString();

  await bridge.handle({
    id:'telemetry-command',
    operation:'brain_vault_get',
    payload:{ source:'Core.md', secret:'INPUT_SECRET_CANARY' },
    created_at:createdAt,
    claimed_at:claimedAt
  });

  const [row] = await readCommandLog(bridgeRoot, { limit:1 });
  assert.equal(row.command_id, 'telemetry-command');
  assert.equal(row.operation, 'brain_vault_get');
  assert.equal(row.terminal_status, 'completed');
  assert.equal(row.finish_ok, true);
  assert.equal(row.brain_version, '3.4.0');
  assert.equal(Number.isInteger(row.execution_ms), true);
  assert.equal(Number.isInteger(row.total_ms), true);

  const raw = await readFile(join(bridgeRoot, COMMAND_LOG_FILE), 'utf8');
  assert.equal(raw.includes('SECRET_PAYLOAD_CANARY'), false);
  assert.equal(raw.includes('INPUT_SECRET_CANARY'), false);
  assert.equal(raw.includes('"payload"'), false);
  assert.equal(raw.includes('"result"'), false);
});
