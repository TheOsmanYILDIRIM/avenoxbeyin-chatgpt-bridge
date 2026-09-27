import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

test('worker transport contract is represented in canonical schema and migration', async () => {
  const [worker, schema, migration] = await Promise.all([
    readFile(new URL('../src/worker.mjs', import.meta.url), 'utf8'),
    readFile(new URL('../sql/schema.sql', import.meta.url), 'utf8'),
    readFile(new URL('../sql/migrations/009_transport_contract_v3.sql', import.meta.url), 'utf8')
  ]);

  assert.match(worker, /REQUIRED_TRANSPORT_SCHEMA\s*=\s*9/);
  assert.match(worker, /bridge_transport_contract/);
  assert.doesNotMatch(worker, /rpc\('claim_next_brain_command_v2'/);
  assert.doesNotMatch(worker, /rpc\('finish_brain_command_v2'/);

  for (const sql of [schema, migration]) {
    assert.match(sql, /bridge_transport_meta/);
    assert.match(sql, /schema_version[^\n]*9|values\s*\(true,\s*9\)/i);
    assert.match(sql, /create or replace function public\.bridge_transport_contract\(\)/i);
    assert.match(sql, /create or replace function public\.claim_next_brain_command_v2\(\)/i);
    assert.match(sql, /create or replace function public\.finish_brain_command_v2\(p jsonb\)/i);
  }
});
