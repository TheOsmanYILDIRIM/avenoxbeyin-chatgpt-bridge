# Architecture

```text
ChatGPT Web / Supabase connector
        |
        | normal command OR paired AES-256-GCM envelope
        v
public.brain_commands
        |
        | authenticated worker claim RPC
        v
Local worker
(Linux / macOS / Windows / Termux)
        |
        +--> normal validated capability adapters
        |
        +--> secure paired vault adapter
        |      - AES-GCM authentication/decryption
        |      - expiry + replay rejection
        |      - vault-root/path/secret guards
        |
        v
Avenox Beyin V3 / beyin.py / managed skills / vault
        |
        | normal: finish RPC + projected response
        | secure: encrypted result envelope
        v
Supabase relay
        |
        v
ChatGPT reads only its command result
```

## Design goal

The Bridge is a safe remote API for Avenox Beyin, not a remote shell.

Bridge API v3 separates two trust levels:

- **unpaired remote operations**: conservative source/privacy boundary;
- **paired secure vault operations**: trusted Brain-content access over authenticated encryption.

Every exposed operation has a machine-readable contract:
- name
- mode: read / write / maintenance
- description
- payload schema
- mapping to the official Avenox entry point
- explicit-user-intent requirement when relevant
- `secure_transport_required` when the payload must be encrypted

The catalog lives in `src/capabilities.mjs` and bootstrap returns the live contract.

## Secure pairing

`avenox-bridge pair` creates a 32-byte shared secret locally and stores it in `.bridge-pairings.json` with mode 0600. The secret is never written to Supabase.

Secure commands use:

- HKDF-SHA256
- AES-256-GCM
- 12-byte random nonce
- authenticated operation name
- short command expiry
- local replay cache
- pairing expiry/revocation

Supabase sees the operation name and encrypted envelope, but not the vault path/content or secure result plaintext.

## Full-vault boundary

Paired capabilities:
- `brain_vault_list`
- `brain_vault_get`
- `brain_vault_update`

They can read normal Brain vault text, including companion/private Markdown such as `Core.md`, `Last-Session.md`, `Threads.md`, `Kurallar.md`, and `Journal.md`.

Security remains narrower than local shell access:
- no arbitrary shell
- no path traversal
- no symlink escape
- explicit credential/runtime denylist
- binary/secret DB/key files rejected
- writes restricted to safe content extensions
- hidden/runtime content is read-only where appropriate
- task sources still require revision-aware task operations
- updates remain SHA-256 CAS protected and sync-backed

## Data integrity

Task writes use Avenox task transactions and revision checks.

Content updates require a previously observed SHA-256. If sync fails, the worker restores the prior source and attempts to re-sync.

## Version handshake

Worker startup calls `bridge_transport_contract()` before claiming work.

The worker verifies:
- minimum transport schema version
- claim/finish RPC names
- secure envelope version
- cipher
- secure result location

An incompatible database therefore fails at startup instead of producing stuck commands.

## Release order

Database changes are expand-first:

1. add/apply backward-compatible migration;
2. verify live transport contract;
3. publish worker code;
4. pass Node + cross-language crypto + PostgreSQL tests;
5. update/restart worker;
6. run live bootstrap E2E.


## Remote-first Brain Vault v4

v4 makes Supabase the always-readable versioned Brain HEAD while keeping Avenox Beyin semantics intact.

```text
ChatGPT
  | direct reads / CAS content writes
  v
Supabase remote Brain HEAD
  - content-addressed blobs
  - linear commit/change sequence
  - source -> blob HEAD
  - FTS/source retrieval
  - preserved BASE/LOCAL/REMOTE conflicts
  ^
  | delta sync only after initial seed
  v
Termux worker
  - optional local replica
  - official beyin.py task/note/receipt transactions
  - AGY / local tools
```

Project repositories remain canonical in GitHub. The Brain mirror is for Brain/companion/tasks/knowledge continuity, not a second copy of project repositories.

Replica sync keeps a local `.bridge-vault-cache.json` with mtime/SHA, remote tree hash, commit cursor, remote path SHAs and per-path base SHAs. An unchanged HEAD costs one small status request; changed remote state is fetched from the commit cursor; changed local files alone are re-hashed. Three-way conflicts preserve both blob variants instead of using last-write-wins.

Generic remote content writes remain CAS protected and reject task sources. Task/note/receipt operations continue through official Beyin transactions; when the worker is offline their queue command can remain durable/pending and must not be duplicated.
