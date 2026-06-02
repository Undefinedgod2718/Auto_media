#!/usr/bin/env python3
"""Local dashboard for non-coder operators (localhost only)."""
from __future__ import annotations

import html
import json
import os
import re
import secrets
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(os.environ.get("AUTO_MEDIA_ROOT", Path(__file__).resolve().parents[1]))
DATA = Path(os.environ.get("DATA_ROOT", ROOT / "data"))
HOST = os.environ.get("AUTO_MEDIA_DASHBOARD_HOST", "127.0.0.1")
PORT = int(os.environ.get("AUTO_MEDIA_DASHBOARD_PORT", "8788"))
ENV_PATH = ROOT / ".env"
CSRF_TOKEN = secrets.token_urlsafe(24)

import sys

sys.path.insert(0, str(ROOT / "scripts" / "lib"))
from env_store import parse_env, schema_payload, status_payload, update_env  # noqa: E402
from secret_tests import run_group  # noqa: E402


def run(cmd: list[str]) -> tuple[int, str]:
    p = subprocess.run(cmd, cwd=str(ROOT), text=True, capture_output=True)
    out = p.stdout.strip() or p.stderr.strip()
    return p.returncode, out


def run_safe(cmd: list[str], timeout_s: int = 20) -> tuple[int, str]:
    p = subprocess.run(
        cmd,
        cwd=str(ROOT),
        text=True,
        capture_output=True,
        timeout=timeout_s,
    )
    out = (p.stdout or "") + ("\n" + p.stderr if p.stderr else "")
    return p.returncode, redact_secrets(out.strip())


def redact_secrets(text: str) -> str:
    if not text:
        return text
    redacted = text
    patterns = [
        r"(ACCESS_TOKEN=)[^\s]+",
        r"(API_KEY=)[^\s]+",
        r"(SECRET=)[^\s]+",
        r"(TOKEN=)[^\s]+",
        r"(Bearer\s+)[A-Za-z0-9._-]+",
    ]
    for pat in patterns:
        redacted = re.sub(pat, r"\1[REDACTED]", redacted, flags=re.IGNORECASE)
    return redacted


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


def _safe_origin(origin: str) -> bool:
    if not origin:
        return False
    return origin.startswith("http://127.0.0.1:") or origin.startswith("http://localhost:")


def _load_env_values() -> dict[str, str]:
    _, values = parse_env(ENV_PATH)
    return values


def _dashboard_html(rc: int, status_out: str) -> str:
    runs = list_runs()
    runs_html = "".join(
        f"<tr><td>{html.escape(r['run_id'])}</td><td>{html.escape(r['stage'])}</td></tr>"
        for r in runs
    )
    return f"""<!doctype html>
<html><head><meta charset="utf-8"><title>Auto Media Dashboard</title></head>
<body>
  <h2>Auto Media Dashboard (localhost)</h2>
  <p>Health: {'OK' if rc == 0 else 'WARN'}</p>
  <p><a href="/user">User mode</a> | <a href="/settings">Token settings</a></p>
  <h3>Environment / Auth</h3>
  <pre>{html.escape(status_out)}</pre>
  <h3>Recent Runs</h3>
  <table border="1" cellpadding="6"><tr><th>run_id</th><th>stage</th></tr>{runs_html}</table>
  <h3>MCP</h3>
  <p>Use <code>scripts/mcp_automedia.py</code> with <code>AUTO_MEDIA_MCP_WRITE=0</code> by default.</p>
</body></html>"""


def _user_html() -> str:
    return """<!doctype html>
<html><head><meta charset="utf-8"><title>Auto Media User Console</title></head>
<body>
  <h2>Auto Media User Console</h2>
  <p>For non-engineers. Localhost only.</p>
  <ul>
    <li><a href="/settings">1) Fill tokens safely</a></li>
    <li><a href="/api/status">2) Check environment/auth status</a></li>
    <li><a href="/api/check/cli-auth">3) Check CLI auth readiness</a></li>
    <li><a href="/api/check/meta">4) Check Meta/IG/Threads token readiness</a></li>
    <li><a href="/api/runs">5) View recent run stages</a></li>
  </ul>
  <p>Need details? See <code>USER.md</code>.</p>
</body></html>"""


