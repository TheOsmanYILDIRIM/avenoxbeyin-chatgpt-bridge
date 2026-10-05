import test from 'node:test';
import assert from 'node:assert/strict';
import { planReplicaSync } from '../src/remote-vault.mjs';

test('remote-only change pulls when local stayed at base', () => {
  const plan = planReplicaSync(
    { 'Core.md':'aaa' },
    { 'Core.md':'bbb' },
    { 'Core.md':'aaa' }
  );
  assert.deepEqual(plan, [{
    source:'Core.md', action:'pull', local_sha256:'aaa', remote_sha256:'bbb', base_sha256:'aaa'
  }]);
});

test('local-only change pushes when remote stayed at base', () => {
  const plan = planReplicaSync(
    { 'Threads.md':'bbb' },
    { 'Threads.md':'aaa' },
    { 'Threads.md':'aaa' }
  );
  assert.equal(plan[0].action, 'push');
  assert.equal(plan[0].base_sha256, 'aaa');
});

test('divergence is sent to authoritative server merge check', () => {
  const plan = planReplicaSync(
    { 'Journal.md':'local' },
    { 'Journal.md':'remote' },
    { 'Journal.md':'base' }
  );
  assert.equal(plan.length, 1);
  assert.equal(plan[0].action, 'push');
  assert.equal(plan[0].base_sha256, 'base');
});

test('identical heads do no work', () => {
  assert.deepEqual(
    planReplicaSync({ 'A.md':'same' }, { 'A.md':'same' }, { 'A.md':'old' }),
    []
  );
});

test('local deletion is conservative and restores remote', () => {
  const plan = planReplicaSync(
    {},
    { 'A.md':'remote' },
    { 'A.md':'base' }
  );
  assert.equal(plan[0].action, 'pull');
});
