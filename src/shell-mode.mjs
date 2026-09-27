import { readFile, writeFile, rename, chmod } from 'node:fs/promises';
import { resolve } from 'node:path';

export const SHELL_STATE_FILE = '.bridge-shell.json';

function pathFor(root) {
  return resolve(root, SHELL_STATE_FILE);
}

export async function shellModeStatus(root) {
  try {
    const value = JSON.parse(await readFile(pathFor(root), 'utf8'));
    return {
      enabled: value?.enabled === true,
      updated_at: typeof value?.updated_at === 'string' ? value.updated_at : null
    };
  } catch (error) {
    if (error?.code === 'ENOENT') return { enabled:false, updated_at:null };
    throw error;
  }
}

export async function setShellMode(root, enabled) {
  const path = pathFor(root);
  const tmp = `${path}.${process.pid}.${Date.now()}.tmp`;
  const state = {
    enabled: enabled === true,
    updated_at: new Date().toISOString()
  };
  await writeFile(tmp, JSON.stringify(state, null, 2) + '\n', {
    encoding:'utf8',
    mode:0o600
  });
  await chmod(tmp, 0o600);
  await rename(tmp, path);
  await chmod(path, 0o600);
  return state;
}
