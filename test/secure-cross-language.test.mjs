import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import {
  createPairing, decryptPairedCommand, encryptPairedResult
} from '../src/secure.mjs';

const execFileAsync = promisify(execFile);

async function python(args, token) {
  const script = resolve('scripts/secure_client.py');
  const { stdout } = await execFileAsync('python3', [script, ...args], {
    env: { ...process.env, AVENOX_PAIRING_TOKEN: token },
    maxBuffer: 2 * 1024 * 1024
  });
  return JSON.parse(stdout);
}

test('Python client encrypts commands that Node worker authenticates', async t => {
  const root = await mkdtemp(join(tmpdir(), 'avenox-crosslang-'));
  t.after(() => rm(root, { recursive:true, force:true }));
  const pairing = await createPairing(root, { name:'crosslang', expiresDays:30 });

  const envelope = await python([
    'encode',
    '--operation', 'brain_vault_get',
    '--payload', JSON.stringify({ source:'Threads.md', unicode:'çalışma' })
  ], pairing.token);

  const decoded = await decryptPairedCommand(
    root, 'brain_vault_get', envelope, { now:Date.now() }
  );
  assert.deepEqual(decoded.payload, { source:'Threads.md', unicode:'çalışma' });
});

test('Python client decrypts Node worker secure results', async t => {
  const root = await mkdtemp(join(tmpdir(), 'avenox-crosslang-'));
  t.after(() => rm(root, { recursive:true, force:true }));
  const pairing = await createPairing(root, { name:'crosslang', expiresDays:30 });

  const command = await python([
    'encode',
    '--operation', 'brain_vault_get',
    '--payload', JSON.stringify({ source:'Core.md' })
  ], pairing.token);
  const context = await decryptPairedCommand(
    root, 'brain_vault_get', command, { now:Date.now() }
  );

  const resultEnvelope = encryptPairedResult(
    context,
    'brain_vault_get',
    { ok:true, result:{ source:'Core.md', content:'özel içerik' } }
  );

  const decoded = await python([
    'decode',
    '--operation', 'brain_vault_get',
    '--envelope', JSON.stringify(resultEnvelope)
  ], pairing.token);

  assert.equal(decoded.ok, true);
  assert.equal(decoded.result.content, 'özel içerik');
});
