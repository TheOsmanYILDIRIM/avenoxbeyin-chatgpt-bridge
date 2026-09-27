import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

test('worker, canonical schema and migration chain agree on transport v11', async () => {
  const [worker, schema, migration009, migration010, migration011] = await Promise.all([
    readFile(new URL('../src/worker.mjs', import.meta.url), 'utf8'),
    readFile(new URL('../sql/schema.sql', import.meta.url), 'utf8'),
    readFile(new URL('../sql/migrations/009_transport_contract_v3.sql', import.meta.url), 'utf8'),
    readFile(new URL('../sql/migrations/010_secure_paired_full_vault.sql', import.meta.url), 'utf8'),
    readFile(new URL('../sql/migrations/011_trusted_full_vault_transport.sql', import.meta.url), 'utf8')
  ]);

  assert.match(worker, /REQUIRED_TRANSPORT_SCHEMA\s*=\s*11/);
  assert.match(worker, /vault_transport !== 'trusted_supabase_queue'/);

  assert.match(schema, /values\s*\(true,\s*11\)/i);
  assert.match(schema, /'vault_transport',\s*'trusted_supabase_queue'/i);
  assert.doesNotMatch(schema, /'secure_cipher'/i);
  assert.doesNotMatch(schema, /'secure_envelope_version'/i);

  assert.match(migration009, /schema_version.*9|values\s*\(true,\s*9\)/i);
  assert.match(migration010, /schema_version=10/i);
  assert.match(migration011, /schema_version=11/i);
  assert.match(migration011, /'vault_transport',\s*'trusted_supabase_queue'/i);
});

test('fresh-install schema contains full-vault operations and dynamic claim/finish RPCs', async () => {
  const schema = await readFile(new URL('../sql/schema.sql', import.meta.url), 'utf8');

  for (const op of ['brain_vault_list','brain_vault_get','brain_vault_update']) {
    assert.match(schema, new RegExp(op));
  }

  const claim = schema.match(/'claim_rpc',\s*'([^']+)'/i)?.[1];
  const finish = schema.match(/'finish_rpc',\s*'([^']+)'/i)?.[1];
  assert.equal(claim, 'claim_next_brain_command_v2');
  assert.equal(finish, 'finish_brain_command_v2');
  assert.equal(schema.toLowerCase().includes(`create or replace function public.${claim}()`), true);
  assert.equal(schema.toLowerCase().includes(`create or replace function public.${finish}(p jsonb)`), true);
});
