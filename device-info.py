#!/usr/bin/env python3
# =============================================================================
# AdSpace device info + signed commands — localhost:7224
# =============================================================================
# Always-on HTTP API with this Pi's version and hardware identity.
# Bound to 127.0.0.1 only. CPU serial is the unique id (not machine-id).
#
# Also installed to /opt/adspace/device-info.py by bootstrap.sh — keep both in sync.
#
#   GET  /            device info (identity + health)
#   GET  /api/info    same payload
#   GET  /health      {"ok": true, "health": {...}}
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
import glob
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


def _read_text(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except OSError:
        return None


def _read_int(path):
    text = _read_text(path)
    if text is None:
        return None
    try:
        return int(text.strip().split()[0], 0)
    except (ValueError, IndexError):
        return None


def _round(value, digits=1):
    if value is None:
        return None
    return round(float(value), digits)


# CPU% from /proc/stat deltas between requests — no sleep in the request path.
_cpu_lock = threading.Lock()
_cpu_prev = None  # (idle, total)
_cpu_percent = None


def _cpu_times():
    text = _read_text("/proc/stat")
    if not text:
        return None
    for line in text.splitlines():
        if not line.startswith("cpu "):
            continue
        parts = line.split()[1:]
        if len(parts) < 4:
            return None
        try:
            nums = [int(p) for p in parts[:8]]
        except ValueError:
            return None
        idle = nums[3] + (nums[4] if len(nums) > 4 else 0)
        return idle, sum(nums)
    return None


_cpu_prev = _cpu_times()


def cpu_percent():
    """Busy CPU since the previous sample. None until two samples exist."""
    global _cpu_prev, _cpu_percent
    times = _cpu_times()
    if times is None:
        return None
    with _cpu_lock:
        prev = _cpu_prev
        _cpu_prev = times
        if prev is None:
            return _cpu_percent
        idle_d = times[0] - prev[0]
        total_d = times[1] - prev[1]
        if total_d <= 0:
            return _cpu_percent
        busy = 1.0 - (idle_d / total_d)
        _cpu_percent = _round(max(0.0, min(100.0, busy * 100.0)), 1)
        return _cpu_percent


def loadavg():
    try:
        one, five, fifteen = os.getloadavg()
        return _round(one, 2), _round(five, 2), _round(fifteen, 2)
    except OSError:
        return None, None, None


def uptime_sec():
    text = _read_text("/proc/uptime")
    if not text:
        return None
    try:
        return int(float(text.split()[0]))
    except (ValueError, IndexError):
        return None


def cpu_temp_c():
    millideg = _read_int("/sys/class/thermal/thermal_zone0/temp")
    if millideg is None:
        return None
    return _round(millideg / 1000.0, 1)


def cpu_freq_mhz():
    freqs = []
    for path in glob.glob("/sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_cur_freq"):
        val = _read_int(path)
        if val is not None and val > 0:
            freqs.append(val)
    if not freqs:
        return None
    return int(round(sum(freqs) / len(freqs) / 1000.0))


def meminfo_bytes():
    text = _read_text("/proc/meminfo")
    if not text:
        return {}
    fields = {}
    for line in text.splitlines():
        if ":" not in line:
            continue
        key, rest = line.split(":", 1)
        try:
            fields[key] = int(rest.strip().split()[0]) * 1024
        except (ValueError, IndexError):
            continue
    return fields


def memory_stats(fields):
    total = fields.get("MemTotal")
    available = fields.get("MemAvailable")
    if not total or available is None:
        return None
    used = max(0, total - available)
    return {
        "totalBytes": total,
        "usedBytes": used,
        "availableBytes": available,
        "percent": _round(used * 100.0 / total, 1),
    }


def swap_stats(fields):
    if not fields:
        return None
    total = fields.get("SwapTotal") or 0
    free = fields.get("SwapFree") or 0
    used = max(0, total - free)
    return {
        "totalBytes": total,
        "usedBytes": used,
        "percent": _round(used * 100.0 / total, 1) if total else 0.0,
    }


def disk_stats(path="/"):
    try:
        st = os.statvfs(path)
    except OSError:
        return None
    total = st.f_frsize * st.f_blocks
    available = st.f_frsize * st.f_bavail
    if total <= 0:
        return None
    used = max(0, total - available)
    return {
        "path": path,
        "totalBytes": total,
        "usedBytes": used,
        "availableBytes": available,
        "percent": _round(used * 100.0 / total, 1),
    }


def fan_rpm():
    for path in sorted(glob.glob("/sys/class/hwmon/hwmon*/fan1_input")):
        val = _read_int(path)
        if val is not None and val >= 0:
            return val
    return None


_THROTTLE_BITS = (
    ("underVoltage", 0),
    ("freqCapped", 1),
    ("throttled", 2),
    ("softTempLimit", 3),
    ("underVoltageOccurred", 16),
    ("freqCappedOccurred", 17),
    ("throttledOccurred", 18),
    ("softTempLimitOccurred", 19),
)


def _parse_throttled(raw):
    flags = {"raw": raw}
    for name, bit in _THROTTLE_BITS:
        flags[name] = bool(raw & (1 << bit))
    return flags


def throttle_stats():
    """Pi under-voltage / thermal throttle flags. Null on non-Pi or if unavailable."""
    text = _read_text("/sys/devices/platform/soc/soc:firmware/get_throttled")
    if text:
        try:
            return _parse_throttled(int(text.strip(), 0))
        except ValueError:
            pass
    try:
        result = subprocess.run(
            ["vcgencmd", "get_throttled"],
            capture_output=True,
            text=True,
            timeout=1,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return None
    out = (result.stdout or "").strip()
    if "=" in out:
        out = out.split("=", 1)[-1]
    try:
        return _parse_throttled(int(out, 0))
    except ValueError:
        return None


def health():
    load1, load5, load15 = loadavg()
    mem = meminfo_bytes()
    return {
        "uptimeSec": uptime_sec(),
        "cpu": {
            "percent": cpu_percent(),
            "load1": load1,
            "load5": load5,
            "load15": load15,
            "tempC": cpu_temp_c(),
            "freqMhz": cpu_freq_mhz(),
        },
        "memory": memory_stats(mem),
        "swap": swap_stats(mem),
        "disk": disk_stats("/"),
        "fanRpm": fan_rpm(),
        "throttle": throttle_stats(),
    }


def info():
    return {
        "version": version(),
        "serial": cpu_serial(),
        "hostname": socket.gethostname(),
        "model": model(),
        "mode": "setup" if os.path.exists(SETUP_FLAG) else "kiosk",
        "health": health(),
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
            self._send(200, {"ok": True, "health": health()})
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
