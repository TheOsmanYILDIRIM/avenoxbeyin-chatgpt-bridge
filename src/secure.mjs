import { readFile, writeFile, rename, chmod, rm } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  randomBytes, randomUUID, createCipheriv, createDecipheriv, hkdfSync
} from 'node:crypto';

const HERE = dirname(fileURLToPath(import.meta.url));
export const DEFAULT_BRIDGE_ROOT = resolve(HERE, '..');
export const PAIRING_STATE_FILE = '.bridge-pairings.json';
export const SECURE_ENVELOPE_VERSION = 1;
export const SECURE_CIPHER = 'AES-256-GCM';
const COMMAND_MAX_TTL_MS = 10 * 60 * 1000;
const CLOCK_SKEW_MS = 2 * 60 * 1000;

function b64u(value) {
  return Buffer.from(value).toString('base64url');
}

function fromB64u(value, name) {
  if (typeof value !== 'string' || !value) throw secureError('secure_envelope_invalid', `${name} required`);
  try {
    return Buffer.from(value, 'base64url');
  } catch {
    throw secureError('secure_envelope_invalid', `invalid ${name}`);
  }
}

function statePath(root) {
  return resolve(root, PAIRING_STATE_FILE);
}

async function loadState(root = DEFAULT_BRIDGE_ROOT) {
  try {
    const parsed = JSON.parse(await readFile(statePath(root), 'utf8'));
    if (parsed?.schema !== 1 || !parsed.pairs || typeof parsed.pairs !== 'object') {
      throw secureError('pairing_state_invalid', 'pairing state is invalid');
    }
    return parsed;
  } catch (error) {
    if (error?.code === 'ENOENT') return { schema:1, pairs:{} };
    throw error;
  }
}

async function saveState(root, state) {
  const path = statePath(root);
  const tmp = `${path}.${process.pid}.${Date.now()}.tmp`;
  await writeFile(tmp, JSON.stringify(state, null, 2) + '\n', { encoding:'utf8', mode:0o600 });
  await chmod(tmp, 0o600);
  await rename(tmp, path);
  await chmod(path, 0o600);
}

function pairingToken(pairId, secret) {
  return `AVX3.${pairId}.${b64u(secret)}`;
}

export function parsePairingToken(token) {
  if (typeof token !== 'string') throw secureError('pairing_token_invalid', 'pairing token required');
  const m = token.trim().match(/^AVX3\.([0-9a-f-]{36})\.([A-Za-z0-9_-]+)$/i);
  if (!m) throw secureError('pairing_token_invalid', 'invalid AVX3 pairing token');
  const secret = fromB64u(m[2], 'pairing secret');
  if (secret.length !== 32) throw secureError('pairing_token_invalid', 'pairing secret must be 32 bytes');
  return { pair_id:m[1].toLowerCase(), secret };
}

function deriveKey(secret) {
  return Buffer.from(hkdfSync(
    'sha256',
    secret,
    Buffer.from('avenox-bridge-v3', 'utf8'),
    Buffer.from('secure-vault-envelope', 'utf8'),
    32
  ));
}

function aadFor(e) {
  return Buffer.from([
    'AVX3',
    String(e.v),
    e.pair_id,
    e.purpose,
    e.operation,
    String(e.issued_at),
    e.expires_at == null ? '' : String(e.expires_at),
    e.nonce
  ].join('|'), 'utf8');
}

