#!/usr/bin/env python3
# =============================================================================
# Sign an AdSpace device command packet (Ed25519).
# =============================================================================
# The matching public key lives on every Pi at /opt/adspace/command-pubkey
# (and in this repo as command-pubkey). Keep the private key out of git.
#
#   python3 sign-command.py --command reboot --device-id 4d919699
#   python3 sign-command.py --command info --device-id 4d919699 | \
#       curl -sS -X POST -H 'Content-Type: application/json' \
#         --data-binary @- http://127.0.0.1:7224/api/command
# =============================================================================

from __future__ import annotations

import argparse
import json
import os
import secrets
import sys
import time

REPO_DIR = os.path.dirname(os.path.abspath(__file__))
DEFAULT_KEY = os.path.join(REPO_DIR, "command-signing.key")


def load_private_key_bytes(path):
    with open(path, encoding="utf-8") as f:
        lines = [
            line.strip()
            for line in f
            if line.strip() and not line.lstrip().startswith("#")
        ]
    if not lines:
        raise SystemExit(f"empty private key file: {path}")
    text = lines[0]
    try:
        raw = bytes.fromhex(text)
    except ValueError as exc:
        raise SystemExit(f"private key must be 32-byte hex: {exc}") from exc
    if len(raw) != 32:
        raise SystemExit(f"private key must be 32 bytes, got {len(raw)}")
    return raw


def sign(priv, command, timestamp, nonce, device_id, args):
    try:
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    except ImportError as exc:
        raise SystemExit(
            "cryptography is required: python3 -m pip install cryptography"
        ) from exc
    msg = f"{command}.{timestamp}.{nonce}.{device_id}"
    if args is not None:
        msg += "." + json.dumps(args, separators=(",", ":"), sort_keys=True)
    key = Ed25519PrivateKey.from_private_bytes(priv)
    return key.sign(msg.encode("utf-8")).hex()


def main():
    parser = argparse.ArgumentParser(description="Sign an AdSpace device command packet")
    parser.add_argument("--key", default=DEFAULT_KEY, help="32-byte hex private key file")
    parser.add_argument("--command", required=True, help="info | reboot | indicate | restart-kiosk")
    parser.add_argument("--device-id", required=True, help="Pi CPU serial (8 chars)")
    parser.add_argument("--nonce", default="", help="hex nonce (random if omitted)")
    parser.add_argument("--timestamp", type=int, default=0, help="unix seconds (now if omitted)")
    parser.add_argument("--args", default="", help="optional JSON object included in the signature")
    args = parser.parse_args()

    priv_path = args.key
    if os.environ.get("ADSPACE_COMMAND_PRIVKEY", "").strip():
        priv = bytes.fromhex(os.environ["ADSPACE_COMMAND_PRIVKEY"].strip())
        if len(priv) != 32:
            raise SystemExit("ADSPACE_COMMAND_PRIVKEY must be 32-byte hex")
    else:
        if not os.path.isfile(priv_path):
            raise SystemExit(
                f"private key not found: {priv_path}\n"
                "Set ADSPACE_COMMAND_PRIVKEY or pass --key. Never commit this key."
            )
        priv = load_private_key_bytes(priv_path)

    extra = None
    if args.args:
        extra = json.loads(args.args)
        if not isinstance(extra, dict):
            raise SystemExit("--args must be a JSON object")

    timestamp = args.timestamp or int(time.time())
    nonce = args.nonce or secrets.token_hex(16)
    packet = {
        "command": args.command,
        "timestamp": timestamp,
        "nonce": nonce,
        "deviceId": args.device_id,
        "signature": sign(priv, args.command, timestamp, nonce, args.device_id, extra),
    }
    if extra is not None:
        packet["args"] = extra
    json.dump(packet, sys.stdout, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
