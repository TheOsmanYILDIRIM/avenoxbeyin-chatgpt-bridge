#!/usr/bin/env node
import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { Bridge } from './worker.mjs';
import { DEFAULT_ROOT, checkUpdate, applyUpdate, rollbackUpdate } from './updater.mjs';
import { startWorker, stopWorker, workerStatus } from './process.mjs';

const args = process.argv.slice(2);
const command = args[0] || 'run';

if (command === 'update') {
  const extra = args.slice(1);
  if (extra.some(x => x !== '--check')) throw new Error('usage: avenox-bridge update [--check]');
  const result = extra.includes('--check') ? await checkUpdate() : await applyUpdate();
  console.log(JSON.stringify(result, null, 2));
} else if (command === 'rollback') {
  if (args.length !== 1) throw new Error('usage: avenox-bridge rollback');
  console.log(JSON.stringify(await rollbackUpdate(), null, 2));
} else if (command === 'start') {
  if (args.length !== 1) throw new Error('usage: avenox-bridge start');
  console.log(JSON.stringify(await startWorker(), null, 2));
} else if (command === 'stop') {
  if (args.length !== 1) throw new Error('usage: avenox-bridge stop');
  console.log(JSON.stringify(await stopWorker(), null, 2));
} else if (command === 'status') {
  if (args.length !== 1) throw new Error('usage: avenox-bridge status');
  console.log(JSON.stringify(await workerStatus(), null, 2));
} else {
  const configPath = process.env.AVENOX_BRIDGE_CONFIG || resolve(DEFAULT_ROOT, 'config.local.json');
  const config = JSON.parse(await readFile(configPath, 'utf8'));
  const bridge = new Bridge(config);

  if (command === 'run') await bridge.run();
  else if (command === 'doctor') console.log(JSON.stringify(await bridge.doctor(), null, 2));
  else throw new Error('unknown command: ' + command);
}
