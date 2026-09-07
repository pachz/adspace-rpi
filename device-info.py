#!/usr/bin/env python3
# =============================================================================
# AdSpace device info + signed commands — localhost:7224
# =============================================================================
# Always-on HTTP API with this Pi's version and hardware identity.
# Bound to 127.0.0.1 only. CPU serial is the unique id (not machine-id).
#
# Also installed to /opt/adspace/device-info.py by bootstrap.sh — keep both in sync.
#
#   GET  /            device info
#   GET  /api/info    same payload
#   GET  /health      {"ok": true}
#   POST /api/command signed command packet (Ed25519)
#
# Command packet (JSON):
#   {
#     "command":   "reboot",
#     "timestamp": 1788770000,
#     "nonce":     "8f3c...",
#     "deviceId":  "4d919699",
#     "signature": "<hex or base64 Ed25519 sig>"
#   }
#
# Signature is Ed25519 over the UTF-8 message:
#   {command}.{timestamp}.{nonce}.{deviceId}
# Optional "args" object, when present, is appended:
#   {command}.{timestamp}.{nonce}.{deviceId}.{canonical_json_args}
# timestamp is the integer's decimal form (no leading zeros, no fraction).
# deviceId is this Pi's 8-char CPU serial (same as GET / serial).
# Public key: /opt/adspace/command-pubkey (32-byte hex), fleet-wide.
# =============================================================================

from __future__ import annotations

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import base64
import json
import os
import re
import socket
import subprocess
import threading
import time

LISTEN_HOST = "127.0.0.1"
LISTEN_PORT = 7224
VERSION_PATH = "/opt/adspace/version"
SETUP_FLAG = "/tmp/adspace-setup-mode"
PUBKEY_PATH = "/opt/adspace/command-pubkey"
NONCE_PATH = "/tmp/adspace-command-nonces.json"
INDICATE_PATH = "/opt/adspace/indicate.sh"

# Fleet command-signing public key (Ed25519). Overridden by PUBKEY_PATH.
DEFAULT_PUBKEY_HEX = "8079e2154dcb576d3e6b0ba000c909f39ced3d1efe070c9ac8626edc460b6041"

TIMESTAMP_SKEW_SEC = 120
MAX_BODY = 16384
NONCE_RE = re.compile(r"^[0-9a-fA-F]{16,128}$")
COMMAND_RE = re.compile(r"^[a-z][a-z0-9-]{0,63}$")
HEX_RE = re.compile(r"^[0-9a-fA-F]+$")

_nonce_lock = threading.Lock()


class PacketError(Exception):
    def __init__(self, status, error, extra=None):
        super().__init__(error)
        self.status = status
        self.error = error
        self.extra = extra or {}


class CommandError(Exception):
    pass


def cpu_serial():
    """Last 8 chars of the Pi CPU serial, or machine-id on QEMU/virt."""
    try:
        with open("/proc/cpuinfo", encoding="utf-8") as f:
            for line in f:
                if line.startswith("Serial"):
                    serial = line.split(":", 1)[-1].strip()
                    if serial:
                        return serial[-8:]
    except OSError:
        pass
    try:
        with open("/etc/machine-id", encoding="utf-8") as f:
            mid = f.read().strip()
            if mid:
                return mid[-8:]
    except OSError:
        pass
    return ""


def version():
    try:
        with open(VERSION_PATH, encoding="utf-8") as f:
            token = f.read().strip()
            if token:
                return token
    except OSError:
        pass
    return "unknown"


def model():
    try:
        with open("/proc/device-tree/model", "rb") as f:
            return f.read().decode("utf-8", "replace").rstrip("\x00").strip()
    except OSError:
        return ""


def info():
    return {
        "version": version(),
        "serial": cpu_serial(),
        "hostname": socket.gethostname(),
        "model": model(),
        "mode": "setup" if os.path.exists(SETUP_FLAG) else "kiosk",
    }


