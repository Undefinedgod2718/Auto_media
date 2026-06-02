#!/usr/bin/env python3
"""Local dashboard for non-coder operators (localhost only)."""
from __future__ import annotations

import html
import json
import os
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(os.environ.get("AUTO_MEDIA_ROOT", Path(__file__).resolve().parents[1]))
DATA = Path(os.environ.get("DATA_ROOT", ROOT / "data"))
HOST = os.environ.get("AUTO_MEDIA_DASHBOARD_HOST", "127.0.0.1")
PORT = int(os.environ.get("AUTO_MEDIA_DASHBOARD_PORT", "8788"))


def run(cmd: list[str]) -> tuple[int, str]:
    p = subprocess.run(cmd, cwd=str(ROOT), text=True, capture_output=True)
    out = p.stdout.strip() or p.stderr.strip()
    return p.returncode, out


def list_runs(limit: int = 15) -> list[dict]:
    runs_dir = DATA / "runs"
    if not runs_dir.is_dir():
        return []
    out = []
    for p in sorted(runs_dir.iterdir(), key=lambda x: x.stat().st_mtime, reverse=True)[:limit]:
        if not p.is_dir():
            continue
        state = p / "state.json"
        stage = "-"
        if state.is_file():
            try:
                stage = json.loads(state.read_text(encoding="utf-8")).get("stage", "-")
            except Exception:
                stage = "invalid-state"
        out.append({"run_id": p.name, "stage": stage})
    return out


class Handler(BaseHTTPRequestHandler):
    def _json(self, payload: dict, code: int = 200) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        if self.path == "/healthz":
            self._json({"ok": True, "service": "am-dashboard"})
            return
        if self.path == "/api/status":
            rc, out = run(["bash", "scripts/env-check.sh"])
            self._json({"ok": rc == 0, "output": out})
            return
        if self.path.startswith("/api/runs"):
            self._json({"ok": True, "runs": list_runs()})
            return
        if self.path == "/":
            rc, status_out = run(["bash", "scripts/env-check.sh"])
            runs = list_runs()
            runs_html = "".join(
                f"<tr><td>{html.escape(r['run_id'])}</td><td>{html.escape(r['stage'])}</td></tr>"
                for r in runs
            )
            body = f"""<!doctype html>
<html><head><meta charset="utf-8"><title>Auto Media Dashboard</title></head>
<body>
  <h2>Auto Media Dashboard (localhost)</h2>
  <p>Health: {'OK' if rc == 0 else 'WARN'}</p>
  <h3>Environment / Auth</h3>
  <pre>{html.escape(status_out)}</pre>
  <h3>Recent Runs</h3>
  <table border="1" cellpadding="6"><tr><th>run_id</th><th>stage</th></tr>{runs_html}</table>
  <h3>MCP</h3>
  <p>Use <code>scripts/mcp_automedia.py</code> with <code>AUTO_MEDIA_MCP_WRITE=0</code> by default.</p>
</body></html>"""
            raw = body.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)
            return
        self._json({"ok": False, "error": "not found"}, code=404)


def main() -> int:
    httpd = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"dashboard: http://{HOST}:{PORT}", flush=True)
    httpd.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
