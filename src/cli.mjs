#!/usr/bin/env node
import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { Bridge } from './worker.mjs';

const command = process.argv[2] || 'run';
const configPath = process.env.AVENOX_BRIDGE_CONFIG || resolve(process.cwd(), 'config.local.json');
const config = JSON.parse(await readFile(configPath, 'utf8'));
const bridge = new Bridge(config);

if (command === 'run') await bridge.run();
else if (command === 'doctor') console.log(JSON.stringify(await bridge.doctor(), null, 2));
else throw new Error(`unknown command: ${command}`);
