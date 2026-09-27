import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { startWorker, stopWorker, workerStatus } from '../src/process.mjs';

test('worker process manager starts, reports and stops one owned child', async t => {
  const root = await mkdtemp(join(tmpdir(), 'avenox-worker-test-'));
  t.after(() => rm(root, { recursive:true, force:true }));
  const entry = join(root, 'wait.mjs');
  await writeFile(entry, 'setInterval(() => {}, 1000)\n');

  assert.equal((await workerStatus(root)).running, false);

  const transportPreflight = async () => ({
    schema_version: 9,
    claim_rpc: 'claim_next_brain_command_v2',
    finish_rpc: 'finish_brain_command_v2'
  });

  const started = await startWorker(root, { entry, transportPreflight });
  assert.equal(started.status, 'started');
  assert.equal((await workerStatus(root)).running, true);

  const again = await startWorker(root, { entry, transportPreflight });
  assert.equal(again.status, 'already_running');

  const stopped = await stopWorker(root);
  assert.equal(stopped.status, 'stopped');
  assert.equal((await workerStatus(root)).running, false);
});


test('worker process manager refuses to spawn when transport preflight fails', async t => {
  const root = await mkdtemp(join(tmpdir(), 'avenox-worker-preflight-test-'));
  t.after(() => rm(root, { recursive:true, force:true }));
  const entry = join(root, 'wait.mjs');
  await writeFile(entry, 'setInterval(() => {}, 1000)\n');

  await assert.rejects(
    () => startWorker(root, {
      entry,
      transportPreflight: async () => {
        throw new Error('transport_schema_mismatch');
      }
    }),
    /transport_schema_mismatch/
  );

  assert.equal((await workerStatus(root)).running, false);
});
