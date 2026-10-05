import { readFile, writeFile, rename } from 'node:fs/promises';
import { extname, resolve } from 'node:path';

const CACHE_VERSION = 1;
const SYNCABLE_EXTENSIONS = new Set([
  '.md','.txt','.json','.yaml','.yml','.toml','.csv','.tsv',
  '.py','.js','.mjs','.cjs','.ts','.tsx','.jsx','.html','.css','.sql','.sh','.ps1','.ini','.cfg'
]);

const shaOk = value => typeof value === 'string' && /^[a-f0-9]{64}$/i.test(value);
const obj = value => value && typeof value === 'object' && !Array.isArray(value) ? value : {};

export function planReplicaSync(localInput, remoteInput, baseInput) {
  const local = obj(localInput);
  const remote = obj(remoteInput);
  const base = obj(baseInput);
  const sources = [...new Set([...Object.keys(local), ...Object.keys(remote), ...Object.keys(base)])].sort();
  const actions = [];

  for (const source of sources) {
    const l = local[source]?.sha256 ?? local[source] ?? null;
    const r = remote[source]?.sha256 ?? remote[source] ?? null;
    const b = base[source]?.sha256 ?? base[source] ?? null;

    if (l && r && l === r) continue;
    if (!l && r) {
      actions.push({ source, action:'pull', local_sha256:null, remote_sha256:r, base_sha256:b });
      continue;
    }
    if (l && !r) {
      actions.push({ source, action:'push', local_sha256:l, remote_sha256:null, base_sha256:b });
      continue;
    }
    if (!l && !r) continue;

    if (b && l === b && r !== b) {
      actions.push({ source, action:'pull', local_sha256:l, remote_sha256:r, base_sha256:b });
    } else {
      // Server-side replica_push performs the authoritative three-way check and
      // records a preserved conflict when both sides diverged from base.
      actions.push({ source, action:'push', local_sha256:l, remote_sha256:r, base_sha256:b });
    }
  }

  return actions;
}

async function loadCache(path) {
  try {
    const parsed = JSON.parse(await readFile(path, 'utf8'));
    if (parsed?.version === CACHE_VERSION) {
      return {
        version:CACHE_VERSION,
        cursor_commit_seq:Number(parsed.cursor_commit_seq || 0),
        remote_tree_hash:typeof parsed.remote_tree_hash === 'string' ? parsed.remote_tree_hash : null,
        files:obj(parsed.files),
        base:obj(parsed.base),
        remote:obj(parsed.remote)
      };
    }
  } catch {}
  return {
    version:CACHE_VERSION,
    cursor_commit_seq:0,
    remote_tree_hash:null,
    files:{},
    base:{},
    remote:{}
  };
}

async function saveCache(path, value) {
  const temp = `${path}.tmp-${process.pid}-${Date.now()}`;
  await writeFile(temp, JSON.stringify(value), { encoding:'utf8', mode:0o600 });
  await rename(temp, path);
}

function syncable(entry, bridge) {
  const ext = extname(entry.source || '').toLowerCase();
  const maxBytes = Number(bridge.c.max_vault_file_bytes || 1048576);
  return SYNCABLE_EXTENSIONS.has(ext) && Number(entry.size_bytes || 0) <= maxBytes;
}

async function localManifest(bridge, cache) {
  const listed = await bridge.vaultList({ recursive:true, max_entries:5000 });
  if (listed.truncated) throw new Error('remote-vault local manifest exceeded 5000 files');

  const nextFiles = {};
  const local = {};
  for (const entry of listed.entries.filter(x => syncable(x, bridge))) {
    const prior = cache.files[entry.source];
    if (
      prior && shaOk(prior.sha256) &&
      Number(prior.size_bytes) === Number(entry.size_bytes) &&
      Number(prior.mtime_ms) === Number(entry.mtime_ms)
    ) {
      local[entry.source] = { sha256:prior.sha256, content:null };
      nextFiles[entry.source] = prior;
      continue;
    }

    try {
      const got = await bridge.vaultGet(entry.source);
      local[entry.source] = { sha256:got.sha256, content:got.content };
      nextFiles[entry.source] = {
        sha256:got.sha256,
        size_bytes:entry.size_bytes,
        mtime_ms:entry.mtime_ms
      };
    } catch (error) {
      if (error?.code !== 'binary_source_rejected') throw error;
    }
  }
  return { local, nextFiles };
}

async function ensureContent(bridge, local, source) {
  if (typeof local[source]?.content === 'string') return local[source].content;
  const got = await bridge.vaultGet(source);
  local[source] = { sha256:got.sha256, content:got.content };
  return got.content;
}

