# AGENTS.md

## Current handoff
Remote-first Brain Vault v4 rollout and initial seed are complete on Termux.

Done:
- Live Supabase `avenox-bridge` is on transport schema 12 with content-addressed Brain blobs, linear commit/change history, remote HEAD, per-replica base state and preserved three-way conflicts.
- Local repository updated to `main` (`bf9784ab39fa947ff8fc9661191f5f398615b2e8`).
- Test suite executed and passed 100% (47/47 passing tests).
- Initial safe-text Brain vault seed into Supabase completed via worker startup reconciliation.
- Direct remote operations (`head`, `list`, `find`, `search`, `read_range`, `get`, `context`, `conflicts`) verified against live Supabase RPC.
- Delta probe verified: unchanged remote HEAD probes perform zero file transfers and skip full local vault scans.
- `src/worker.mjs` `max_entries` boundary updated to 5000 to match SQL remote vault schema limit for full-vault reconciliation.

Verification:
- Resulting HEAD: `bf9784ab39fa947ff8fc9661191f5f398615b2e8`
- Test suite: 47 passed, 0 failed, duration ~29.2s.
- Live Remote Vault Status:
  - `schema_version`: 12 (`versioned_remote_vault_v1`)
  - `seeded`: true
  - `file_count`: 500
  - `tree_hash`: `e1c5dee30d5637bb40639cf3a41784b499c111c6cd812c20ee3612fb858a91e6`
  - `head_commit_seq`: 502
  - `open_conflicts`: 0 (`[]`)
- Worker Status: running (PID 4492, healthy, active delta polling).
- Termux Standby: Normal ChatGPT Brain reads and context retrievals are now fully remote-backed and no longer require Termux to be active. Termux can be safely stopped or kept as an optional background replica.

Open:
- No open conflicts or sync issues exist.

Next:
- Proceed with normal ChatGPT Brain operations using remote-first direct Supabase RPCs. Later worker starts on Termux will perform fast delta-only synchronization.
