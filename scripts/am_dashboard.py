#!/usr/bin/env python3
"""Local dashboard for non-coder operators (localhost only)."""
from __future__ import annotations

import hashlib
import html
import ipaddress
import json
import os
import re
import secrets
import shutil
import subprocess
import tempfile
import time
import urllib.parse
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import fcntl
import yaml

ROOT = Path(os.environ.get("AUTO_MEDIA_ROOT", Path(__file__).resolve().parents[1]))
DATA = Path(os.environ.get("DATA_ROOT", ROOT / "data"))
HOST = os.environ.get("AUTO_MEDIA_DASHBOARD_HOST", "127.0.0.1")
PORT = int(os.environ.get("AUTO_MEDIA_DASHBOARD_PORT", "8788"))
ENV_PATH = ROOT / ".env"
PLATFORM_YAML = ROOT / "config" / "platform.yaml"
SKILLS_DIR = ROOT / "config" / "skills"
SKILL_BACKUP_ROOT = DATA / "backups" / "skills"
SKILL_AUDIT_LOG = DATA / "logs" / "skill_admin.jsonl"
SKILL_LOCK = DATA / "locks" / "dashboard-skill-edit.lock"
PLATFORMS = ("instagram", "threads", "facebook")
ARTIFACTS = ("writer", "artist")
MAX_SKILL_FILE_BYTES = 256 * 1024
WRITER_FILES = (
    "SKILL.md",
    "BRAND.md",
    "TEMPLATE.md",
)
ARTIST_FILES = (
    "SKILL.md",
    "VISUAL_BASE.md",
    "PAGE_TYPES.md",
)
LEGACY_ARTIST_FILES = (
    "PALETTE.md",
    "RULES.md",
)
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
    try:
        p = subprocess.run(
            cmd,
            cwd=str(ROOT),
            text=True,
            capture_output=True,
            timeout=timeout_s,
        )
        out = (p.stdout or "") + ("\n" + p.stderr if p.stderr else "")
        return p.returncode, redact_secrets(out.strip())
    except subprocess.TimeoutExpired as e:
        out = (e.stdout or "") + ("\n" + e.stderr if e.stderr else "")
        return 124, redact_secrets(out.strip() or f"timeout after {timeout_s}s")


def _extract_line(text: str, key: str) -> str:
    for line in text.splitlines():
        if key in line:
            return line.strip()
    return ""


def _write_enabled() -> bool:
    return os.environ.get("AUTO_MEDIA_DASHBOARD_WRITE", "0") == "1"


def _skill_dirs() -> list[Path]:
    if not SKILLS_DIR.is_dir():
        return []
    return sorted(
        [
            p
            for p in SKILLS_DIR.iterdir()
            if p.is_dir() and p.name != "_template" and re.match(r"^[A-Za-z0-9_.-]+$", p.name)
        ],
        key=lambda p: p.name,
    )


def _skill_types(skill_dir: Path) -> set[str]:
    kinds: set[str] = set()
    name = skill_dir.name.lower()
    if (skill_dir / "BRAND.md").is_file() and (skill_dir / "TEMPLATE.md").is_file():
        kinds.add("writer")
    if (skill_dir / "VISUAL_BASE.md").is_file() and (skill_dir / "PAGE_TYPES.md").is_file():
        kinds.add("artist")
    if name.endswith("_writer") or "copywriter" in name:
        kinds.add("writer")
    if name.endswith("_artist") or "svg" in name or "image" in name:
        kinds.add("artist")
    return kinds


def _allowed_files_for_skill(skill_name: str) -> set[str]:
    d = SKILLS_DIR / skill_name
    kinds = _skill_types(d)
    allowed: set[str] = {"SKILL.md"}
    if "writer" in kinds:
        allowed.update(WRITER_FILES)
    if "artist" in kinds:
        allowed.update(ARTIST_FILES)
        # Legacy artist skills may already carry palette/rule docs. Allow editing
        # existing files only; do not let the API create new shape variants.
        allowed.update(f for f in LEGACY_ARTIST_FILES if (d / f).is_file())
    return allowed


def _editable_files(skill_name: str) -> list[str]:
    d = SKILLS_DIR / skill_name
    if not d.is_dir():
        return []
    allowed = _allowed_files_for_skill(skill_name)
    return sorted(f for f in allowed if (d / f).is_file())


