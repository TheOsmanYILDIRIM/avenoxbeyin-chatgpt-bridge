import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

test('worker transport contract is represented across canonical schema and ordered migrations', async () => {
  const [worker, schema, migration008, migration009, migration010] = await Promise.all([
    readFile(new URL('../src/worker.mjs', import.meta.url), 'utf8'),
    readFile(new URL('../sql/schema.sql', import.meta.url), 'utf8'),
    readFile(new URL('../sql/migrations/008_single_payload_finish_rpc.sql', import.meta.url), 'utf8'),
    readFile(new URL('../sql/migrations/009_transport_contract_v3.sql', import.meta.url), 'utf8'),
    readFile(new URL('../sql/migrations/010_secure_paired_full_vault.sql', import.meta.url), 'utf8')
  ]);

  assert.match(worker, /REQUIRED_TRANSPORT_SCHEMA\s*=\s*10/);
  assert.match(worker, /bridge_transport_contract/);
  assert.doesNotMatch(worker, /rpc\('claim_next_brain_command_v2'/);
  assert.doesNotMatch(worker, /rpc\('finish_brain_command_v2'/);

  assert.match(schema, /bridge_transport_meta/);
  assert.match(schema, /values\s*\(true,\s*10\)/i);
  assert.match(schema, /create or replace function public\.bridge_transport_contract\(\)/i);
  assert.match(schema, /create or replace function public\.claim_next_brain_command_v2\(\)/i);
  assert.match(schema, /create or replace function public\.finish_brain_command_v2\(p jsonb\)/i);

  assert.match(migration008, /create or replace function public\.finish_brain_command_v2\(p jsonb\)/i);

  assert.match(migration009, /bridge_transport_meta/);
  assert.match(migration009, /values\s*\(true,\s*9\)/i);
  assert.match(migration009, /create or replace function public\.bridge_transport_contract\(\)/i);
  assert.match(migration009, /create or replace function public\.claim_next_brain_command_v2\(\)/i);
  assert.match(migration009, /'finish_rpc',\s*'finish_brain_command_v2'/i);

  assert.match(migration010, /brain_vault_list/);
  assert.match(migration010, /brain_vault_get/);
  assert.match(migration010, /brain_vault_update/);
  assert.match(migration010, /schema_version=10/i);
  assert.match(migration010, /'secure_cipher',\s*'AES-256-GCM'/i);
});

test('fresh-install schema exposes the same transport RPC names advertised by the contract', async () => {
  const schema = await readFile(new URL('../sql/schema.sql', import.meta.url), 'utf8');
  const claim = schema.match(/'claim_rpc',\s*'([^']+)'/i)?.[1];
  const finish = schema.match(/'finish_rpc',\s*'([^']+)'/i)?.[1];

  assert.equal(claim, 'claim_next_brain_command_v2');
  assert.equal(finish, 'finish_brain_command_v2');
  assert.equal(schema.toLowerCase().includes(`create or replace function public.${claim}()`), true);
  assert.equal(schema.toLowerCase().includes(`create or replace function public.${finish}(p jsonb)`), true);
});