export async function syncRemoteVault(bridge, { reason='manual' } = {}) {
  const transport = await bridge.transportContract();
  if (
    transport?.remote_vault_transport !== 'versioned_remote_vault_v1' ||
    typeof transport?.remote_vault?.rpc !== 'string' ||
    typeof transport?.remote_vault?.replica_rpc !== 'string'
  ) {
    return { supported:false, reason:'remote_vault_unavailable' };
  }

  const rpcName = transport.remote_vault.rpc;
  const replicaRpc = transport.remote_vault.replica_rpc;
  const cachePath = bridge.c.remote_vault_cache_path ||
    resolve(bridge.bridgeRoot(), '.bridge-vault-cache.json');
  const cache = await loadCache(cachePath);
  const { local, nextFiles } = await localManifest(bridge, cache);

  const head = await bridge.rpc(rpcName, { p_operation:'head', p:{} });
  let remote = { ...cache.remote };
  let base = { ...cache.base };
  let cursor = Number(cache.cursor_commit_seq || 0);

  if (Object.keys(base).length === 0) {
    const state = await bridge.rpc(replicaRpc, { p_operation:'state', p:{} });
    base = Object.fromEntries((state?.paths || [])
      .filter(x => x?.source && shaOk(x.base_sha256))
      .map(x => [x.source, x.base_sha256]));
    cursor = Math.max(cursor, Number(state?.cursor_commit_seq || 0));
  }

  if (Object.keys(remote).length === 0 && Number(head?.file_count || 0) > 0) {
    const listed = await bridge.rpc(rpcName, {
      p_operation:'list',
      p:{ max_entries:5000 }
    });
    remote = Object.fromEntries((listed?.entries || [])
      .filter(x => x?.source && shaOk(x.sha256))
      .map(x => [x.source, x.sha256]));
  } else if (cache.remote_tree_hash !== head?.tree_hash) {
    for (;;) {
      const delta = await bridge.rpc(replicaRpc, {
        p_operation:'changes',
        p:{ since:cursor, limit:1000 }
      });
      const changes = Array.isArray(delta?.changes) ? delta.changes : [];
      if (changes.length === 0) break;
      for (const change of changes) {
        if (!change?.source) continue;
        if (change.operation === 'delete' || !shaOk(change.new_sha256)) delete remote[change.source];
        else remote[change.source] = change.new_sha256;
        cursor = Math.max(cursor, Number(change.commit_seq || 0));
      }
      if (changes.length < 1000 || cursor >= Number(delta?.remote?.head_commit_seq || cursor)) break;
    }
  }

  const localForPlan = Object.fromEntries(Object.entries(local).map(([k,v]) => [k,v.sha256]));
  const actions = planReplicaSync(localForPlan, remote, base);
  const ack = [];
  const conflicts = [];
  let changedLocal = false;

  for (const action of actions) {
    if (action.action === 'pull') {
      const got = await bridge.rpc(rpcName, { p_operation:'get', p:{ source:action.source } });
      if (!got?.found || !shaOk(got.sha256)) continue;
      try {
        await bridge.vaultReplicaApply({
          source:action.source,
          expected_sha256:action.local_sha256,
          content:got.content
        });
      } catch (error) {
        // A local edit raced the pull. Send the new local side through replica_push
        // so the server preserves both variants instead of overwriting either.
        if (error?.code !== 'conflict') throw error;
        const latest = await bridge.vaultGet(action.source);
        const raced = await bridge.rpc(replicaRpc, {
          p_operation:'push',
          p:{
            source:action.source,
            base_sha256:action.base_sha256,
            content:latest.content,
            actor:'termux-replica'
          }
        });
        if (raced?.action === 'conflict') conflicts.push(action.source);
        continue;
      }
      remote[action.source] = got.sha256;
      base[action.source] = got.sha256;
      nextFiles[action.source] = { sha256:got.sha256, size_bytes:got.size_bytes, mtime_ms:null };
      ack.push({ source:action.source, sha256:got.sha256 });
      changedLocal = true;
      continue;
    }

    const content = await ensureContent(bridge, local, action.source);
    const pushed = await bridge.rpc(replicaRpc, {
      p_operation:'push',
      p:{
        source:action.source,
        base_sha256:action.base_sha256,
        content,
        actor:'termux-replica'
      }
    });

    if (pushed?.action === 'download' && shaOk(pushed.sha256)) {
      await bridge.vaultReplicaApply({
        source:action.source,
        expected_sha256:action.local_sha256,
        content:pushed.content
      });
      remote[action.source] = pushed.sha256;
      base[action.source] = pushed.sha256;
      nextFiles[action.source] = {
        sha256:pushed.sha256,
        size_bytes:Buffer.byteLength(pushed.content || '', 'utf8'),
        mtime_ms:null
      };
      ack.push({ source:action.source, sha256:pushed.sha256 });
      changedLocal = true;
    } else if ((pushed?.action === 'uploaded' || pushed?.action === 'clean') && shaOk(pushed.sha256)) {
      remote[action.source] = pushed.sha256;
      base[action.source] = pushed.sha256;
      ack.push({ source:action.source, sha256:pushed.sha256 });
    } else if (pushed?.action === 'conflict') {
      conflicts.push(action.source);
    }
  }

  if (changedLocal || actions.some(x => x.action === 'push')) {
    await bridge.runBeyin('sync');
  }

  const finalHead = await bridge.rpc(rpcName, { p_operation:'head', p:{} });
  if (ack.length > 0 || actions.length > 0 || cache.remote_tree_hash !== finalHead?.tree_hash) {
    await bridge.rpc(replicaRpc, {
      p_operation:'ack',
      p:{
        entries:ack,
        cursor_commit_seq:Number(finalHead?.head_commit_seq || cursor),
        tree_hash:finalHead?.tree_hash || null
      }
    });
  }

  const nextCache = {
    version:CACHE_VERSION,
    cursor_commit_seq:Number(finalHead?.head_commit_seq || cursor),
    remote_tree_hash:finalHead?.tree_hash || null,
    files:nextFiles,
    base,
    remote
  };
  await saveCache(cachePath, nextCache);

  return {
    supported:true,
    reason,
    scanned_files:Object.keys(local).length,
    actions:actions.length,
    changed_local:changedLocal,
    conflicts,
    head:finalHead
  };
}
