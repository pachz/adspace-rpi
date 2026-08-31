#!/usr/bin/env python3
"""HTTP caching proxy for QEMU apt.

Caches *.deb (and friends) under a host directory so `qemu-run.sh --fresh`
does not re-download Chromium et al. Package indexes are always fetched live.
"""
from __future__ import annotations

import argparse
import fcntl
import os
import select
import socket
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse
from urllib.request import Request, urlopen

CACHE_SUFFIXES = (".deb", ".ddeb", ".udeb")


def cacheable(url: str) -> bool:
    return urlparse(url).path.lower().endswith(CACHE_SUFFIXES)


def cache_path(root: Path, url: str) -> Path:
    parsed = urlparse(url)
    rel = Path(parsed.netloc) / parsed.path.lstrip("/")
    if parsed.query:
        rel = rel.parent / f"{rel.name}?{parsed.query}"
    # Reject path traversal
    out = (root / rel).resolve()
    if not str(out).startswith(str(root.resolve())):
        raise ValueError(f"refusing cache path outside root: {url}")
    return out


class Handler(BaseHTTPRequestHandler):
    cache_root: Path

    def log_message(self, fmt: str, *args: object) -> None:
        sys.stderr.write("[apt-proxy] " + (fmt % args) + "\n")

    def do_CONNECT(self) -> None:
        host_port = self.path.split(":", 1)
        host = host_port[0]
        port = int(host_port[1]) if len(host_port) > 1 else 443
        try:
            upstream = socket.create_connection((host, port), timeout=30)
        except OSError as exc:
            self.send_error(502, str(exc))
            return
        self.send_response(200, "Connection Established")
        self.end_headers()
        client = self.connection
        sockets = [client, upstream]
        try:
            while True:
                readable, _, errored = select.select(sockets, [], sockets, 60)
                if errored or not readable:
                    break
                for sock in readable:
                    other = upstream if sock is client else client
                    data = sock.recv(65536)
                    if not data:
                        return
                    other.sendall(data)
        finally:
            upstream.close()

    def do_HEAD(self) -> None:
        self._proxy(body=False)

    def do_GET(self) -> None:
        self._proxy(body=True)

    def _proxy(self, body: bool) -> None:
        url = self.path
        if not url.startswith("http://"):
            self.send_error(400, "absolute-form URI required")
            return
        try:
            dest = cache_path(self.cache_root, url) if cacheable(url) else None
        except ValueError as exc:
            self.send_error(400, str(exc))
            return
        if dest is not None and dest.is_file() and dest.stat().st_size > 0:
            self._serve_file(dest, body, hit=True)
            return
        if dest is None:
            self._fetch_live(url, body, save_to=None)
            return
        dest.parent.mkdir(parents=True, exist_ok=True)
        lock_path = dest.with_suffix(dest.suffix + ".lock")
        with open(lock_path, "a+b") as lockf:
            fcntl.flock(lockf.fileno(), fcntl.LOCK_EX)
            if dest.is_file() and dest.stat().st_size > 0:
                self._serve_file(dest, body, hit=True)
                return
            self._fetch_live(url, body, save_to=dest)

    def _serve_file(self, dest: Path, body: bool, hit: bool) -> None:
        data = dest.read_bytes() if body else b""
        size = dest.stat().st_size
        self.log_message("%s %s (%s)", "HIT" if hit else "STORE", dest.name, _size(size))
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(size))
        self.send_header("Connection", "close")
        self.send_header("X-Cache", "HIT" if hit else "MISS")
        self.end_headers()
        if body:
            self.wfile.write(data)

    def _fetch_live(self, url: str, body: bool, save_to: Path | None) -> None:
        headers = {}
        ua = self.headers.get("User-Agent")
        if ua:
            headers["User-Agent"] = ua
        req = Request(url, headers=headers, method="GET" if body else "HEAD")
        try:
            with urlopen(req, timeout=120) as resp:
                payload = resp.read() if body else b""
                status = resp.status
                ctype = resp.headers.get("Content-Type", "application/octet-stream")
        except Exception as exc:  # noqa: BLE001 — surface any fetch failure as 502
            self.send_error(502, str(exc))
            return
        if save_to is not None and body and status == 200 and payload:
            partial = save_to.with_suffix(save_to.suffix + ".partial")
            partial.write_bytes(payload)
            os.replace(partial, save_to)
            self.log_message("MISS %s (%s)", save_to.name, _size(len(payload)))
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Connection", "close")
        self.send_header("X-Cache", "MISS")
        self.end_headers()
        if body:
            self.wfile.write(payload)


def _size(n: int) -> str:
    if n >= 1_048_576:
        return f" {n / 1_048_576:.1f}MB"
    if n >= 1024:
        return f" {n / 1024:.0f}kB"
    return f" {n}B"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=3142)
    parser.add_argument("--dir", type=Path, required=True)
    parser.add_argument("--bind", default="127.0.0.1")
    args = parser.parse_args()
    args.dir.mkdir(parents=True, exist_ok=True)
    Handler.cache_root = args.dir.resolve()
    server = ThreadingHTTPServer((args.bind, args.port), Handler)
    print(f"[apt-proxy] listening on {args.bind}:{args.port} cache={Handler.cache_root}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
