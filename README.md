# Avenox Beyin ChatGPT Bridge

Independent community adapter that lets **ChatGPT Web** work with a live, local **Avenox Beyin V3** through the user's own Supabase project.

Upstream: `avenoxai/avenoxbeyin`.

**This repository is intentionally separate from Avenox Beyin core.** It does not require an Avenox core patch, does not add Node or Supabase as Avenox dependencies, and does not change Avenox's local-first defaults.

## Architecture

```text
ChatGPT Web
  -> user's Supabase project
  -> public.brain_commands queue
  -> authenticated local Bridge worker
  -> Avenox Beyin / beyin.py / vault
  -> brain_responses / command result
  -> ChatGPT Web
```

Supabase is the remote transport. Avenox Beyin remains the local source of truth.

## Current model — Bridge API v3

The worker discovers and publishes a live capability catalog at bootstrap. ChatGPT must use that catalog instead of guessing operation names or payloads.

Full Brain continuity is available through:

- `brain_vault_list`
- `brain_vault_get`
- `brain_vault_update`

These use the normal authenticated Supabase queue. There is no pairing token or client-side encryption requirement.

The vault path supports companion/private Brain Markdown needed for continuity, including files such as `Core.md`, `Soul.md`, `Kurallar.md`, `Last-Session.md`, `Threads.md`, and `Journal.md`.

## Security boundary

Full vault access is **not** remote shell access.

The Bridge keeps:

- dedicated authenticated worker identity and worker allowlist
- operation whitelist and payload validation
- versioned DB/worker transport handshake
- vault-root containment
- path traversal and symlink-escape rejection
- credential/runtime file denylist
- binary/unsafe source restrictions
- SHA-256 CAS for content updates
- revision-aware task transactions
- no arbitrary shell execution

Generic `brain_source_*` operations retain their conservative source/privacy behavior. Trusted continuity access uses the explicit `brain_vault_*` capabilities.

## Capabilities

The live catalog currently covers bootstrap/skills, context, exact source and vault access, notes, tasks, receipts, sync/history, skill sync, companion maintenance, preferences, Brain lifecycle/update operations and Jev controls.

Availability is runtime-probed. The bootstrap result is authoritative.

## Host model

The Bridge is host-agnostic. Termux is one supported host, not an architectural dependency.

Requirements:

- local Avenox Beyin V3
- Node.js 20+
- Python supported by Avenox Beyin
- user's Supabase project
- dedicated Supabase Auth worker user

## Install

```sh
sh scripts/install.sh
```

Managed checkout:

```text
~/.local/share/avenox-brain-bridge
```

Worker lifecycle:

```sh
avenox-bridge start
avenox-bridge status
avenox-bridge stop
```

Updates:

```sh
avenox-bridge update --check
avenox-bridge update
avenox-bridge rollback
```

The updater requires a clean Git checkout and fast-forward update. It runs the test suite before accepting the new revision and rolls back on failure.

## Database compatibility

Bridge code and Supabase transport schema are treated as one release contract.

Current worker requirement:

```text
transport schema >= 11
vault_transport = trusted_supabase_queue
```

Worker startup validates the live transport contract before claiming commands.

Database changes follow an expand-first migration order so an older worker can continue operating while the database is upgraded.

## Tests

```sh
npm test
```

The active suite includes:

- CLI and worker syntax gates
- worker process lifecycle
- updater/rollback behavior
- full-vault companion reads
- credential/runtime path rejection
- CAS and task safety
- capability normalization
- DB/worker version drift checks
- fresh-install PostgreSQL schema smoke test

GitHub CI must pass both the Node and PostgreSQL jobs.

## ChatGPT setup

Add `docs/CHATGPT-INSTRUCTIONS.md` to the private ChatGPT Project instructions and connect the user's Supabase project.

The Project instruction is deliberately small. The current Bridge behavior is loaded dynamically from bootstrap through:

- `bridge_skill`
- `bridge_capabilities`
- `core_skill`
- `skills_manifest`

## Relationship to Avenox Beyin

This is a **community remote adapter**, not an Avenox core feature.

Avenox core stays Python/local-first and does not manage this worker, Node, Supabase, or ChatGPT lifecycle. The Bridge consumes Avenox's existing public/local interfaces from outside the core.

The adapter can evolve independently without expanding the upstream project's default remote trust boundary or maintenance responsibility.

## License

MIT. Avenox Beyin is a separate upstream project and retains its own copyright/license notices.