def _safe_skill_name(name: str) -> str:
    if not re.match(r"^[A-Za-z0-9_.-]+$", name or ""):
        raise ValueError("invalid skill name")
    d = (SKILLS_DIR / name).resolve()
    if not d.is_dir() or SKILLS_DIR.resolve() not in d.parents:
        raise ValueError("unknown skill")
    return name


def _safe_skill_file_path(skill_name: str, filename: str) -> Path:
    _safe_skill_name(skill_name)
    if filename not in _editable_files(skill_name):
        raise ValueError("file not allowed")
    p = (SKILLS_DIR / skill_name / filename).resolve()
    base = (SKILLS_DIR / skill_name).resolve()
    if base not in p.parents:
        raise ValueError("invalid path")
    return p


def _load_platform_config() -> dict:
    if not PLATFORM_YAML.is_file():
        raise ValueError("config/platform.yaml missing")
    data = yaml.safe_load(PLATFORM_YAML.read_text(encoding="utf-8")) or {}
    if not isinstance(data, dict):
        raise ValueError("config/platform.yaml must be a mapping")
    return data


def _platforms_mapping_node(data: dict) -> dict:
    engines = data.get("engines")
    if not isinstance(engines, dict):
        raise ValueError("platform mapping structure not found: engines missing")
    platforms = engines.get("platforms")
    if not isinstance(platforms, dict):
        raise ValueError("platform mapping structure not found: engines.platforms missing")
    return platforms


def _current_platform_mapping(data: dict | None = None) -> dict[str, dict[str, str]]:
    cfg = data if data is not None else _load_platform_config()
    platforms_node = _platforms_mapping_node(cfg)
    out: dict[str, dict[str, str]] = {p: {a: "" for a in ARTIFACTS} for p in PLATFORMS}
    for platform in PLATFORMS:
        row = platforms_node.get(platform)
        if not isinstance(row, dict):
            continue
        for artifact in ARTIFACTS:
            entry = row.get(artifact)
            if isinstance(entry, dict):
                out[platform][artifact] = str(entry.get("skill_mount") or "")
    return out


def _replace_platform_mapping(data: dict, mapping: dict[str, dict[str, str]]) -> dict:
    platforms_node = _platforms_mapping_node(data)
    for platform in PLATFORMS:
        row = platforms_node.get(platform)
        if not isinstance(row, dict):
            raise ValueError(f"platform mapping structure not found: {platform}")
        for artifact in ARTIFACTS:
            entry = row.get(artifact)
            if not isinstance(entry, dict):
                raise ValueError(f"platform mapping structure not found: {platform}.{artifact}")
            skill = (mapping.get(platform) or {}).get(artifact)
            if not skill:
                raise ValueError(f"missing {platform}/{artifact}")
            entry["skill_mount"] = skill
    return data


def _save_platform_config_atomic(data: dict) -> None:
    text = yaml.safe_dump(data, allow_unicode=True, sort_keys=False)
    _write_text_atomic(PLATFORM_YAML, text)


def _skills_schema() -> dict[str, object]:
    skills = []
    writer_options: list[str] = []
    artist_options: list[str] = []
    for d in _skill_dirs():
        types = sorted(_skill_types(d))
        files = _editable_files(d.name)
        skills.append({"name": d.name, "types": types, "files": files})
        if "writer" in types:
            writer_options.append(d.name)
        if "artist" in types:
            artist_options.append(d.name)
    return {
        "write_enabled": _write_enabled(),
        "mapping": _current_platform_mapping(),
        "options": {"writer": writer_options, "artist": artist_options},
        "skills": skills,
    }


@contextmanager
def _edit_lock():
    SKILL_LOCK.parent.mkdir(parents=True, exist_ok=True)
    with SKILL_LOCK.open("w", encoding="utf-8") as f:
        fcntl.flock(f.fileno(), fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(f.fileno(), fcntl.LOCK_UN)


def _backup_copy(src: Path) -> Path:
    ts = time.strftime("%Y%m%d-%H%M%S")
    dest = SKILL_BACKUP_ROOT / ts / src.relative_to(ROOT)
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dest)
    return dest


