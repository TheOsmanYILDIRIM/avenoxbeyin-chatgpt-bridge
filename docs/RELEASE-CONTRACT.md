# Bridge Release Contract

Bridge code and Supabase transport schema are one release unit.

## Mandatory release order

For any change that adds or changes an RPC, table, column, status, or transport payload:

1. Add an **expand-only** Supabase migration first.
2. Apply that migration to the live Supabase project.
3. Verify `public.bridge_transport_contract()` reports the required schema version and RPC names.
4. Only then merge/publish worker code that depends on it.
5. Run `npm test`.
6. Update the managed checkout.
7. Restart through `avenox-bridge stop && avenox-bridge start`.
8. Run one bootstrap E2E and verify `completed` + `brain_responses`.

Never publish worker code that references an RPC which is absent from the canonical schema/migrations.

## Runtime handshake

The worker must call the stable `bridge_transport_contract` RPC before claiming work.

If the live schema is older than `REQUIRED_TRANSPORT_SCHEMA`, startup must fail before any command is claimed.

Claim/finish RPC names come from the live transport contract rather than being hardcoded into the worker loop.

## Compatibility policy

Database changes are expand-first and backward compatible. Destructive cleanup/removal belongs in a later release only after all workers have moved to the new contract.

The canonical sources are:

- `sql/schema.sql` for fresh installs
- ordered files in `sql/migrations/` for upgrades
- `REQUIRED_TRANSPORT_SCHEMA` in `src/worker.mjs` for worker compatibility
