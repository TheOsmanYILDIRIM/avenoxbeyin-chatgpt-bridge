#!/usr/bin/env node
import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { Bridge } from './worker.mjs';
import { DEFAULT_ROOT, checkUpdate, applyUpdate, rollbackUpdate } from './updater.mjs';
import { startWorker, stopWorker, workerStatus } from './process.mjs';
import { createPairing, listPairings, revokePairing } from './secure.mjs';

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
} else if (command === 'pair') {
  const extra = args.slice(1);
  if (extra.length === 1 && extra[0] === '--list') {
    console.log(JSON.stringify({ pairings: await listPairings(DEFAULT_ROOT) }, null, 2));
  } else if (extra.length === 2 && extra[0] === '--revoke') {
    console.log(JSON.stringify(await revokePairing(DEFAULT_ROOT, extra[1]), null, 2));
  } else {
    let name = 'chatgpt-project';
    let expiresDays = 30;
    for (let i = 0; i < extra.length; i++) {
      if (extra[i] === '--name' && extra[i + 1]) {
        name = extra[++i];
      } else if (extra[i] === '--expires-days' && extra[i + 1]) {
        expiresDays = Number(extra[++i]);
      } else {
        throw new Error('usage: avenox-bridge pair [--name NAME] [--expires-days N] | --list | --revoke PAIR_ID');
      }
    }
    const pairing = await createPairing(DEFAULT_ROOT, { name, expiresDays });
    console.log(JSON.stringify({
      ...pairing,
      warning: 'Pairing token is a secret. Store it only in the intended private ChatGPT Project and do not send it through Supabase.'
    }, null, 2));
  }
} else {
  const configPath = process.env.AVENOX_BRIDGE_CONFIG || resolve(DEFAULT_ROOT, 'config.local.json');
  const config = JSON.parse(await readFile(configPath, 'utf8'));
  const bridge = new Bridge(config);

  if (command === 'run') await bridge.run();
  else if (command === 'doctor') console.log(JSON.stringify(await bridge.doctor(), null, 2));
  else throw new Error('unknown command: ' + command);
}