def _write_text_atomic(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    original_mode = path.stat().st_mode if path.exists() else None
    tmp: Path | None = None
    try:
        with tempfile.NamedTemporaryFile("w", delete=False, dir=str(path.parent), encoding="utf-8") as tf:
            tf.write(content)
            tmp = Path(tf.name)
        os.replace(tmp, path)
        if original_mode is not None:
            os.chmod(path, original_mode & 0o7777)
    finally:
        if tmp is not None and tmp.exists():
            tmp.unlink()


def _audit_skill(action: str, success: bool, client_ip: str, **details: object) -> None:
    SKILL_AUDIT_LOG.parent.mkdir(parents=True, exist_ok=True)
    err = str(details.get("error", "") or "")
    details["error_hash"] = hashlib.sha256(err.encode("utf-8")).hexdigest()[:12] if err else ""
    details.pop("error", None)
    row = {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "action": action,
        "success": bool(success),
        "client_ip": client_ip,
        "details": details,
    }
    with SKILL_AUDIT_LOG.open("a", encoding="utf-8") as f:
        f.write(json.dumps(row, ensure_ascii=False) + "\n")


def _n8n_cli_check() -> tuple[dict[str, str], list[str]]:
    checks: dict[str, str] = {}
    next_steps: list[str] = []

    rc_claude, out_claude = run_safe(["bash", "scripts/verify_n8n_claude_engine.sh"], timeout_s=20)
    checks["claude"] = "PASS n8n claude auth ready" if rc_claude == 0 else f"WARN {out_claude[:240]}"
    if rc_claude != 0:
        next_steps.extend(
            [
                "Run: bash scripts/sync_claude_oauth.sh",
                "Run: bash scripts/inject_n8n_secrets.sh",
            ]
        )

    # n8n image bakes gemini/codex CLIs in Dockerfile (codex via INSTALL_CODEX=true).
    checks["codex"] = "PASS n8n codex binary baked (INSTALL_CODEX=true)"
    checks["gemini"] = "PASS n8n gemini binary baked (npm global)"

    codex_auth = Path("/data/secrets/codex/auth.json").is_file()
    gemini_auth = Path("/data/secrets/gemini/oauth_creds.json").is_file() or Path(
        "/data/secrets/gemini/google_accounts.json"
    ).is_file()
    if codex_auth:
        checks["codex"] += " + oauth"
    else:
        checks["codex"] += " (oauth missing?)"
        next_steps.append("Run: bash scripts/sync_codex_oauth.sh")
    if gemini_auth:
        checks["gemini"] += " + oauth"
    else:
        checks["gemini"] += " (oauth missing?)"
        next_steps.append("Run: bash scripts/sync_gemini_oauth.sh")
    if not (codex_auth and gemini_auth):
        next_steps.append("Run: bash scripts/inject_n8n_secrets.sh")

    return checks, list(dict.fromkeys(next_steps))


def cli_auth_status() -> dict[str, object]:
    checks, next_steps = _n8n_cli_check()
    bad = [k for k, v in checks.items() if ("WARN" in v or not v)]
    out = json.dumps({"checks": checks}, ensure_ascii=False)
    if bad:
        next_steps.append("Restart n8n: sudo docker compose up -d n8n")
    return {
        "ok": len(bad) == 0,
        "check": "cli-auth",
        "checks": checks,
        "output": out,
        "next_steps": list(dict.fromkeys(next_steps)),
    }


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
  <p><a href="/user">User mode</a> | <a href="/settings">Token settings</a> | <a href="/skills">Skill manager</a></p>
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
    <li><a href="/skills">6) Skill manager (writer/artist)</a></li>
  </ul>
  <p>Need details? See <code>USER.md</code>.</p>
</body></html>"""


def _skills_html() -> str:
    return f"""<!doctype html>
<html><head><meta charset="utf-8"><title>Skill Manager</title></head>
<body>
  <h2>Skill Manager</h2>
  <p><a href="/user">Back to user console</a></p>
  <p id="mode"></p>
  <h3>Platform mapping (6 slots)</h3>
  <div id="mapping"></div>
  <button type="button" onclick="saveMapping()">Save mapping (auto apply)</button>
  <h3>Skill file editor</h3>
  <div>
    <label>Skill: <select id="skillSel"></select></label>
    <label>File: <select id="fileSel"></select></label>
    <button type="button" onclick="loadFile()">Load</button>
  </div>
  <textarea id="editor" style="width:90%;height:360px;"></textarea><br/>
  <button type="button" onclick="saveFile()">Save file (auto apply)</button>
  <pre id="result"></pre>