function validateEnvelopeShape(envelope, expectedOperation, expectedPurpose) {
  if (!envelope || typeof envelope !== 'object' || Array.isArray(envelope)) {
    throw secureError('secure_envelope_invalid', 'secure envelope must be an object');
  }
  if (envelope.v !== SECURE_ENVELOPE_VERSION) {
    throw secureError('secure_envelope_invalid', 'unsupported secure envelope version');
  }
  if (typeof envelope.pair_id !== 'string' || !envelope.pair_id) {
    throw secureError('secure_envelope_invalid', 'pair_id required');
  }
  if (envelope.purpose !== expectedPurpose) {
    throw secureError('secure_envelope_invalid', 'secure envelope purpose mismatch');
  }
  if (envelope.operation !== expectedOperation) {
    throw secureError('secure_envelope_invalid', 'secure envelope operation mismatch');
  }
  if (!Number.isInteger(envelope.issued_at)) {
    throw secureError('secure_envelope_invalid', 'issued_at must be integer milliseconds');
  }
  if (expectedPurpose === 'command' && !Number.isInteger(envelope.expires_at)) {
    throw secureError('secure_envelope_invalid', 'expires_at must be integer milliseconds');
  }
  const nonce = fromB64u(envelope.nonce, 'nonce');
  const tag = fromB64u(envelope.tag, 'tag');
  const ciphertext = fromB64u(envelope.ciphertext, 'ciphertext');
  if (nonce.length !== 12) throw secureError('secure_envelope_invalid', 'nonce must be 12 bytes');
  if (tag.length !== 16) throw secureError('secure_envelope_invalid', 'tag must be 16 bytes');
  return { nonce, tag, ciphertext };
}

function encryptJson(secret, pairId, operation, payload, {
  purpose='command',
  now=Date.now(),
  ttlMs=5 * 60 * 1000
} = {}) {
  const nonce = randomBytes(12);
  const envelope = {
    v: SECURE_ENVELOPE_VERSION,
    pair_id: pairId,
    purpose,
    operation,
    issued_at: Math.trunc(now),
    expires_at: purpose === 'command' ? Math.trunc(now + ttlMs) : null,
    nonce: b64u(nonce),
    ciphertext: '',
    tag: ''
  };
  const key = deriveKey(secret);
  const cipher = createCipheriv('aes-256-gcm', key, nonce);
  cipher.setAAD(aadFor(envelope));
  const plaintext = Buffer.from(JSON.stringify(payload), 'utf8');
  const ciphertext = Buffer.concat([cipher.update(plaintext), cipher.final()]);
  envelope.ciphertext = b64u(ciphertext);
  envelope.tag = b64u(cipher.getAuthTag());
  return envelope;
}

function decryptJson(secret, envelope, expectedOperation, expectedPurpose) {
  const { nonce, tag, ciphertext } = validateEnvelopeShape(
    envelope, expectedOperation, expectedPurpose
  );
  try {
    const key = deriveKey(secret);
    const decipher = createDecipheriv('aes-256-gcm', key, nonce);
    decipher.setAAD(aadFor(envelope));
    decipher.setAuthTag(tag);
    const plaintext = Buffer.concat([decipher.update(ciphertext), decipher.final()]);
    return JSON.parse(plaintext.toString('utf8'));
  } catch (error) {
    if (error?.code?.startsWith?.('secure_')) throw error;
    throw secureError('secure_auth_failed', 'secure envelope authentication failed');
  }
}

export async function createPairing(root = DEFAULT_BRIDGE_ROOT, {
  name='chatgpt-project',
  expiresDays=30,
  now=Date.now()
} = {}) {
  if (typeof name !== 'string' || !name.trim()) throw new Error('pairing name required');
  if (!Number.isInteger(expiresDays) || expiresDays < 1 || expiresDays > 365) {
    throw new Error('expiresDays must be 1..365');
  }
  const state = await loadState(root);
  const pairId = randomUUID();
  const secret = randomBytes(32);
  state.pairs[pairId] = {
    name: name.trim(),
    secret: b64u(secret),
    created_at: new Date(now).toISOString(),
    expires_at: new Date(now + expiresDays * 86400000).toISOString(),
    seen_nonces: {}
  };
  await saveState(root, state);
  return {
    pair_id: pairId,
    name: name.trim(),
    expires_at: state.pairs[pairId].expires_at,
    token: pairingToken(pairId, secret)
  };
}

