#!/usr/bin/env python3
"""Reference client for Avenox Bridge API v3 secure envelopes.

The pairing token is read from AVENOX_PAIRING_TOKEN by default. Never send
that token to Supabase; only the returned envelope is transport data.
"""

import argparse
import base64
import json
import os
import secrets
import time
import uuid

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

SECURE_ENVELOPE_VERSION = 1
MAX_TTL_MS = 10 * 60 * 1000


def _b64u(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def _unb64u(value: str) -> bytes:
    padding = "=" * (-len(value) % 4)
    return base64.urlsafe_b64decode(value + padding)


def parse_pairing_token(token: str):
    parts = token.strip().split(".")
    if len(parts) != 3 or parts[0] != "AVX3":
        raise ValueError("invalid AVX3 pairing token")
    pair_id = str(uuid.UUID(parts[1]))
    secret = _unb64u(parts[2])
    if len(secret) != 32:
        raise ValueError("pairing secret must be 32 bytes")
    return pair_id, secret


def derive_key(secret: bytes) -> bytes:
    return HKDF(
        algorithm=hashes.SHA256(),
        length=32,
        salt=b"avenox-bridge-v3",
        info=b"secure-vault-envelope",
    ).derive(secret)


def _aad(envelope: dict) -> bytes:
    expires = "" if envelope.get("expires_at") is None else str(envelope["expires_at"])
    fields = [
        "AVX3",
        str(envelope["v"]),
        envelope["pair_id"],
        envelope["purpose"],
        envelope["operation"],
        str(envelope["issued_at"]),
        expires,
        envelope["nonce"],
    ]
    return "|".join(fields).encode("utf-8")


def encrypt_command(token: str, operation: str, payload: dict, *, now_ms=None, ttl_ms=300000):
    if ttl_ms <= 0 or ttl_ms > MAX_TTL_MS:
        raise ValueError("ttl_ms must be within 1..600000")
    pair_id, secret = parse_pairing_token(token)
    now_ms = int(time.time() * 1000) if now_ms is None else int(now_ms)
    nonce = secrets.token_bytes(12)
    envelope = {
        "v": SECURE_ENVELOPE_VERSION,
        "pair_id": pair_id,
        "purpose": "command",
        "operation": operation,
        "issued_at": now_ms,
        "expires_at": now_ms + int(ttl_ms),
        "nonce": _b64u(nonce),
        "ciphertext": "",
        "tag": "",
    }
    plaintext = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    encrypted = AESGCM(derive_key(secret)).encrypt(nonce, plaintext, _aad(envelope))
    envelope["ciphertext"] = _b64u(encrypted[:-16])
    envelope["tag"] = _b64u(encrypted[-16:])
    return envelope


def decrypt_result(token: str, operation: str, envelope: dict):
    pair_id, secret = parse_pairing_token(token)
    if envelope.get("pair_id") != pair_id:
        raise ValueError("pairing mismatch")
    if envelope.get("v") != SECURE_ENVELOPE_VERSION:
        raise ValueError("unsupported envelope version")
    if envelope.get("purpose") != "result" or envelope.get("operation") != operation:
        raise ValueError("result envelope mismatch")
    nonce = _unb64u(envelope["nonce"])
    ciphertext = _unb64u(envelope["ciphertext"])
    tag = _unb64u(envelope["tag"])
    plaintext = AESGCM(derive_key(secret)).decrypt(
        nonce, ciphertext + tag, _aad(envelope)
    )
    return json.loads(plaintext.decode("utf-8"))


def _token():
    token = os.environ.get("AVENOX_PAIRING_TOKEN")
    if not token:
        raise SystemExit("AVENOX_PAIRING_TOKEN is required")
    return token


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)

    enc = sub.add_parser("encode")
    enc.add_argument("--operation", required=True)
    enc.add_argument("--payload", required=True)
    enc.add_argument("--ttl-ms", type=int, default=300000)

    dec = sub.add_parser("decode")
    dec.add_argument("--operation", required=True)
    dec.add_argument("--envelope", required=True)

    args = parser.parse_args()
    if args.command == "encode":
        payload = json.loads(args.payload)
        print(json.dumps(
            encrypt_command(_token(), args.operation, payload, ttl_ms=args.ttl_ms),
            ensure_ascii=False,
            separators=(",", ":"),
        ))
    else:
        envelope = json.loads(args.envelope)
        print(json.dumps(
            decrypt_result(_token(), args.operation, envelope),
            ensure_ascii=False,
            separators=(",", ":"),
        ))


if __name__ == "__main__":
    main()
