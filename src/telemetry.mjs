import { appendFile, readFile, stat, rename, rm } from 'node:fs/promises';
import { resolve } from 'node:path';

export const COMMAND_LOG_FILE = '.bridge-command-log.jsonl';
export const DEFAULT_MAX_LOG_BYTES = 5 * 1024 * 1024;

function logPath(root) {
  return resolve(root, COMMAND_LOG_FILE);
}

function rotatedPath(root) {
  return resolve(root, COMMAND_LOG_FILE + '.1');
}

export async function appendCommandLog(root, entry, { maxBytes = DEFAULT_MAX_LOG_BYTES } = {}) {
  const path = logPath(root);
  const line = JSON.stringify(entry) + '\n';

  try {
    const info = await stat(path);
    if (info.size + Buffer.byteLength(line, 'utf8') > maxBytes) {
      await rm(rotatedPath(root), { force:true });
      await rename(path, rotatedPath(root));
    }
  } catch (error) {
    if (error?.code !== 'ENOENT') throw error;
  }

  await appendFile(path, line, { encoding:'utf8', mode:0o600 });
}

export async function readCommandLog(root, { limit = 50 } = {}) {
  if (!Number.isInteger(limit) || limit < 1 || limit > 1000) {
    throw new Error('limit must be 1..1000');
  }

  let text;
  try {
    text = await readFile(logPath(root), 'utf8');
  } catch (error) {
    if (error?.code === 'ENOENT') return [];
    throw error;
  }

  const lines = text.trim().split(/\r?\n/).filter(Boolean);
  const out = [];
  for (const line of lines.slice(-limit)) {
    try {
      out.push(JSON.parse(line));
    } catch {
      out.push({ malformed:true, raw:line });
    }
  }
  return out;
}
