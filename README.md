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

## Transport\n\nThe default transport is the normal queue/result flow: ChatGPT enqueues a command, the authenticated worker executes it locally, then ChatGPT reads that command's projected response. An experimental long-running SQL fast path was removed because some ChatGPT/Supabase security layers reject it.\n\n## Operations

The Bridge now exposes a machine-readable capability catalog covering context/source reads, note/task/receipt writes, sync/history/skill-sync, companion compact, preferences, update/rollback/recover, Jev controls, bootstrap and skill reads. The generic worker maps each operation to a validated Avenox entry point and never exposes arbitrary shell execution.

## Tests

```sh
npm test
```

The test suite covers the remote source privacy gate, CAS update behavior, structured Brain CLI error mapping, and capability discovery for commands dispatched outside the normal top-level help parser.

## Requirements

- Avenox Beyin V3 installed locally
- Node.js 20+
- Python supported by Avenox Beyin
- Supabase project
- Supabase Auth user dedicated to the worker

## Quick start

1. Apply `sql/schema.sql` to a Supabase project.
2. Create a normal Supabase Auth user for the worker.
3. Insert that user's UUID into `private.bridge_workers` from a trusted admin session.
4. Copy `examples/config.example.json` to `config.local.json`.
5. Put the worker password in the environment variable named by `worker_password_env`.
6. Run `npm start`.
7. Add `docs/CHATGPT-INSTRUCTIONS.md` to your ChatGPT Project instructions and connect the Supabase plugin.
8. Use the normal queue/result flow; do not use the removed experimental `brain_execute` procedure.

## Status

The generic worker now implements the Bridge API v2 capability catalog. It covers live context/source reads, note/task/receipt writes, sync/history/skill reconciliation, companion maintenance, preferences, update lifecycle and Jev controls through validated adapters. Bootstrap returns the machine-readable capability catalog so AI clients do not need to guess operation names or payloads.

The worker never exposes arbitrary shell execution. Existing Markdown replacement is CAS-protected with SHA-256 and task sources are forced through the official task transaction.

Exact remote source reads/writes also enforce a small privacy boundary: Companion/identity sources and Markdown explicitly marked private, local-only, or sensitive are rejected before content is returned or changed.

## Upstream contribution path

Once the adapter stabilizes, the integration can be proposed upstream as a ChatGPT Web client/bridge, similar in spirit to Avenox Beyin's other client integrations.

## License

MIT. Avenox Beyin is a separate upstream project and retains its own copyright/license notices.
