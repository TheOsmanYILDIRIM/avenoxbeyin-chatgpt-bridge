# Architecture

```text
ChatGPT Web / Supabase connector
        |
        | CALL private.brain_execute(...)
        v
Supabase queue (brain_commands)
        |
        | authenticated claim RPC
        v
Local worker (Node.js; Linux/macOS/Windows/Termux)
        |
        v
Avenox Beyin V3 / beyin.py / managed skills / vault
        |
        | finish_brain_command(...)
        v
brain_responses projection
        |
        +---- same open SQL call returns completed response
```

## Why the procedure commits

A PostgreSQL function cannot insert a queue item and then wait for another connection to process it inside the same uncommitted transaction: the worker cannot see the new row. `private.brain_execute` is therefore a PostgreSQL procedure. It inserts the command, commits it, and then polls the already-committed command while the same ChatGPT SQL tool call remains open.

This makes the common path one ChatGPT tool invocation even though the bridge may check the database several times internally.

## Timeout path

The procedure waits at most 20 seconds (12 seconds recommended). If the worker has not finished, it returns `{timed_out:true, command_id:...}`. ChatGPT then makes one `private.brain_result(command_id)` call. Thus:

- normal: 1 ChatGPT tool call
- slow/error recovery: 2 ChatGPT tool calls

## Security boundary

`private.brain_execute` and `private.brain_result` are not Data API endpoints. They are intended for a trusted Supabase management/SQL connector. Worker-facing RPCs remain authenticated through a dedicated Supabase Auth user checked against `private.bridge_workers`.

For public or multi-user deployments, place an authenticated broker/MCP server in front of the queue rather than exposing the private SQL fast path.

## Projection / no data loss

The bridge does not send the whole command row back to ChatGPT. It projects only:

- status
- response_kind
- source_refs
- response_text
- error (terminal failures)
- source/size_bytes/sha256 for exact source reads

For `brain_source_get`, `response_text` is the exact Markdown content produced by the worker. Omitting internal metadata does not truncate or summarize the source.
