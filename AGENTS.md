# AGENTS.md

## Current handoff
Remote-first Brain Vault v4 is implemented on `feature/remote-vault-v4`.

Done:
- Live Supabase `avenox-bridge` is on transport schema 12 with content-addressed Brain blobs, linear commit/change history, remote HEAD, per-replica base state and preserved three-way conflicts.
- Direct remote `brain_context` and vault list/find/search/read-range/get/update are defined for Termux-free Brain reads and CAS content writes once the vault is seeded.
- Task sources remain protected from generic writes; task/note/receipt semantic operations keep official Beyin transaction semantics and can stay durable/pending while the worker is offline.
- Termux is an optional replica/worker: startup reconciles once, successful local semantic mutations sync immediately, remote HEAD is probed every 5s without scanning the local vault, and a cached local mtime/SHA scan runs every 60s to catch out-of-band edits.
- Unchanged remote polls are HEAD-only; full content transfer happens only for the first seed or changed paths.
- `SKILL.v4.md`, API v4 capabilities, canonical schema and remote-vault unit tests are present.
- Duplicate experimental `020_remote_vault_shadow.sql` was removed.

Verification:
- Live migrations `remote_vault_v4`, `remote_vault_v4_indexes`, and `remote_vault_v4_source_guard` are applied.
- Live status: schema=12, seeded=false, file_count=0, open_conflicts=0.
- Final compatibility/polling head `edd3a064...` passed both Node and PostgreSQL schema smoke jobs.
- Supabase advisors show no new exposed-table/RLS problem. SECURITY DEFINER warnings correspond to authenticated worker RPCs that internally verify `private.bridge_workers`.

Open:
- Initial seed has not happened yet. It needs one start of the v4 worker after the branch is deployed/merged; after that normal Brain reads no longer require Termux.
- PR #1 is open against `main`; keep the normal branch/PR flow and do not direct-push main.
- After the first seed, confirm the published API v4 contract snapshot and test a remote read, CAS write, delta pull and deliberate conflict.

Next:
PR #1 is green at the recorded head; do not push directly to main. On the first v4 worker start, let startup seed finish, verify `remote_vault_status.seeded=true`, then Termux may be stopped; later worker starts are delta-only.
