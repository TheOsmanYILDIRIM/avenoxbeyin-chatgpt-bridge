# ChatGPT project instructions

Use the connected Supabase project as the transport to the user's live Avenox Beyin.

## Bootstrap first

Before the first meaningful Avenox-backed task in a conversation, enqueue `avenox_bootstrap`.

The bootstrap response includes:
- current Brain version
- current core skill
- current skill manifest
- Bridge API version
- machine-readable Bridge capabilities

Use that live capability catalog. Never invent operation names or payload fields.

If the live bootstrap response is unavailable and the operation catalog is uncertain, read:

```sql
select private.brain_capabilities() as capabilities;
```

## Queue flow

Use the normal queue/result flow.

1. Insert one command into `public.brain_commands` with a unique idempotency key.
2. Wait long enough for the worker polling interval.
3. Read only that command's status and projected response from `public.brain_responses`.
4. If still pending/claimed/running, perform at most one additional result check unless the user explicitly asks to keep waiting.

Do not use the removed experimental `brain_execute` procedure.

Do not scan the whole response table or read unrelated command rows.

## Operation semantics

The bootstrap capability catalog is authoritative for:
- operation name
- read/write/maintenance mode
- description
- payload schema
- official Avenox mapping
- whether explicit user intent is required

Examples include context/source reads, note/task/receipt mutations, sync/history/skill-sync, companion compact, preferences, update/rollback/recover and Jev management.

## Important safety rules

- Never expose arbitrary shell execution.
- Do not translate an unknown request into a guessed CLI command.
- Use `brain_task_update` for task files instead of generic source replacement.
- `brain_source_update` requires the previously read SHA-256 and must fail on hash conflict.
- Update/rollback/recover and Jev mode changes require explicit user intent.
- Exact source reads return canonical Markdown content; do not summarize it before using it as source.
- Current project source code belongs in GitHub; Brain is for memory/context/decisions.

## Source priority

1. Live local Avenox Beyin through the Bridge.
2. GitHub for current project source code.
3. Google Drive only as fallback when the Bridge cannot provide the required Brain source.
