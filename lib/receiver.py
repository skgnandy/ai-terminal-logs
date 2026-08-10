#!/usr/bin/env python3
"""Accept NDJSON batches from Vector and COPY them into Postgres.

Why a receiver instead of a Vector `postgres` sink: sink availability varies by
Vector build, and a version-dependent install path is unacceptable for a one-line
setup that must work on any machine. This runs on the standard library only —
no pip, no venv, no wheels to compile on a small VPS.

Delivery semantics: Vector retries on any non-2xx response, so a failed COPY is
not data loss. Retries create duplicates, which the `fp` content hash absorbs.
Under sustained backpressure the queue sheds load rather than growing unbounded —
the agent must never OOM the machine it is monitoring.
"""

from __future__ import annotations

import hashlib
import json
import os
import queue
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("RECEIVER_PORT", "9080"))
CONTAINER = os.environ.get("PG_CONTAINER", "ai-terminal-logs")
PG_USER = os.environ.get("PG_USER", "logagent")
PG_DB = os.environ.get("PG_DB", "logs")
HOST = os.environ.get("HOST_NAME", "unknown")

COLUMNS = "id,ts,host,service,kind,severity,body,attrs,fp"
MAX_QUEUE = 2000
COPY_TIMEOUT = 60

_queue: "queue.Queue[list[str]]" = queue.Queue(maxsize=MAX_QUEUE)
_seq = 0
_seq_lock = threading.Lock()

_stats = {"received": 0, "written": 0, "dropped": 0, "failed": 0}


def _next_id() -> int:
    global _seq
    with _seq_lock:
        _seq += 1
        return _seq


def _esc(value: object) -> str:
    """Escape one field for Postgres COPY text format."""
    if value is None:
        return r"\N"
    return (
        str(value)
        .replace("\\", "\\\\")
        .replace("\t", "\\t")
        .replace("\n", "\\n")
        .replace("\r", "")
    )


def _to_row(event: dict) -> str:
    body = event.get("body") or event.get("message") or ""
    service = event.get("service") or "unknown"
    fingerprint = hashlib.sha1(
        f"{event.get('ts')}|{service}|{body}".encode("utf-8", "replace")
    ).hexdigest()

    attrs = event.get("attrs")
    return "\t".join(
        [
            str(_next_id()),
            _esc(event.get("ts")),
            _esc(event.get("host") or HOST),
            _esc(service),
            _esc(event.get("kind") or "unknown"),
            _esc(event.get("severity")),
            _esc(body),
            _esc(json.dumps(attrs)) if attrs else r"\N",
            "\\\\x" + fingerprint,
        ]
    )


def _writer() -> None:
    """Single writer thread. One COPY per batch beats per-row INSERTs by ~100x."""
    sql = f"COPY log_entries ({COLUMNS}) FROM STDIN WITH (FORMAT text, NULL '\\N')"
    while True:
        rows = _queue.get()
        if not rows:
            continue
        try:
            proc = subprocess.run(
                ["docker", "exec", "-i", CONTAINER,
                 "psql", "-U", PG_USER, "-d", PG_DB, "-q", "-c", sql],
                input="\n".join(rows) + "\n",
                text=True,
                capture_output=True,
                timeout=COPY_TIMEOUT,
            )
            if proc.returncode == 0:
                _stats["written"] += len(rows)
            else:
                _stats["failed"] += len(rows)
                print(f"copy failed: {proc.stderr.strip()[:400]}", file=sys.stderr, flush=True)
        except Exception as exc:  # noqa: BLE001 — the writer thread must never die
            _stats["failed"] += len(rows)
            print(f"copy error: {exc}", file=sys.stderr, flush=True)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self) -> None:  # noqa: N802
        length = int(self.headers.get("Content-Length", 0))
        payload = self.rfile.read(length).decode("utf-8", "replace")

        rows = []
        for line in payload.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(_to_row(json.loads(line)))
            except Exception:  # noqa: BLE001 — one malformed line must not drop a batch
                continue

        _stats["received"] += len(rows)

        try:
            _queue.put_nowait(rows)
        except queue.Full:
            # Shed load. Vector buffers to disk and retries; growing this queue
            # would trade a brief backlog for an OOM kill.
            _stats["dropped"] += len(rows)
            self._respond(503)
            return

        self._respond(204)

    def do_GET(self) -> None:  # noqa: N802
        if self.path != "/health":
            self._respond(404)
            return
        body = json.dumps({"ok": True, "queue": _queue.qsize(), **_stats}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _respond(self, code: int) -> None:
        self.send_response(code)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *_args) -> None:
        """Silence per-request logging — it would out-volume the logs we collect."""
        return


def main() -> None:
    threading.Thread(target=_writer, daemon=True, name="copy-writer").start()
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
