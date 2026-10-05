import test from 'node:test';
import assert from 'node:assert/strict';
import { planReplicaSync, probeRemoteVault } from '../src/remote-vault.mjs';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

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


test('HEAD probe skips local scan when remote tree is unchanged', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'avenox-remote-vault-test-'));
  const cachePath = join(dir, 'cache.json');
  await writeFile(cachePath, JSON.stringify({
    version:1,
    cursor_commit_seq:7,
    remote_tree_hash:'same-tree',
    files:{},
    base:{},
    remote:{}
  }));

  let rpcCalls = 0;
  const bridge = {
    c:{ remote_vault_cache_path:cachePath },
    bridgeRoot:() => dir,
    transportContract:async () => ({
      remote_vault_transport:'versioned_remote_vault_v1',
      remote_vault:{ rpc:'brain_remote_rpc', replica_rpc:'brain_remote_replica_rpc' }
    }),
    rpc:async (name, body) => {
      rpcCalls += 1;
      assert.equal(name, 'brain_remote_rpc');
      assert.equal(body.p_operation, 'head');
      return { tree_hash:'same-tree', head_commit_seq:7, file_count:10 };
    },
    vaultList:async () => { throw new Error('local scan should not run'); }
  };

  try {
    const result = await probeRemoteVault(bridge);
    assert.equal(result.supported, true);
    assert.equal(result.changed, false);
    assert.equal(rpcCalls, 1);
  } finally {
    await rm(dir, { recursive:true, force:true });
  }
});
