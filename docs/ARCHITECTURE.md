# Architecture

```text
ChatGPT Web / Supabase connector
        |
        | insert command
        v
public.brain_commands
        |
        | authenticated worker claim RPC
        v
Local worker
(Linux / macOS / Windows / Termux)
        |
        | validated operation adapter
        v
Avenox Beyin V3 / beyin.py / managed skills / vault
        |
        | finish RPC + response projection
        v
public.brain_responses
        |
        v
ChatGPT reads only its command result
```

## Design goal

The Bridge is a safe remote API for Avenox Beyin, not a remote shell.

Every exposed operation has a machine-readable contract:
- name
- mode: read / write / maintenance
- description
- payload schema
- mapping to the official Avenox entry point
- explicit-user-intent requirement when relevant

The current catalog lives in `src/capabilities.mjs` and is also included in bootstrap output so an AI client can discover the live contract instead of guessing.

## Coverage

The generic worker covers the major functions described by the current Avenox skills:
- context, exact source read and history
- notes, tasks and receipts
- CAS-protected Markdown source updates + sync
- sync and skill-sync
- companion compact
- preferences read/update
- doctor
- update check, update, dismiss, rollback, recover
- Jev status/config/memory review
- dynamic bootstrap and skill reads

Operations that modify Markdown use constrained adapters. There is no arbitrary command or shell operation.

## Data integrity

Task writes use Avenox task transactions and revision checks.

Generic Markdown updates require:
1. an existing canonical Markdown source,
2. a previously observed SHA-256,
3. a matching current hash,
4. atomic replacement,
5. successful `beyin.py sync`.

If sync fails, the worker restores the prior source and attempts to re-sync.

## Transport

The standard transport is deliberately simple:
1. ChatGPT enqueues.
2. Worker polls and executes.
3. Worker writes a projected response.
4. ChatGPT reads the result.

An experimental long-running SQL procedure was removed because ChatGPT's Supabase security layer could reject it. The queue/result flow is slower but much more portable across ChatGPT plans and connectors.

## Security boundary

The worker uses a dedicated Supabase Auth account and a publishable key. Worker RPCs verify `auth.uid()` against `private.bridge_workers`.

The public queue tables remain RLS-protected and are not directly available to ordinary anon/authenticated Data API clients.
