# Security model

## Worker authentication

The local worker signs in with a dedicated Supabase Auth account and uses only the publishable key plus its own password. No `service_role` key belongs on the worker.

`public.claim_next_brain_command()` and `public.finish_brain_command(...)` are SECURITY DEFINER RPCs because the queue tables are otherwise closed by RLS. Both keep an explicit `auth.uid()` allowlist check against `private.bridge_workers`.

## No remote shell

The Bridge is intentionally capability-based. There is no operation that accepts arbitrary executable names, shell strings or free-form CLI arguments.

Every operation is defined in `src/capabilities.mjs` and mapped to a validated worker adapter. The bootstrap response includes that catalog so an AI can discover the supported contract instead of inventing commands.

## Mutation safety

- Task creation/update always uses official Avenox transactions.
- Existing Markdown mutation requires the canonical source, the previously observed SHA-256 and replacement content.
- A hash mismatch returns conflict instead of overwriting concurrent changes.
- Task Markdown is rejected by generic source update.
- Generic source replacement is atomic and followed by `beyin.py sync`.
- If sync fails after replacement, the worker restores the previous file and attempts to re-sync.
- Update, rollback, recover and Jev mode/provider changes are marked as requiring explicit user intent in the capability catalog.

## Temporary files

Structured CLI payloads are written to a private temporary directory with restrictive permissions and removed after the operation. They are not written into the user's vault.

## Source reads

Exact source reads reject absolute paths, traversal, non-Markdown files, symlink escapes and oversized files. Basename lookup succeeds only for a unique exact basename.

## Response projection

ChatGPT receives projected response text and source references rather than unrestricted database rows. Internal worker IDs, authorization state and unrelated queue entries are not part of the normal response path.

## Public / multi-user deployment

The included Supabase pattern is designed for a trusted personal ChatGPT connector plus one or more explicitly allowlisted workers. For a public or multi-user service, put a dedicated authenticated broker/MCP server in front of the queue and enforce tenant authorization there.