def _settings_html() -> str:
    return f"""<!doctype html>
<html><head><meta charset="utf-8"><title>Token Settings</title></head>
<body>
  <h2>Token Settings (localhost)</h2>
  <p>Values are never returned in plaintext. Empty input means no update.</p>
  <p><a href="/user">Back to user console</a></p>
  <div id="status"></div>
  <form id="settingsForm"></form>
  <p>
    <button type="button" onclick="saveSettings()">Save updates</button>
    <button type="button" onclick="runTest('all')">Test all</button>
    <button type="button" onclick="runTest('telegram')">Test telegram</button>
    <button type="button" onclick="runTest('n8n_api')">Test n8n</button>
    <button type="button" onclick="runTest('meta_fb_ig')">Test meta</button>
    <button type="button" onclick="runTest('threads')">Test threads</button>
    <button type="button" onclick="runReadonlyCheck('cli-auth')">Check CLI auth</button>
    <button type="button" onclick="runReadonlyCheck('meta')">Check Meta/IG/Threads</button>
  </p>
  <pre id="result"></pre>
<script>
const csrf = "{CSRF_TOKEN}";
let schema = [];
let statusRows = [];

function fieldStatus(name) {{
  return statusRows.find(r => r.name === name) || {{is_set:false, masked:""}};
}}

async function loadSettings() {{
  const schemaResp = await fetch('/api/settings/schema');
  const statusResp = await fetch('/api/settings/status');
  schema = (await schemaResp.json()).fields || [];
  statusRows = (await statusResp.json()).fields || [];
  const form = document.getElementById('settingsForm');
  form.innerHTML = '';
  for (const f of schema) {{
    const s = fieldStatus(f.name);
    const row = document.createElement('div');
    row.style.marginBottom = '8px';
    row.innerHTML = `
      <label><b>${{f.name}}</b> (${{f.group}})</label><br/>
      <small>${{f.description || ''}} | current: ${{s.is_set ? 'set' : 'unset'}} ${{s.masked || ''}}</small><br/>
      <input type="${{f.secret ? 'password' : 'text'}}" name="${{f.name}}" style="min-width:420px;" autocomplete="off" />
    `;
    form.appendChild(row);
  }}
  document.getElementById('status').textContent = 'Loaded settings schema/status';
}}

async function saveSettings() {{
  const inputs = document.querySelectorAll('#settingsForm input');
  const updates = {{}};
  for (const i of inputs) {{
    if ((i.value || '').trim()) updates[i.name] = i.value.trim();
  }}
  const resp = await fetch('/api/settings/update', {{
    method: 'POST',
    headers: {{'Content-Type':'application/json','X-CSRF-Token':csrf}},
    body: JSON.stringify({{updates}})
  }});
  const data = await resp.json();
  document.getElementById('result').textContent = JSON.stringify(data, null, 2);
  await loadSettings();
}}

async function runTest(group) {{
  const resp = await fetch('/api/settings/test', {{
    method: 'POST',
    headers: {{'Content-Type':'application/json','X-CSRF-Token':csrf}},
    body: JSON.stringify({{group}})
  }});
  const data = await resp.json();
  document.getElementById('result').textContent = JSON.stringify(data, null, 2);
}}

async function runReadonlyCheck(name) {{
  const resp = await fetch('/api/check/' + encodeURIComponent(name));
  const data = await resp.json();
  document.getElementById('result').textContent = JSON.stringify(data, null, 2);
}}

loadSettings();
</script>
</body></html>"""


class Handler(BaseHTTPRequestHandler):
    CHECK_ACTIONS: dict[str, list[str]] = {
        "cli-auth": ["bash", "scripts/verify_n8n_claude_engine.sh"],
        "meta": ["bash", "scripts/verify_meta_tokens.sh"],
    }

    def _localhost_only(self) -> bool:
        ip = self.client_address[0]
        return ip in ("127.0.0.1", "::1", "localhost")

    def _reject_if_not_local(self) -> bool:
        if self._localhost_only():
            return False
        self._json({"ok": False, "error": "localhost only"}, code=403)
        return True

    def _parse_json_body(self) -> dict:
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length) if length > 0 else b"{}"
        try:
            return json.loads(raw.decode("utf-8") or "{}")
        except Exception:
            return {}

    def _csrf_ok(self) -> bool:
        token = self.headers.get("X-CSRF-Token", "")
        origin = self.headers.get("Origin", "")
        return token == CSRF_TOKEN and _safe_origin(origin)

    def _json(self, payload: dict, code: int = 200) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        if self._reject_if_not_local():
            return
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
        if self.path.startswith("/api/check/"):
            action = self.path.removeprefix("/api/check/").strip("/")
            cmd = self.CHECK_ACTIONS.get(action)
            if not cmd:
                self._json({"ok": False, "error": "unknown check"}, code=404)
                return
            rc, out = run_safe(cmd, timeout_s=20)
            next_steps = []
            if action == "cli-auth" and rc != 0:
                next_steps = [
                    "Run: bash scripts/sync_claude_oauth.sh",
                    "Run: bash scripts/inject_n8n_secrets.sh",
                    "Restart n8n: sudo docker compose up -d n8n",
                ]
            if action == "meta" and rc != 0:
                next_steps = [
                    "Refresh Meta/Threads token",
                    "Update .env token values",
                    "Restart n8n: sudo docker compose up -d n8n",
                ]
            self._json(
                {
                    "ok": rc == 0,
                    "check": action,
                    "output": out,
                    "next_steps": next_steps,
                }
            )
            return
        if self.path == "/api/settings/schema":
            self._json({"ok": True, "fields": schema_payload()})
            return
        if self.path == "/api/settings/status":
            self._json({"ok": True, "fields": status_payload(_load_env_values())})
            return
        if self.path == "/user":
            raw = _user_html().encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)
            return
        if self.path == "/settings":
            raw = _settings_html().encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)
            return
        if self.path == "/":
            rc, status_out = run(["bash", "scripts/env-check.sh"])
            body = _dashboard_html(rc, status_out)
            raw = body.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)
            return
        self._json({"ok": False, "error": "not found"}, code=404)

    def do_POST(self) -> None:  # noqa: N802
        if self._reject_if_not_local():
            return
        if not self._csrf_ok():
            self._json({"ok": False, "error": "csrf failed"}, code=403)
            return
        payload = self._parse_json_body()
        if self.path == "/api/settings/update":
            updates = payload.get("updates") or {}
            if not isinstance(updates, dict):
                self._json({"ok": False, "error": "updates must be object"}, code=400)
                return
            try:
                changed = update_env(ENV_PATH, updates)
            except ValueError as e:
                self._json({"ok": False, "error": str(e)}, code=400)
                return
            self._json({"ok": True, "changed": changed})
            return
        if self.path == "/api/settings/test":
            group = str(payload.get("group", "all"))
            self._json(run_group(group, _load_env_values()))
            return
        self._json({"ok": False, "error": "not found"}, code=404)


def main() -> int:
    httpd = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"dashboard: http://{HOST}:{PORT}", flush=True)
    httpd.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
