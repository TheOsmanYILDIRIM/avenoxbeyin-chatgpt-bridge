import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

test('installer preserves local pairing state with restrictive permissions', async () => {
  const script = await readFile(new URL('../scripts/install.sh', import.meta.url), 'utf8');
  assert.match(script, /\.bridge-pairings\.json/);
  assert.match(script, /chmod 600 "\$TMP\/\.bridge-pairings\.json"/);
});
