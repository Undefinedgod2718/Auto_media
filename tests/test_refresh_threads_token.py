#!/usr/bin/env python3
"""Tests for scripts/refresh_threads_token.sh — safety (rollback) and dry-run.

The success path needs the real Threads API (the verify step calls
graph.threads.net), so it is covered manually/in staging. Here we prove the
script never replaces a working token on failure, and that --dry-run is inert.
"""
from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "refresh_threads_token.sh"

OLD_TOKEN = "THAA-old-working-token"


def _write_env(tmp: Path, token: str = OLD_TOKEN, uid: str = "12345") -> Path:
    env = tmp / ".env"
    lines = []
    if token is not None:
        lines.append(f"THREADS_ACCESS_TOKEN={token}")
    if uid is not None:
        lines.append(f"THREADS_USER_ID={uid}")
    env.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return env


SCRIPT_DEPS = [
    "scripts/refresh_threads_token.sh", "scripts/lib/common.sh",
    "scripts/lib/load_env.sh", "scripts/lib/env_store.py",
    "scripts/lib/secret_tests.py", "scripts/lib/parse_task.py",
    "scripts/lib/read-platform.sh",
]


def _mirror_repo(tmp: Path) -> None:
    (tmp / "scripts" / "lib").mkdir(parents=True, exist_ok=True)
    for rel in SCRIPT_DEPS:
        src = ROOT / rel
        if src.exists():
            (tmp / rel).write_text(src.read_text(encoding="utf-8"), encoding="utf-8")


def _run(tmp: Path, *args: str, base: str | None = None):
    env = {**os.environ, "AUTO_MEDIA_ROOT": str(tmp), "DATA_ROOT": str(tmp / "data")}
    if base:
        env["THREADS_GRAPH_BASE"] = base
    return subprocess.run(
        ["bash", str(tmp / "scripts" / "refresh_threads_token.sh"), "--no-restart", *args],
        cwd=str(tmp), capture_output=True, text=True, env=env,
        encoding="utf-8", errors="replace",
    )


class _Junk(BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        body = b'{"error":{"message":"invalid","code":190}}'
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):  # silence
        pass


def _mock_server():
    srv = HTTPServer(("127.0.0.1", 0), _Junk)
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()
    return srv


def _env_token(env_path: Path) -> str | None:
    for line in env_path.read_text(encoding="utf-8").splitlines():
        if line.startswith("THREADS_ACCESS_TOKEN="):
            return line.split("=", 1)[1]
    return None


def test_dry_run_does_not_touch_env():
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        _mirror_repo(tmp)
        env = _write_env(tmp)
        r = _run(tmp, "--dry-run")
        assert r.returncode == 0, r.stderr
        assert _env_token(env) == OLD_TOKEN


def test_rollback_on_bad_response_keeps_old_token():
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        _mirror_repo(tmp)
        env = _write_env(tmp)
        srv = _mock_server()
        try:
            base = f"http://127.0.0.1:{srv.server_address[1]}"
            r = _run(tmp, base=base)
        finally:
            srv.shutdown()
        assert r.returncode != 0, "should fail on bad response"
        assert _env_token(env) == OLD_TOKEN, "old token must be preserved"


def test_skip_when_unset():
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        _mirror_repo(tmp)
        (tmp / ".env").write_text("THREADS_USER_ID=123\n", encoding="utf-8")  # no token
        r = _run(tmp)
        assert r.returncode == 0, r.stderr


if __name__ == "__main__":
    import traceback

    failed = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try:
                fn()
                print(f"ok   {name}")
            except Exception:
                failed += 1
                print(f"FAIL {name}")
                traceback.print_exc()
    sys.exit(1 if failed else 0)
