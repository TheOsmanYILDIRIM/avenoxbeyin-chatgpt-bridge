import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import {
  createPairing, listPairings, revokePairing,
  encryptCommandWithToken, decryptPairedCommand,
  encryptPairedResult, decryptResultWithToken
} from '../src/secure.mjs';

async function rootFixture(t) {
  const root = await mkdtemp(join(tmpdir(), 'avenox-secure-test-'));
  t.after(() => rm(root, { recursive:true, force:true }));
  return root;
}

test('pairing token encrypts and authenticates a command envelope', async t => {
  const root = await rootFixture(t);
  const pairing = await createPairing(root, { name:'test', expiresDays:30, now:1000 });
  const envelope = encryptCommandWithToken(
    pairing.token,
    'brain_vault_get',
    { source:'Threads.md' },
    { now:2000, ttlMs:300000 }
  );

  const decoded = await decryptPairedCommand(root, 'brain_vault_get', envelope, { now:3000 });
  assert.deepEqual(decoded.payload, { source:'Threads.md' });
  assert.equal(decoded.pair_id, pairing.pair_id);
});

test('secure envelope rejects replay, tampering and expiry', async t => {
  const root = await rootFixture(t);
  const pairing = await createPairing(root, { name:'test', expiresDays:30, now:1000 });

  const replay = encryptCommandWithToken(
    pairing.token, 'brain_vault_get', { source:'Threads.md' },
    { now:2000, ttlMs:300000 }
  );
  await decryptPairedCommand(root, 'brain_vault_get', replay, { now:3000 });
  await assert.rejects(
    () => decryptPairedCommand(root, 'brain_vault_get', replay, { now:4000 }),
    error => error?.code === 'secure_replay_rejected'
  );

  const tampered = encryptCommandWithToken(
    pairing.token, 'brain_vault_get', { source:'Threads.md' },
    { now:5000, ttlMs:300000 }
  );
  const chars = tampered.ciphertext.split('');
  chars[0] = chars[0] === 'A' ? 'B' : 'A';
  tampered.ciphertext = chars.join('');
  await assert.rejects(
    () => decryptPairedCommand(root, 'brain_vault_get', tampered, { now:6000 }),
    error => error?.code === 'secure_auth_failed'
  );

  const expired = encryptCommandWithToken(
    pairing.token, 'brain_vault_get', { source:'Threads.md' },
    { now:7000, ttlMs:1000 }
  );
  await assert.rejects(
    () => decryptPairedCommand(root, 'brain_vault_get', expired, { now:9000 }),
    error => error?.code === 'secure_command_expired'
  );
});

test('secure result is encrypted for the same pairing', async t => {
  const root = await rootFixture(t);
  const pairing = await createPairing(root, { name:'test', expiresDays:30, now:1000 });
  const command = encryptCommandWithToken(
    pairing.token, 'brain_vault_get', { source:'Core.md' },
    { now:2000, ttlMs:300000 }
  );
  const context = await decryptPairedCommand(root, 'brain_vault_get', command, { now:3000 });
  const encrypted = encryptPairedResult(context, 'brain_vault_get', {
    ok:true,
    result:{ source:'Core.md', content:'private companion' }
  }, { now:4000 });

  const decoded = decryptResultWithToken(pairing.token, 'brain_vault_get', encrypted);
  assert.equal(decoded.result.content, 'private companion');
  assert.equal(JSON.stringify(encrypted).includes('private companion'), false);
});

test('pairing listing never returns secret and revocation disables the pair', async t => {
  const root = await rootFixture(t);
  const pairing = await createPairing(root, { name:'test', expiresDays:30, now:1000 });
  const list = await listPairings(root, { now:2000 });
  assert.equal(list.length, 1);
  assert.equal('secret' in list[0], false);
  assert.equal('token' in list[0], false);

  assert.equal((await revokePairing(root, pairing.pair_id)).revoked, true);
  const envelope = encryptCommandWithToken(
    pairing.token, 'brain_vault_get', { source:'Threads.md' },
    { now:3000, ttlMs:300000 }
  );
  await assert.rejects(
    () => decryptPairedCommand(root, 'brain_vault_get', envelope, { now:4000 }),
    error => error?.code === 'secure_pairing_required'
  );
});
