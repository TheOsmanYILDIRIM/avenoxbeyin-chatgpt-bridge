import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, readFile, rm, mkdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { checkUpdate, applyUpdate, rollbackUpdate } from '../src/updater.mjs';

const exec = promisify(execFile);

async function git(cwd, ...args) {
  const { stdout } = await exec('git', args, { cwd });
  return stdout.trim();
}

async function repoFixture(t) {
  const base = await mkdtemp(join(tmpdir(), 'avenox-updater-test-'));
  t.after(() => rm(base, { recursive:true, force:true }));
  const remote = join(base, 'remote.git');
  const work = join(base, 'work');
  const source = join(base, 'source');
  await mkdir(source);

  await git(base, 'init', '--bare', remote);
  await git(source, 'init', '-b', 'main');
  await git(source, 'config', 'user.email', 'test@example.invalid');
  await git(source, 'config', 'user.name', 'Test');
  await writeFile(join(source, 'value.txt'), 'one\n');
  await git(source, 'add', '.');
  await git(source, 'commit', '-m', 'one');
  await git(source, 'remote', 'add', 'origin', remote);
  await git(source, 'push', '-u', 'origin', 'main');

  await git(base, 'clone', '-b', 'main', remote, work);
  return { base, remote, work, source };
}

test('git updater checks, fast-forwards and rolls back', async t => {
  const { work, source } = await repoFixture(t);
  assert.equal((await checkUpdate(work)).status, 'up_to_date');

  await writeFile(join(source, 'value.txt'), 'two\n');
  await git(source, 'add', '.');
  await git(source, 'commit', '-m', 'two');
  await git(source, 'push');

  assert.equal((await checkUpdate(work)).status, 'available');
  const updated = await applyUpdate(work, { testCommand:[process.execPath, ['--version']] });
  assert.equal(updated.status, 'updated');
  assert.equal(await readFile(join(work, 'value.txt'), 'utf8'), 'two\n');

  const rolled = await rollbackUpdate(work);
  assert.equal(rolled.status, 'rolled_back');
  assert.equal(await readFile(join(work, 'value.txt'), 'utf8'), 'one\n');
});

test('git updater refuses tracked local edits', async t => {
  const { work } = await repoFixture(t);
  await writeFile(join(work, 'value.txt'), 'local edit\n');
  await assert.rejects(() => checkUpdate(work), /local changes/);
});