export async function listPairings(root = DEFAULT_BRIDGE_ROOT, { now=Date.now() } = {}) {
  const state = await loadState(root);
  return Object.entries(state.pairs).map(([pair_id, pair]) => ({
    pair_id,
    name: pair.name,
    created_at: pair.created_at,
    expires_at: pair.expires_at,
    active: !pair.expires_at || Date.parse(pair.expires_at) > now
  }));
}

export async function revokePairing(root = DEFAULT_BRIDGE_ROOT, pairId) {
  const state = await loadState(root);
  const existed = Boolean(state.pairs[pairId]);
  delete state.pairs[pairId];
  if (existed) await saveState(root, state);
  return { pair_id:pairId, revoked:existed };
}

export async function secureTransportStatus(root = DEFAULT_BRIDGE_ROOT) {
  const pairs = await listPairings(root);
  return {
    version: 3,
    envelope_version: SECURE_ENVELOPE_VERSION,
    cipher: SECURE_CIPHER,
    paired: pairs.some(x => x.active),
    pairings: pairs
  };
}

export function encryptCommandWithToken(token, operation, payload, options = {}) {
  const { pair_id, secret } = parsePairingToken(token);
  return encryptJson(secret, pair_id, operation, payload, {
    ...options,
    purpose:'command'
  });
}

export function decryptResultWithToken(token, operation, envelope) {
  const { pair_id, secret } = parsePairingToken(token);
  if (envelope?.pair_id !== pair_id) throw secureError('secure_pairing_mismatch', 'pairing mismatch');
  return decryptJson(secret, envelope, operation, 'result');
}

export async function decryptPairedCommand(
  root,
  operation,
  envelope,
  { now=Date.now() } = {}
) {
  validateEnvelopeShape(envelope, operation, 'command');

  if (envelope.issued_at > now + CLOCK_SKEW_MS) {
    throw secureError('secure_clock_invalid', 'secure command is from the future');
  }
  if (envelope.expires_at <= now) {
    throw secureError('secure_command_expired', 'secure command expired');
  }
  if (envelope.expires_at - envelope.issued_at > COMMAND_MAX_TTL_MS) {
    throw secureError('secure_ttl_invalid', 'secure command TTL exceeds maximum');
  }
  if (envelope.issued_at < now - COMMAND_MAX_TTL_MS - CLOCK_SKEW_MS) {
    throw secureError('secure_command_expired', 'secure command is too old');
  }

  const state = await loadState(root);
  const pair = state.pairs[envelope.pair_id];
  if (!pair) throw secureError('secure_pairing_required', 'pairing not found');
  if (pair.expires_at && Date.parse(pair.expires_at) <= now) {
    throw secureError('secure_pairing_expired', 'pairing expired');
  }

  pair.seen_nonces ||= {};
  for (const [nonce, expiresAt] of Object.entries(pair.seen_nonces)) {
    if (!Number.isFinite(expiresAt) || expiresAt <= now) delete pair.seen_nonces[nonce];
  }
  if (pair.seen_nonces[envelope.nonce]) {
    throw secureError('secure_replay_rejected', 'secure command nonce already used');
  }

  const secret = fromB64u(pair.secret, 'stored pairing secret');
  if (secret.length !== 32) throw secureError('pairing_state_invalid', 'stored pairing secret invalid');
  const payload = decryptJson(secret, envelope, operation, 'command');

  pair.seen_nonces[envelope.nonce] = envelope.expires_at + CLOCK_SKEW_MS;
  await saveState(root, state);

  return {
    pair_id: envelope.pair_id,
    secret,
    payload
  };
}

export function encryptPairedResult(secureContext, operation, payload, { now=Date.now() } = {}) {
  return encryptJson(
    secureContext.secret,
    secureContext.pair_id,
    operation,
    payload,
    { purpose:'result', now }
  );
}

export async function clearPairingStateForTests(root = DEFAULT_BRIDGE_ROOT) {
  await rm(statePath(root), { force:true });
}

function secureError(code, message) {
  const error = new Error(message);
  error.code = code;
  return error;
}
