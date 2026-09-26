# Security model

## Worker authentication

The local worker signs in with a dedicated Supabase Auth account and uses only the publishable key plus its own password. No `service_role` key belongs on the worker.

`public.claim_next_brain_command()` and `public.finish_brain_command(...)` are SECURITY DEFINER RPCs because the public queue tables are otherwise closed by RLS. Both must keep the explicit `auth.uid()` allowlist check against `private.bridge_workers`.

## ChatGPT fast path

`private.brain_execute(...)` and `private.brain_result(...)` are intended only for a trusted Supabase management/SQL connector. They are deliberately kept in the `private` schema and EXECUTE is revoked from `public`, `anon`, and `authenticated`.

The fast-path procedure is SECURITY INVOKER. It must issue `COMMIT` after enqueueing so the external worker can see the command while the original ChatGPT tool call remains open.

PostgreSQL does not allow transaction control in a procedure that has a procedure-level `SET search_path` clause. For that reason the procedure uses fully-qualified table references and is not exposed to Data API roles. Supabase Advisor can still report a mutable-search-path warning for this procedure; treat that warning as a known constraint of this trusted-management fast path, not as permission to expose it publicly.

## Response minimization

ChatGPT receives a projection, not the raw queue row. The projection excludes worker IDs, request metadata, auth identifiers, and arbitrary raw result JSON.

For `brain_source_get`, the projection intentionally includes:

- exact `response_text`
- canonical vault-relative `source`
- `size_bytes`
- `sha256`

This preserves source integrity without exposing unrelated transport internals.

## Public / multi-user deployment

Do not expose the private SQL fast path directly to untrusted clients. Put an authenticated broker or MCP server in front of the queue and enforce per-user authorization there.
