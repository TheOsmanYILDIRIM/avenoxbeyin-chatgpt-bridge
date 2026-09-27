# Secure Pairing and Full Vault Mode

Bridge API v3 supports paired encrypted access to the Brain vault without exposing vault payloads to Supabase.

## Trust boundary

The pairing secret exists only in:

- the local managed Bridge installation;
- the intended private ChatGPT Project.

Supabase stores only encrypted command/result envelopes for secure vault operations.

TLS remains required. AES-256-GCM additionally authenticates the command and protects the payload at rest in the relay database.

## Create a pairing

```bash
avenox-bridge pair --name chatgpt-osman --expires-days 30
```

The returned `token` is secret. Copy it into the private ChatGPT Project instructions as `AVENOX_PAIRING_TOKEN=...`.

Do not place the token in Git, Supabase, screenshots, public chats, or logs.

Inspect and revoke:

```bash
avenox-bridge pair --list
avenox-bridge pair --revoke <PAIR_ID>
```

## Secure operations

- `brain_vault_list`
- `brain_vault_get`
- `brain_vault_update`

They require an AES-GCM envelope. Their capability `payload_schema` describes the decrypted inner payload.

Encrypted responses are read from `brain_commands.result`; no plaintext `brain_responses` row is produced for these operations.

## Security properties

- authenticated encryption (AES-256-GCM);
- per-command random nonce;
- replay rejection using a local nonce cache;
- short command expiry;
- operation name authenticated as AAD;
- local pairing expiry/revocation;
- vault-root containment and symlink escape rejection;
- explicit secret/runtime path denylist;
- CAS writes;
- task files continue to use revision-aware task update APIs;
- no arbitrary shell execution.

This makes the paired client trusted for Brain content while keeping the relay untrusted.
