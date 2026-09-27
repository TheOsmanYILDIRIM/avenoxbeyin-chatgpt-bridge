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

  const started = await startWorker(root, { entry });
  assert.equal(started.status, 'started');
  assert.equal((await workerStatus(root)).running, true);

  const again = await startWorker(root, { entry });
  assert.equal(again.status, 'already_running');

  const stopped = await stopWorker(root);
  assert.equal(stopped.status, 'stopped');
  assert.equal((await workerStatus(root)).running, false);
});
