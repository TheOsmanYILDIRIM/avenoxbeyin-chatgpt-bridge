import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { readFile, writeFile, rm } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const execFileAsync = promisify(execFile);
const HERE = dirname(fileURLToPath(import.meta.url));
export const DEFAULT_ROOT = resolve(HERE, '..');
const STATE_FILE = '.bridge-update.json';

async function run(cmd, args, cwd, options = {}) {
  return execFileAsync(cmd, args, {
    cwd,
    windowsHide: true,
    maxBuffer: 8 * 1024 * 1024,
    ...options
  });
}

async function git(root, args) {
  const { stdout } = await run('git', args, root);
  return stdout.trim();
}

async function assertCheckout(root) {
  let top;
  try {
    top = await git(root, ['rev-parse', '--show-toplevel']);
  } catch {
    throw new Error('Bridge update requires a Git checkout. Reinstall once with scripts/install.sh.');
  }
  if (resolve(top) !== resolve(root)) throw new Error('Bridge root is not the Git checkout root.');
}

async function assertClean(root) {
  const dirty = await git(root, ['status', '--porcelain', '--untracked-files=no']);
  if (dirty) throw new Error('Tracked Bridge files have local changes. Commit or revert them before update.');
}

async function refs(root) {
  await assertCheckout(root);
  await assertClean(root);
  await git(root, ['fetch', '--quiet', 'origin', 'main']);
  return {
    current: await git(root, ['rev-parse', 'HEAD']),
    latest: await git(root, ['rev-parse', 'origin/main'])
  };
}

export async function checkUpdate(root = DEFAULT_ROOT) {
  const { current, latest } = await refs(root);
  return {
    status: current === latest ? 'up_to_date' : 'available',
    current,
    latest
  };
}

export async function applyUpdate(root = DEFAULT_ROOT, { testCommand } = {}) {
  const { current, latest } = await refs(root);
  if (current === latest) return { status:'up_to_date', current };

  try {
    await git(root, ['merge-base', '--is-ancestor', current, latest]);
  } catch {
    throw new Error('Update is not a fast-forward. Refusing to rewrite local history.');
  }

  const state = {
    previous: current,
    target: latest,
    updated_at: new Date().toISOString()
  };
  await writeFile(resolve(root, STATE_FILE), JSON.stringify(state, null, 2) + '\n', 'utf8');

  await git(root, ['merge', '--ff-only', 'origin/main']);
  const command = testCommand || [process.platform === 'win32' ? 'npm.cmd' : 'npm', ['test']];
  try {
    await run(command[0], command[1], root);
  } catch (error) {
    await git(root, ['reset', '--hard', current]);
    throw new Error('Updated code failed tests; automatically rolled back to ' + current.slice(0, 12));
  }

  return {
    status: 'updated',
    previous: current,
    current: latest,
    restart_required: true
  };
}

export async function rollbackUpdate(root = DEFAULT_ROOT) {
  await assertCheckout(root);
  await assertClean(root);

  let state;
  try {
    state = JSON.parse(await readFile(resolve(root, STATE_FILE), 'utf8'));
  } catch {
    throw new Error('No Bridge update is available to roll back.');
  }

  const current = await git(root, ['rev-parse', 'HEAD']);
  if (current !== state.target) {
    throw new Error('Current commit no longer matches the last update; refusing ambiguous rollback.');
  }

  await git(root, ['reset', '--hard', state.previous]);
  await rm(resolve(root, STATE_FILE), { force:true });
  return {
    status: 'rolled_back',
    previous: current,
    current: state.previous,
    restart_required: true
  };
}
