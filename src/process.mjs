import { spawn } from 'node:child_process';
import { readFile, writeFile, rm } from 'node:fs/promises';
import { resolve } from 'node:path';
import { DEFAULT_ROOT } from './updater.mjs';

const STATE = '.bridge-worker.json';

function alive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

async function readState(root) {
  try {
    return JSON.parse(await readFile(resolve(root, STATE), 'utf8'));
  } catch {
    return null;
  }
}

export async function workerStatus(root = DEFAULT_ROOT) {
  const state = await readState(root);
  if (!state) return { running:false, configured:false };
  return {
    running: alive(state.pid),
    configured: true,
    pid: state.pid,
    started_at: state.started_at || null
  };
}

export async function startWorker(root = DEFAULT_ROOT, { entry } = {}) {
  const current = await workerStatus(root);
  if (current.running) return { status:'already_running', ...current };

  const cli = entry || resolve(root, 'src/cli.mjs');
  const child = spawn(process.execPath, [cli, 'run'], {
    cwd: root,
    detached: true,
    stdio: 'ignore',
    windowsHide: true,
    env: process.env
  });
  child.unref();

  const state = { pid: child.pid, started_at: new Date().toISOString() };
  await writeFile(resolve(root, STATE), JSON.stringify(state, null, 2) + '\n', 'utf8');

  await new Promise(r => setTimeout(r, 150));
  if (!alive(child.pid)) {
    await rm(resolve(root, STATE), { force:true });
    throw new Error('Bridge worker exited during startup.');
  }
  return { status:'started', running:true, ...state };
}

export async function stopWorker(root = DEFAULT_ROOT) {
  const state = await readState(root);
  if (!state) return { status:'already_stopped', running:false };

  if (alive(state.pid)) {
    try {
      process.kill(state.pid, 'SIGTERM');
    } catch {}
  }
  await rm(resolve(root, STATE), { force:true });
  return { status:'stopped', running:false, pid:state.pid };
}
