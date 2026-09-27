# Avenox Beyin ChatGPT Bridge

A host-agnostic bridge that lets **ChatGPT Web** use the live, local **Avenox Beyin V3** memory and skill system through Supabase.

Upstream project: `avenoxai/avenoxbeyin` (Avenox Beyin V3). This repository is an independent integration/adapter and does not replace the upstream Brain engine.

## Why

ChatGPT Web cannot directly execute a user's local `beyin.py`. This bridge turns Supabase into a narrow command/result transport while the real Brain stays local and authoritative.

```text
ChatGPT Web
  -> enqueue one brain_commands row
  -> Supabase brain_commands
  -> local worker (Linux/macOS/Windows/Termux/etc.)
  -> Avenox Beyin / beyin.py / live skills
  -> brain_responses
  -> same open ChatGPT tool call returns the result
```

## Goals

- no Termux dependency
- no service-role secret on the worker
- preserve Avenox Beyin transaction semantics
- dynamically expose current Avenox skills to ChatGPT
- keep project source code in GitHub, not in Brain
- use Drive only as an optional readable fallback
- warn about an unavailable worker from an unclaimed pending command, without idle heartbeat writes

## Transport

The default transport is the normal queue/result flow: ChatGPT enqueues a command, the authenticated worker executes it locally, then ChatGPT reads that command's projected response.

Bridge API v3 adds an optional **paired secure full-vault path** for trusted ChatGPT Projects. Secure vault commands use AES-256-GCM envelopes; Supabase carries ciphertext while the pairing secret remains only in the local Bridge installation and the intended private ChatGPT Project. Secure results are returned encrypted in `brain_commands.result`, not plaintext `brain_responses`.

## Operations

The Bridge now exposes a machine-readable capability catalog covering context/source reads, note/task/receipt writes, sync/history/skill-sync, companion compact, preferences, update/rollback/recover, Jev controls, bootstrap and skill reads. The generic worker maps each operation to a validated Avenox entry point and never exposes arbitrary shell execution.

## Tests

```sh
npm test
```

The test suite covers CAS updates, structured Brain CLI error mapping, capability discovery, transport-contract drift, secure pairing, tamper/replay rejection, companion/full-vault access rules, Python↔Node crypto interoperability, and a real PostgreSQL fresh-install schema smoke test.

## Requirements

- Avenox Beyin V3 installed locally
- Node.js 20+
- Python supported by Avenox Beyin
- Supabase project
- Supabase Auth user dedicated to the worker

## Install and update

For a managed local checkout, install once:

```sh
sh scripts/install.sh
```

The installer clones the Bridge to `~/.local/share/avenox-brain-bridge`, runs the tests, and creates an `avenox-bridge` command under `~/.local/bin`. If an older non-Git Bridge already exists there, it is moved to a timestamped backup first; `config.local.json` and `.env` are copied into the new checkout instead of being discarded.

After that, updates follow the same small command shape as Avenox Beyin:

```sh
avenox-bridge update --check
avenox-bridge update
avenox-bridge rollback
```

The updater only accepts a clean Git checkout and a fast-forward from `origin/main`. It runs `npm test` after updating; if the tests fail, it automatically resets to the previous commit. `config.local.json` and `.env` are ignored by Git and remain untouched. A successful update returns `restart_required: true`; restart the existing worker process so it loads the new code.

## Quick start

1. Apply `sql/schema.sql` to a Supabase project.
2. Create a normal Supabase Auth user for the worker.
3. Insert that user's UUID into `private.bridge_workers` from a trusted admin session.
4. Copy `examples/config.example.json` to `config.local.json`.
5. Put the worker password in the environment variable named by `worker_password_env`.
6. Run `npm start`.
7. Add `docs/CHATGPT-INSTRUCTIONS.md` to your ChatGPT Project instructions and connect the Supabase plugin.
8. Use the normal queue/result flow; do not use the removed experimental `brain_execute` procedure.
9. Optional full-vault mode: run `avenox-bridge pair --name chatgpt-project`, store the returned token only in the intended private ChatGPT Project, and follow `docs/SECURE-PAIRING.md`.

## Status

The generic worker now implements Bridge API v3. Bootstrap returns the versioned Bridge skill, capability catalog, Avenox core skill, skill manifest, and secure-pairing status so AI clients do not guess operation names, payloads, or transport behavior.

The worker never exposes arbitrary shell execution. Existing Markdown replacement is CAS-protected with SHA-256 and task sources are forced through the official task transaction.

Unpaired exact source operations retain the conservative remote privacy gate. Paired secure operations (`brain_vault_list`, `brain_vault_get`, `brain_vault_update`) can access the trusted Brain vault, including companion/private Markdown, while still blocking obvious credential/runtime files, path traversal, symlink escape, binary sources, and unsafe remote writes.

## Upstream contribution path

Once the adapter stabilizes, the integration can be proposed upstream as a ChatGPT Web client/bridge, similar in spirit to Avenox Beyin's other client integrations.

## License

MIT. Avenox Beyin is a separate upstream project and retains its own copyright/license notices.