<script>
const csrf = "{CSRF_TOKEN}";
let schema = null;
function escapeHtml(s) {{
  return String(s).replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;');
}}
async function refreshSchema() {{
  const resp = await fetch('/api/skills/schema');
  const data = await resp.json();
  schema = data;
  document.getElementById('mode').textContent = data.write_enabled
    ? 'Write mode: ENABLED'
    : 'Read-only mode: set AUTO_MEDIA_DASHBOARD_WRITE=1 to enable edits';
  const skillSel = document.getElementById('skillSel');
  skillSel.innerHTML = '';
  for (const s of data.skills || []) {{
    const o = document.createElement('option');
    o.value = s.name;
    o.textContent = s.name + ' [' + (s.types || []).join('/') + ']';
    skillSel.appendChild(o);
  }}
  await refreshFiles();
  renderMapping();
  const ro = !data.write_enabled;
  document.getElementById('editor').readOnly = ro;
}}
async function refreshFiles() {{
  const skill = document.getElementById('skillSel').value;
  if (!skill) return;
  const resp = await fetch('/api/skills/files?skill=' + encodeURIComponent(skill));
  const data = await resp.json();
  const fileSel = document.getElementById('fileSel');
  fileSel.innerHTML = '';
  for (const f of data.files || []) {{
    const o = document.createElement('option');
    o.value = f;
    o.textContent = f;
    fileSel.appendChild(o);
  }}
}}
function renderMapping() {{
  const m = (schema && schema.mapping) || {{}};
  const opts = (schema && schema.options) || {{writer:[], artist:[]}};
  const slots = [
    ['instagram','writer'], ['threads','writer'], ['facebook','writer'],
    ['instagram','artist'], ['threads','artist'], ['facebook','artist']
  ];
  const htmlRows = slots.map(([p,a]) => {{
    const cur = (m[p]||{{}})[a] || '';
    const list = (opts[a]||[]).map(v => `<option ${{v===cur?'selected':''}} value="${{v}}">${{v}}</option>`).join('');
    return `<div><b>${{p}}/${{a}}</b> <select id="slot-${{p}}-${{a}}">${{list}}</select></div>`;
  }}).join('');
  document.getElementById('mapping').innerHTML = htmlRows;
}}
async function loadFile() {{
  const skill = document.getElementById('skillSel').value;
  const file = document.getElementById('fileSel').value;
  const resp = await fetch('/api/skills/file?skill=' + encodeURIComponent(skill) + '&file=' + encodeURIComponent(file));
  const data = await resp.json();
  document.getElementById('editor').value = data.content || '';
  document.getElementById('result').textContent = JSON.stringify(data, null, 2);
}}
async function saveFile() {{
  const payload = {{
    skill: document.getElementById('skillSel').value,
    file: document.getElementById('fileSel').value,
    content: document.getElementById('editor').value
  }};
  const resp = await fetch('/api/skills/file', {{
    method:'POST',
    headers:{{'Content-Type':'application/json','X-CSRF-Token':csrf}},
    body: JSON.stringify(payload)
  }});
  const data = await resp.json();
  document.getElementById('result').textContent = JSON.stringify(data, null, 2);
  await refreshSchema();
}}
async function saveMapping() {{
  const mapping = {{}};
  for (const p of ['instagram','threads','facebook']) {{
    mapping[p] = {{}};
    for (const a of ['writer','artist']) {{
      const el = document.getElementById(`slot-${{p}}-${{a}}`);
      mapping[p][a] = el ? el.value : '';
    }}
  }}
  const resp = await fetch('/api/skills/mapping', {{
    method:'POST',
    headers:{{'Content-Type':'application/json','X-CSRF-Token':csrf}},
    body: JSON.stringify({{mapping}})
  }});
  const data = await resp.json();
  document.getElementById('result').textContent = JSON.stringify(data, null, 2);
  await refreshSchema();
}}
document.getElementById('skillSel').addEventListener('change', refreshFiles);
refreshSchema();
</script>
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
        if ip in ("127.0.0.1", "::1", "localhost"):
            return True
        try:
            addr = ipaddress.ip_address(ip)
            # In docker-host/devcontainer setups, requests may arrive from private
            # bridge addresses instead of loopback.
            return addr.is_private
        except ValueError:
            return False

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

    def _query(self) -> tuple[str, dict[str, list[str]]]:
        u = urllib.parse.urlparse(self.path)
        return u.path, urllib.parse.parse_qs(u.query, keep_blank_values=True)

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
        path, query = self._query()
        if path == "/healthz":
            self._json({"ok": True, "service": "am-dashboard"})
            return
        if path == "/api/status":
            rc, out = run(["bash", "scripts/env-check.sh"])
            self._json({"ok": rc == 0, "output": out})
            return
        if path.startswith("/api/runs"):
            self._json({"ok": True, "runs": list_runs()})
            return
        if path.startswith("/api/check/"):
            action = path.removeprefix("/api/check/").strip("/")
            cmd = self.CHECK_ACTIONS.get(action)
            if not cmd:
                self._json({"ok": False, "error": "unknown check"}, code=404)
                return
            if action == "cli-auth":
                self._json(cli_auth_status())
                return
            rc, out = run_safe(cmd, timeout_s=20)
            next_steps = []
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
        if path == "/api/settings/schema":
            self._json({"ok": True, "fields": schema_payload()})
            return
        if path == "/api/settings/status":
            self._json({"ok": True, "fields": status_payload(_load_env_values())})
            return
        if path == "/api/skills/schema":
            self._json({"ok": True, **_skills_schema()})
            return
        if path == "/api/skills/files":
            skill = (query.get("skill") or [""])[0]
            try:
                _safe_skill_name(skill)
            except ValueError as e:
                self._json({"ok": False, "error": str(e)}, code=400)
                return
            self._json({"ok": True, "skill": skill, "files": _editable_files(skill)})
            return
        if path == "/api/skills/file":
            skill = (query.get("skill") or [""])[0]
            filename = (query.get("file") or [""])[0]
            try:
                p = _safe_skill_file_path(skill, filename)
            except ValueError as e:
                self._json({"ok": False, "error": str(e)}, code=400)
                return
            content = p.read_text(encoding="utf-8") if p.is_file() else ""
            self._json({"ok": True, "skill": skill, "file": filename, "content": content})
            return
        if path == "/user":
            raw = _user_html().encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)
            return
        if path == "/settings":
            raw = _settings_html().encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)
            return
        if path == "/skills":
            raw = _skills_html().encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)
            return
        if path == "/":
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
        if self.path == "/api/skills/file":
            if not _write_enabled():
                self._json({"ok": False, "error": "write disabled"}, code=403)
                return
            skill = str(payload.get("skill", ""))
            filename = str(payload.get("file", ""))
            content = payload.get("content", "")
            if not isinstance(content, str):
                self._json({"ok": False, "error": "content must be string"}, code=400)
                return
            if len(content.encode("utf-8")) > MAX_SKILL_FILE_BYTES:
                self._json({"ok": False, "error": "content too large"}, code=400)
                return
            client_ip = self.client_address[0]
            try:
                p = _safe_skill_file_path(skill, filename)
            except ValueError as e:
                self._json({"ok": False, "error": str(e)}, code=400)
                return
            try:
                with _edit_lock():
                    had_original = p.exists()
                    backup = _backup_copy(p) if had_original else None
                    _write_text_atomic(p, content)
                    rc_v, out_v = run_safe(["bash", "scripts/amctl.sh", "skill", "validate", skill], timeout_s=45)
                    if rc_v != 0:
                        if backup and backup.is_file():
                            _write_text_atomic(p, backup.read_text(encoding="utf-8"))
                        elif not had_original and p.exists():
                            p.unlink()
                        _audit_skill(
                            "skill_file_save",
                            False,
                            client_ip,
                            skill=skill,
                            file=filename,
                            stage="validate",
                            error=out_v,
                        )
                        self._json({"ok": False, "stage": "validate", "output": out_v}, code=400)
                        return
                    rc_a, out_a = run_safe(["bash", "scripts/amctl.sh", "apply"], timeout_s=90)
                    if rc_a != 0:
                        if backup and backup.is_file():
                            _write_text_atomic(p, backup.read_text(encoding="utf-8"))
                        elif not had_original and p.exists():
                            p.unlink()
                        run_safe(["bash", "scripts/amctl.sh", "apply"], timeout_s=90)
                        _audit_skill(
                            "skill_file_save",
                            False,
                            client_ip,
                            skill=skill,
                            file=filename,
                            stage="apply",
                            error=out_a,
                        )
                        self._json({"ok": False, "stage": "apply", "output": out_a}, code=400)
                        return
                _audit_skill("skill_file_save", True, client_ip, skill=skill, file=filename)
                self._json({"ok": True, "skill": skill, "file": filename, "validate_output": out_v, "apply_output": out_a})
                return
            except Exception as e:
                _audit_skill("skill_file_save", False, client_ip, skill=skill, file=filename, error=str(e))
                self._json({"ok": False, "error": str(e)}, code=500)
                return
        if self.path == "/api/skills/mapping":
            if not _write_enabled():
                self._json({"ok": False, "error": "write disabled"}, code=403)
                return
            mapping = payload.get("mapping")
            if not isinstance(mapping, dict):
                self._json({"ok": False, "error": "mapping must be object"}, code=400)
                return
            skill_types = {d.name: _skill_types(d) for d in _skill_dirs()}
            updates: list[tuple[str, str, str]] = []
            try:
                for platform in PLATFORMS:
                    row = mapping.get(platform)
                    if not isinstance(row, dict):
                        raise ValueError(f"missing mapping for {platform}")
                    for artifact in ARTIFACTS:
                        skill = str(row.get(artifact, "")).strip()
                        if not skill:
                            raise ValueError(f"missing {platform}/{artifact}")
                        _safe_skill_name(skill)
                        if artifact not in skill_types.get(skill, set()):
                            raise ValueError(f"{skill} is not a valid {artifact} skill")
                        updates.append((platform, artifact, skill))
            except ValueError as e:
                self._json({"ok": False, "error": str(e)}, code=400)
                return

            client_ip = self.client_address[0]
            try:
                with _edit_lock():
                    old_config = _load_platform_config()
                    prev_backup = _backup_copy(PLATFORM_YAML) if PLATFORM_YAML.exists() else None
                    new_mapping = _current_platform_mapping(old_config)
                    if any(not new_mapping[p][a] for p in PLATFORMS for a in ARTIFACTS):
                        self._json({"ok": False, "error": "platform mapping structure not found in platform.yaml"}, code=500)
                        return
                    for platform, artifact, skill in updates:
                        new_mapping[platform][artifact] = skill
                    _save_platform_config_atomic(_replace_platform_mapping(old_config, new_mapping))

                    validated = sorted({s for _, _, s in updates})
                    validate_out: dict[str, str] = {}
                    for s in validated:
                        rc_v, out_v = run_safe(["bash", "scripts/amctl.sh", "skill", "validate", s], timeout_s=45)
                        validate_out[s] = out_v
                        if rc_v != 0:
                            if prev_backup and prev_backup.is_file():
                                _write_text_atomic(PLATFORM_YAML, prev_backup.read_text(encoding="utf-8"))
                            _audit_skill(
                                "skill_mapping_save",
                                False,
                                client_ip,
                                stage="validate",
                                skill=s,
                                error=out_v,
                            )
                            self._json({"ok": False, "stage": "validate", "skill": s, "output": out_v}, code=400)
                            return

                    rc_a, out_a = run_safe(["bash", "scripts/amctl.sh", "apply"], timeout_s=90)
                    if rc_a != 0:
                        if prev_backup and prev_backup.is_file():
                            _write_text_atomic(PLATFORM_YAML, prev_backup.read_text(encoding="utf-8"))
                            run_safe(["bash", "scripts/amctl.sh", "apply"], timeout_s=90)
                        _audit_skill("skill_mapping_save", False, client_ip, stage="apply", error=out_a)
                        self._json({"ok": False, "stage": "apply", "output": out_a}, code=400)
                        return
                _audit_skill(
                    "skill_mapping_save",
                    True,
                    client_ip,
                    updates=[{"platform": p, "artifact": a, "skill": s} for p, a, s in updates],
                )
                self._json({"ok": True, "mapping": _current_platform_mapping(), "validate_output": validate_out, "apply_output": out_a})
                return
            except Exception as e:
                _audit_skill("skill_mapping_save", False, client_ip, error=str(e))
                self._json({"ok": False, "error": str(e)}, code=500)
                return
        self._json({"ok": False, "error": "not found"}, code=404)


def main() -> int:
    httpd = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"dashboard: http://{HOST}:{PORT}", flush=True)
    httpd.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
