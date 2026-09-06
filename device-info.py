#!/usr/bin/env python3
# =============================================================================
# AdSpace device info — localhost:7224
# =============================================================================
# Always-on HTTP API with this Pi's version and hardware identity.
# Bound to 127.0.0.1 only. CPU serial is the unique id (not machine-id).
#
# Also installed to /opt/adspace/device-info.py by bootstrap.sh — keep both in sync.
#
#   GET /           device info
#   GET /api/info   same payload
#   GET /health     {"ok": true}
# =============================================================================

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
import socket

LISTEN_HOST = "127.0.0.1"
LISTEN_PORT = 7224
VERSION_PATH = "/opt/adspace/version"
SETUP_FLAG = "/tmp/adspace-setup-mode"


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


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print(f"adspace-info: {self.address_string()} {fmt % args}", flush=True)

    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, OPTIONS")
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


def main():
    server = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), Handler)
    print(f"Adspace device info listening on {LISTEN_HOST}:{LISTEN_PORT}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
