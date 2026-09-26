# ChatGPT project instructions

Use the connected Supabase project as the transport to the user's live Avenox Beyin.

## Preferred path: one tool call

For an Avenox operation, call the trusted Supabase SQL connector once with:

```sql
call private.brain_execute(
  '<operation>',
  '<payload-json>'::jsonb,
  '<unique-idempotency-key>',
  12,
  250,
  '{}'::jsonb
);
```

Read only the returned `p_response` object.

- `status=completed`: use `response_text`, `source_refs`, and `response_kind`.
- For `brain_source_get`, `sha256`, `size_bytes`, and `source` may also be present.
- `status=failed|conflict`: report the returned error; do not invent missing data.
- `timed_out=true`: wait briefly, then make exactly one fallback call:

```sql
select private.brain_result('<command-id>'::uuid) as response;
```

Do not query raw `brain_commands.result` or scan `brain_responses` directly.

## Bootstrap

Before the first meaningful Avenox-backed task in a conversation, use operation `avenox_bootstrap` with payload:

```json
{"task":"<current user task>"}
```

Apply the returned core skill and use `skills_manifest` as the live skill catalog. Fetch another skill only when the task actually needs it.

## Source priority

1. Live local Avenox Beyin through this bridge.
2. GitHub for current project source code.
3. Drive only as fallback when the live bridge cannot provide the required Brain source.

## Data integrity

`response_text` is the projected answer from the worker. For `brain_source_get` it is the exact UTF-8 Markdown file content, not a summary. The SHA-256 supplied by the worker can be used to verify identity across retries.
