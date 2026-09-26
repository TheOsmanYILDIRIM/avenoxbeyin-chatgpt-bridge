# Avenox Beyin ChatGPT Bridge

A host-agnostic bridge that lets **ChatGPT Web** use the live, local **Avenox Beyin V3** memory and skill system through Supabase.

Upstream project: `avenoxai/avenoxbeyin` (Avenox Beyin V3). This repository is an independent integration/adapter and does not replace the upstream Brain engine.

## Why

ChatGPT Web cannot directly execute a user's local `beyin.py`. This bridge turns Supabase into a narrow command/result transport while the real Brain stays local and authoritative.

```text
ChatGPT Web
  -> one CALL private.brain_execute(...)
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

## One-call fast path

With the trusted Supabase SQL connector, `private.brain_execute(...)` commits the queue item, keeps the same tool call open, and returns the worker result when ready. The normal path is therefore **one ChatGPT tool call**. If the configured timeout expires, use `private.brain_result(command_id)` once as fallback.

The projection preserves full `response_text`; exact source reads also return `sha256`, `size_bytes`, and `source`. Internal worker/auth/raw-result metadata is not exposed.

## Operations

Read-only core:
- `avenox_bootstrap`
- `avenox_skill_get`
- `brain_context`
- `brain_source_get`
- `brain_doctor`

Mutation operations are part of the protocol and should map only to official `beyin.py` entry points:
- `brain_note_create`
- `brain_task_create`
- `brain_task_update`
- `brain_receipt`

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
8. Prefer `CALL private.brain_execute(...)`; raw response-table SELECTs are unnecessary.

## Status

This repository currently packages the architecture proven in a live ChatGPT Web <-> Supabase <-> local Avenox Beyin deployment. Read-only bootstrap/context/skill/source operations are implemented in the generic worker. Mutation adapters are intentionally documented but not yet enabled in the generic worker until cross-platform temp-file handling is finalized.

## Upstream contribution path

Once the adapter stabilizes, the integration can be proposed upstream as a ChatGPT Web client/bridge, similar in spirit to Avenox Beyin's other client integrations.

## License

MIT. Avenox Beyin is a separate upstream project and retains its own copyright/license notices.