def _decode_bytes(value, expected_len, what):
    if not isinstance(value, str) or not value.strip():
        raise PacketError(400, f"invalid {what}")
    text = value.strip()
    raw = None
    if HEX_RE.fullmatch(text) and len(text) % 2 == 0:
        raw = bytes.fromhex(text)
    else:
        pad = "=" * (-len(text) % 4)
        for decoder in (base64.b64decode, base64.urlsafe_b64decode):
            try:
                raw = decoder(text + pad, validate=False)
                break
            except (ValueError, TypeError):
                continue
    if raw is None or (expected_len is not None and len(raw) != expected_len):
        raise PacketError(400, f"invalid {what}")
    return raw


def parse_ed25519_public_key(text):
    """32-byte hex/base64, or SPKI PEM (`-----BEGIN PUBLIC KEY-----`)."""
    if not isinstance(text, str) or not text.strip():
        raise PacketError(503, "invalid public key")
    text = text.strip().replace("\\n", "\n")
    if "BEGIN PUBLIC KEY" in text:
        try:
            from cryptography.hazmat.primitives import serialization
        except ImportError as exc:
            raise PacketError(503, "ed25519 unavailable") from exc
        try:
            key = serialization.load_pem_public_key(text.encode("utf-8"))
            raw = key.public_bytes(
                encoding=serialization.Encoding.Raw,
                format=serialization.PublicFormat.Raw,
            )
        except (ValueError, TypeError) as exc:
            raise PacketError(503, "invalid public key") from exc
        if len(raw) != 32:
            raise PacketError(503, "invalid public key")
        return raw
    lines = [
        line.strip()
        for line in text.splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]
    if not lines:
        raise PacketError(503, "invalid public key")
    return _decode_bytes(lines[0], 32, "public key")


def load_pubkey_bytes():
    text = DEFAULT_PUBKEY_HEX
    try:
        with open(PUBKEY_PATH, encoding="utf-8") as f:
            raw_text = f.read().strip()
            if raw_text:
                text = raw_text
    except OSError:
        pass
    return parse_ed25519_public_key(text)


def signed_message(command, timestamp, nonce, device_id, args=None):
    msg = f"{command}.{timestamp}.{nonce}.{device_id}"
    if args is not None:
        msg += "." + json.dumps(args, separators=(",", ":"), sort_keys=True)
    return msg.encode("utf-8")


def _load_nonces():
    try:
        with open(NONCE_PATH, encoding="utf-8") as f:
            data = json.load(f)
        if isinstance(data, dict):
            return {str(k): int(v) for k, v in data.items()}
    except (OSError, ValueError, TypeError):
        pass
    return {}


def _save_nonces(nonces):
    tmp = NONCE_PATH + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(nonces, f, separators=(",", ":"))
    os.replace(tmp, NONCE_PATH)


def consume_nonce(nonce, timestamp, now):
    cutoff = now - TIMESTAMP_SKEW_SEC
    with _nonce_lock:
        nonces = _load_nonces()
        stale = [k for k, ts in nonces.items() if ts < cutoff]
        for k in stale:
            del nonces[k]
        if nonce in nonces:
            raise PacketError(401, "replay")
        nonces[nonce] = int(timestamp)
        _save_nonces(nonces)


def verify_signature(pubkey_bytes, signature, message):
    try:
        from cryptography.exceptions import InvalidSignature
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
    except ImportError as exc:
        raise PacketError(503, "ed25519 unavailable") from exc
    try:
        Ed25519PublicKey.from_public_bytes(pubkey_bytes).verify(signature, message)
    except (InvalidSignature, ValueError) as exc:
        raise PacketError(401, "invalid signature") from exc


