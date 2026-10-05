# AGENTS.md

## Current handoff
Remote-first Brain Vault v4 is being implemented on `feature/remote-vault-v4`.

Done:
- Supabase migration 020 adds content-addressed Brain blobs, commit/change history, remote HEAD, replica base state and preserved three-way conflicts.
- Live `avenox-bridge` DB is on transport schema 12 with an empty/unseeded remote vault.
- `src/remote-vault.mjs` adds delta replica reconciliation with a local mtime/SHA cache.
- Worker startup and successful semantic/local mutations trigger reconciliation; direct remote reads no longer conceptually depend on Termux once seeded.
- Bridge API is moving to v4 and the v4 skill defines remote-first/deferred-write behavior.

Verification:
- Migration 020 applied successfully on the live Supabase project.
- Live status after migration: seeded=false, file_count=0, open_conflicts=0, transport schema=12.
- Supabase advisors show no new exposed table/RLS issue; SECURITY DEFINER warnings are expected for authenticated worker RPCs that internally verify `private.bridge_workers`.

Open:
- Finish canonical schema/SQL smoke v12 alignment.
- Run GitHub CI and fix any Node/Postgres regressions.
- Initial vault seed requires one worker start after the v4 worker is deployed; subsequent sync is delta-only.

Next:
Update tests/schema, verify CI, then open/merge the PR through the normal branch flow. Do not bypass task revision semantics when resolving task-file conflicts.