def parse_and_verify(body):
    if not isinstance(body, dict):
        raise PacketError(400, "invalid json")

    command = body.get("command")
    if not isinstance(command, str) or not COMMAND_RE.fullmatch(command):
        raise PacketError(400, "invalid command")

    try:
        timestamp = int(body.get("timestamp"))
    except (TypeError, ValueError):
        raise PacketError(400, "invalid timestamp") from None

    nonce = body.get("nonce")
    if not isinstance(nonce, str) or not NONCE_RE.fullmatch(nonce):
        raise PacketError(400, "invalid nonce")

    device_id = body.get("deviceId")
    if not isinstance(device_id, str) or not device_id:
        raise PacketError(400, "invalid deviceId")

    args = body.get("args")
    if args is not None and not isinstance(args, dict):
        raise PacketError(400, "invalid args")

    signature = _decode_bytes(body.get("signature"), 64, "signature")
    message = signed_message(command, timestamp, nonce, device_id, args)
    verify_signature(load_pubkey_bytes(), signature, message)

    serial = cpu_serial()
    if not serial or device_id != serial:
        raise PacketError(401, "wrong device")

    now = int(time.time())
    if abs(now - timestamp) > TIMESTAMP_SKEW_SEC:
        raise PacketError(
            401,
            "expired",
            {"timestamp": timestamp, "serverTime": now},
        )

    consume_nonce(nonce, timestamp, now)
    return {
        "command": command,
        "timestamp": timestamp,
        "nonce": nonce,
        "deviceId": device_id,
        "args": args or {},
    }


def _sudo(argv, timeout=30):
    result = subprocess.run(
        ["sudo", "-n", *argv],
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    if result.returncode != 0:
        err = (result.stderr or result.stdout or "command failed").strip()
        raise CommandError(err)
    return (result.stdout or "").strip()


def _reboot_soon():
    time.sleep(0.4)
    subprocess.run(["sudo", "-n", "reboot"], check=False)


def cmd_info(_packet):
    return info()


def cmd_reboot(_packet):
    threading.Thread(target=_reboot_soon, daemon=True).start()
    return {"scheduled": True}


def cmd_indicate(_packet):
    output = _sudo([INDICATE_PATH], timeout=30)
    return {"output": output}


def cmd_restart_kiosk(_packet):
    _sudo(["systemctl", "restart", "adspace-kiosk.service"], timeout=30)
    return {"restarted": True}


COMMANDS = {
    "info": cmd_info,
    "reboot": cmd_reboot,
    "indicate": cmd_indicate,
    "restart-kiosk": cmd_restart_kiosk,
}


def dispatch(packet):
    handler = COMMANDS.get(packet["command"])
    if handler is None:
        raise PacketError(400, "unknown command")
    return handler(packet)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print(f"adspace-info: {self.address_string()} {fmt % args}", flush=True)

    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")

    def _send(self, status, body):
        data = json.dumps(body, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self._cors()
        self.end_headers()
        self.wfile.write(data)

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors()
        self.end_headers()

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path in ("/", "/api", "/api/info"):
            self._send(200, info())
        elif path == "/health":
            self._send(200, {"ok": True})
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        if path != "/api/command":
            self._send(404, {"error": "not found"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self._send(400, {"error": "invalid content-length"})
            return
        if length < 2 or length > MAX_BODY:
            self._send(400, {"error": "invalid body"})
            return
        raw = self.rfile.read(length)
        try:
            body = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            self._send(400, {"error": "invalid json"})
            return
        try:
            packet = parse_and_verify(body)
            result = dispatch(packet)
        except PacketError as exc:
            payload = {"error": exc.error}
            payload.update(exc.extra)
            self._send(exc.status, payload)
            return
        except subprocess.TimeoutExpired:
            self._send(504, {"error": "command timed out"})
            return
        except CommandError as exc:
            self._send(500, {"error": str(exc)})
            return
        except Exception as exc:
            print(f"adspace-info: command failed: {exc}", flush=True)
            self._send(500, {"error": "command failed"})
            return
        self._send(200, {"ok": True, "command": packet["command"], "result": result})


def main():
    try:
        pubkey_hex = load_pubkey_bytes().hex()
    except PacketError as exc:
        pubkey_hex = f"unavailable ({exc.error})"
    server = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), Handler)
    print(f"Adspace device info listening on {LISTEN_HOST}:{LISTEN_PORT}", flush=True)
    print(f"command pubkey {pubkey_hex}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
