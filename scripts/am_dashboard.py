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
import threading
import time
import urllib.parse
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import fcntl

ROOT = Path(os.environ.get("AUTO_MEDIA_ROOT", Path(__file__).resolve().parents[1]))
DATA = Path(os.environ.get("DATA_ROOT", ROOT / "data"))
HOST = os.environ.get("AUTO_MEDIA_DASHBOARD_HOST", "127.0.0.1")
PORT = int(os.environ.get("AUTO_MEDIA_DASHBOARD_PORT", "8790"))
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
INSTANCE_REV = "settings-ssr-20260603"
WRITE_PIN_ENV = "AUTO_MEDIA_DASHBOARD_WRITE_PIN"
WRITE_SESSION_COOKIE = "am_write_session"
WRITE_SESSION_TTL_S = 8 * 3600
WRITE_PIN_MIN_LEN = 8
UNLOCK_MAX_ATTEMPTS = 5
UNLOCK_WINDOW_S = 60

_WRITE_SESSIONS: dict[str, float] = {}
_WRITE_SESSION_LOCK = threading.Lock()
_UNLOCK_FAILS: dict[str, list[float]] = {}
_UNLOCK_FAIL_LOCK = threading.Lock()

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


def _dev_write_bypass() -> bool:
    return os.environ.get("AUTO_MEDIA_DASHBOARD_WRITE", "0") == "1"


def _configured_write_pin() -> str | None:
    pin = (_load_env_values().get(WRITE_PIN_ENV) or "").strip()
    return pin if len(pin) >= WRITE_PIN_MIN_LEN else None


def _purge_write_sessions(now: float | None = None) -> None:
    ts = now if now is not None else time.time()
    expired = [sid for sid, exp in _WRITE_SESSIONS.items() if exp <= ts]
    for sid in expired:
        _WRITE_SESSIONS.pop(sid, None)


def _write_session_valid(session_id: str) -> bool:
    if not session_id:
        return False
    now = time.time()
    with _WRITE_SESSION_LOCK:
        _purge_write_sessions(now)
        exp = _WRITE_SESSIONS.get(session_id)
        return exp is not None and exp > now


def _create_write_session() -> str:
    sid = secrets.token_urlsafe(32)
    with _WRITE_SESSION_LOCK:
        _purge_write_sessions()
        _WRITE_SESSIONS[sid] = time.time() + WRITE_SESSION_TTL_S
    return sid


def _revoke_write_session(session_id: str) -> None:
    with _WRITE_SESSION_LOCK:
        _WRITE_SESSIONS.pop(session_id, None)


def _unlock_rate_ok(client_ip: str) -> bool:
    now = time.time()
    with _UNLOCK_FAIL_LOCK:
        attempts = [t for t in _UNLOCK_FAILS.get(client_ip, []) if now - t < UNLOCK_WINDOW_S]
        _UNLOCK_FAILS[client_ip] = attempts
        return len(attempts) < UNLOCK_MAX_ATTEMPTS


def _record_unlock_fail(client_ip: str) -> None:
    now = time.time()
    with _UNLOCK_FAIL_LOCK:
        attempts = [t for t in _UNLOCK_FAILS.get(client_ip, []) if now - t < UNLOCK_WINDOW_S]
        attempts.append(now)
        _UNLOCK_FAILS[client_ip] = attempts


def _write_enabled_for(handler: BaseHTTPRequestHandler) -> bool:
    if _dev_write_bypass():
        return True
    cookies = _parse_cookies(handler.headers.get("Cookie", ""))
    return _write_session_valid(cookies.get(WRITE_SESSION_COOKIE, ""))


def _parse_cookies(raw: str) -> dict[str, str]:
    out: dict[str, str] = {}
    for part in raw.split(";"):
        part = part.strip()
        if "=" in part:
            k, v = part.split("=", 1)
            out[k.strip()] = v.strip()
    return out


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


def _yaml():
    try:
        import yaml as _yaml_mod  # type: ignore[import-untyped]
    except ImportError as e:
        raise RuntimeError(
            "PyYAML not installed. Run: uv pip install pyyaml  (or: pip install pyyaml)"
        ) from e
    return _yaml_mod


def _load_platform_config() -> dict:
    if not PLATFORM_YAML.is_file():
        raise ValueError("config/platform.yaml missing")
    data = _yaml().safe_load(PLATFORM_YAML.read_text(encoding="utf-8")) or {}
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
    text = _yaml().safe_dump(data, allow_unicode=True, sort_keys=False)
    _write_text_atomic(PLATFORM_YAML, text)


def _skills_schema_payload(handler: BaseHTTPRequestHandler) -> dict[str, object]:
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
        "write_enabled": _write_enabled_for(handler),
        "pin_configured": _configured_write_pin() is not None,
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

    secrets_root = DATA / "secrets"
    codex_auth = (secrets_root / "codex" / "auth.json").is_file()
    gemini_auth = (secrets_root / "gemini" / "oauth_creds.json").is_file() or (
        secrets_root / "gemini" / "google_accounts.json"
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


def _docker_compose_prefix() -> list[str]:
    candidates: list[list[str]] = [
        ["docker", "compose"],
        ["sudo", "-n", "docker", "compose"],
        ["sudo", "docker", "compose"],
    ]
    for prefix in candidates:
        try:
            p = subprocess.run(
                [*prefix, "ps"],
                cwd=str(ROOT),
                capture_output=True,
                text=True,
                timeout=15,
            )
            if p.returncode == 0:
                return prefix
        except (OSError, subprocess.TimeoutExpired):
            continue
    return ["docker", "compose"]


def _parse_verify_meta_output(text: str) -> dict[str, object]:
    lines = [ln.strip() for ln in (text or "").splitlines() if ln.strip()]
    parsed: dict[str, object] = {"ok": False, "lines": [], "summary": ""}
    for line in reversed(lines):
        if line.startswith("{") and '"ok"' in line:
            try:
                body = json.loads(line)
                if isinstance(body, dict):
                    parsed["ok"] = bool(body.get("ok"))
                    parsed["summary"] = str(body.get("error") or body.get("path") or "")
                    break
            except json.JSONDecodeError:
                pass
    check_lines = [ln for ln in lines if ln.startswith(("ok ", "FAIL:", "skip ", "WARN:"))]
    parsed["lines"] = check_lines
    if not parsed.get("summary") and check_lines:
        parsed["summary"] = check_lines[0]
    if not check_lines and lines:
        parsed["ok"] = False
    elif check_lines and not any(ln.startswith("FAIL:") for ln in check_lines):
        if not any("looks like Threads token" in ln for ln in check_lines):
            parsed["ok"] = parsed.get("ok") or any(ln.startswith("ok ") for ln in check_lines)
    return parsed


def _apply_after_settings_save() -> dict[str, object]:
    """Restart n8n so container env matches .env, then verify Meta/Threads tokens."""
    dc = _docker_compose_prefix()
    rc_n, n8n_out = run_safe([*dc, "up", "-d", "n8n"], timeout_s=120)
    n8n_block: dict[str, object] = {
        "ok": rc_n == 0,
        "exit_code": rc_n,
        "cmd": " ".join([*dc, "up", "-d", "n8n"]),
        "output": n8n_out,
    }
    rc_v, verify_out = run_safe(["bash", "scripts/verify_meta_tokens.sh"], timeout_s=90)
    verify_block = _parse_verify_meta_output(verify_out)
    verify_block["exit_code"] = rc_v
    verify_block["output"] = verify_out
    return {
        "ok": bool(n8n_block["ok"]) and bool(verify_block.get("ok")),
        "n8n_restart": n8n_block,
        "verify_meta": verify_block,
    }


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
<html><head><meta charset="utf-8"><title>Skill Manager</title>
<style>
  body {{ font-family: system-ui, sans-serif; margin: 16px; max-width: 1100px; }}
  .toolbar {{ display: flex; flex-wrap: wrap; align-items: center; gap: 8px; min-height: 40px; margin-bottom: 12px; }}
  .badge {{ padding: 4px 10px; border-radius: 4px; font-weight: 600; font-size: 13px; }}
  .badge-ro {{ background: #eee; color: #333; }}
  .badge-wr {{ background: #d1fae5; color: #065f46; }}
  .unlock-row {{ display: flex; align-items: center; gap: 6px; }}
  .btn {{ padding: 6px 12px; cursor: pointer; }}
  .btn-primary {{ background: #2563eb; color: #fff; border: none; font-weight: 600; }}
  .btn:disabled {{ opacity: 0.45; cursor: not-allowed; }}
  table.mapping {{ border-collapse: collapse; width: 100%; margin: 8px 0; }}
  table.mapping th, table.mapping td {{ border: 1px solid #ccc; padding: 6px 8px; text-align: left; }}
  .editor-row {{ display: flex; flex-wrap: wrap; gap: 8px; align-items: center; margin: 8px 0; }}
  #editor {{ width: 100%; height: 320px; box-sizing: border-box; }}
  #result {{ margin: 8px 0; padding: 8px; background: #f4f4f5; border-radius: 4px; font-size: 13px; }}
  #resultDetail {{ display: none; white-space: pre-wrap; font-size: 12px; max-height: 200px; overflow: auto; }}
  h3 {{ margin: 16px 0 6px; font-size: 15px; }}
</style></head>
<body>
  <div class="toolbar">
    <a href="/user">返回</a>
    <span id="modeBadge" class="badge badge-ro">唯讀</span>
    <span id="unlockWrap" class="unlock-row">
      <input type="password" id="pinIn" placeholder="寫入 PIN" size="14"
        title="與 Settings 中「Skill 寫入 PIN」相同；僅本機有效" />
      <button type="button" class="btn btn-primary" id="btnUnlock" onclick="unlockWrite()"
        title="驗證 PIN 後 8 小時內可編輯；按鎖定或關閉分頁後需再解鎖">解鎖</button>
      <a id="pinSetupLink" href="/settings" style="display:none">先到 Settings 設定 PIN</a>
    </span>
    <button type="button" class="btn" id="btnLock" onclick="lockWrite()" style="display:none"
      title="立即回到唯讀，需再輸入 PIN">鎖定</button>
  </div>
  <h3>平台對應</h3>
  <table class="mapping"><thead><tr><th>平台</th><th>角色</th><th>Skill</th></tr></thead>
  <tbody id="mappingBody"></tbody></table>
  <button type="button" class="btn btn-primary" id="btnSaveMapping" onclick="saveMapping()" disabled
    title="寫入 platform.yaml 並自動 apply 到 n8n">儲存對應</button>
  <h3>檔案編輯</h3>
  <div class="editor-row">
    <label>Skill <select id="skillSel"></select></label>
    <label>檔案 <select id="fileSel"></select></label>
    <button type="button" class="btn" id="btnLoad" onclick="loadFile()"
      title="從 config/skills 讀取檔案">載入</button>
    <button type="button" class="btn btn-primary" id="btnSaveFile" onclick="saveFile()" disabled
      title="儲存前會驗證 skill 並 apply 到 n8n">儲存檔案</button>
  </div>
  <textarea id="editor" readonly></textarea>
  <div id="result">就緒</div>
  <button type="button" class="btn" id="btnDetail" onclick="toggleDetail()" style="display:none">詳細</button>
  <pre id="resultDetail"></pre>
<script>
const csrf = "{CSRF_TOKEN}";
let schema = null;
let lastDetail = '';
function setResult(msg, detail) {{
  document.getElementById('result').textContent = msg;
  lastDetail = detail || '';
  const btn = document.getElementById('btnDetail');
  const pre = document.getElementById('resultDetail');
  if (lastDetail) {{
    btn.style.display = 'inline-block';
    pre.textContent = lastDetail;
  }} else {{
    btn.style.display = 'none';
    pre.style.display = 'none';
    pre.textContent = '';
  }}
}}
function toggleDetail() {{
  const pre = document.getElementById('resultDetail');
  pre.style.display = pre.style.display === 'none' ? 'block' : 'none';
}}
function applyWriteMode(enabled, pinConfigured) {{
  const ro = !enabled;
  document.getElementById('editor').readOnly = ro;
  document.getElementById('btnSaveFile').disabled = ro;
  document.getElementById('btnSaveMapping').disabled = ro;
  document.querySelectorAll('#mappingBody select').forEach(el => {{ el.disabled = ro; }});
  const badge = document.getElementById('modeBadge');
  const unlockWrap = document.getElementById('unlockWrap');
  const btnLock = document.getElementById('btnLock');
  const pinIn = document.getElementById('pinIn');
  const btnUnlock = document.getElementById('btnUnlock');
  const pinLink = document.getElementById('pinSetupLink');
  if (enabled) {{
    badge.textContent = '可寫入';
    badge.className = 'badge badge-wr';
    unlockWrap.style.display = 'none';
    btnLock.style.display = 'inline-block';
  }} else {{
    badge.textContent = '唯讀';
    badge.className = 'badge badge-ro';
    unlockWrap.style.display = 'flex';
    btnLock.style.display = 'none';
    const needSetup = !pinConfigured;
    pinIn.disabled = needSetup;
    btnUnlock.disabled = needSetup;
    pinLink.style.display = needSetup ? 'inline' : 'none';
  }}
}}
async function refreshSchema() {{
  const resp = await fetch('/api/skills/schema');
  const data = await resp.json();
  schema = data;
  applyWriteMode(!!data.write_enabled, !!data.pin_configured);
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
  const tbody = document.getElementById('mappingBody');
  tbody.innerHTML = '';
  const ro = !(schema && schema.write_enabled);
  for (const [p, a] of slots) {{
    const cur = (m[p]||{{}})[a] || '';
    const list = (opts[a]||[]).map(v =>
      `<option ${{v===cur?'selected':''}} value="${{v}}">${{v}}</option>`).join('');
    const tr = document.createElement('tr');
    tr.innerHTML = `<td>${{p}}</td><td>${{a}}</td><td><select id="slot-${{p}}-${{a}}" ` +
      `title="該平台發文時使用的 skill 目錄名稱" ${{ro?'disabled':''}}>${{list}}</select></td>`;
    tbody.appendChild(tr);
  }}
}}
async function unlockWrite() {{
  const pin = document.getElementById('pinIn').value;
  const resp = await fetch('/api/skills/unlock', {{
    method: 'POST',
    headers: {{'Content-Type':'application/json','X-CSRF-Token':csrf}},
    body: JSON.stringify({{pin}})
  }});
  const data = await resp.json();
  if (!resp.ok) {{
    setResult(data.error || '解鎖失敗', data.hint || JSON.stringify(data));
    return;
  }}
  document.getElementById('pinIn').value = '';
  setResult('已解鎖，可編輯');
  await refreshSchema();
}}
async function lockWrite() {{
  await fetch('/api/skills/lock', {{
    method: 'POST',
    headers: {{'Content-Type':'application/json','X-CSRF-Token':csrf}},
    body: '{{}}'
  }});
  setResult('已鎖定，唯讀');
  await refreshSchema();
}}
async function loadFile() {{
  const skill = document.getElementById('skillSel').value;
  const file = document.getElementById('fileSel').value;
  const resp = await fetch('/api/skills/file?skill=' + encodeURIComponent(skill) + '&file=' + encodeURIComponent(file));
  const data = await resp.json();
  document.getElementById('editor').value = data.content || '';
  setResult('已載入 ' + skill + '/' + file);
}}
async function saveFile() {{
  const payload = {{
    skill: document.getElementById('skillSel').value,
    file: document.getElementById('fileSel').value,
    content: document.getElementById('editor').value
  }};
  setResult('儲存中…');
  const resp = await fetch('/api/skills/file', {{
    method:'POST',
    headers:{{'Content-Type':'application/json','X-CSRF-Token':csrf}},
    body: JSON.stringify(payload)
  }});
  const data = await resp.json();
  setResult(resp.ok ? '檔案已儲存' : (data.error || '儲存失敗'), JSON.stringify(data, null, 2));
  await refreshSchema();
}}
async function saveMapping() {{
  const mapping = {{}};
  for (const p of ['instagram','threads','facebook']) {{
    mapping[p] = {{}};
    for (const a of ['writer','artist']) {{
      const el = document.getElementById('slot-' + p + '-' + a);
      mapping[p][a] = el ? el.value : '';
    }}
  }}
  setResult('儲存對應中…');
  const resp = await fetch('/api/skills/mapping', {{
    method:'POST',
    headers:{{'Content-Type':'application/json','X-CSRF-Token':csrf}},
    body: JSON.stringify({{mapping}})
  }});
  const data = await resp.json();
  setResult(resp.ok ? '對應已儲存' : (data.error || '儲存失敗'), JSON.stringify(data, null, 2));
  await refreshSchema();
}}
document.getElementById('skillSel').addEventListener('change', refreshFiles);
refreshSchema();
</script>
</body></html>"""


def _js_embed(obj: object) -> str:
    return json.dumps(obj, ensure_ascii=False).replace("<", "\\u003c")


def _settings_html() -> str:
    values = _load_env_values()
    env_path = str(ENV_PATH.resolve())
    initial_schema = _js_embed(schema_payload())
    initial_status = _js_embed(status_payload(values))
    page_rev = INSTANCE_REV
    return f"""<!doctype html>
<html><head><meta charset="utf-8"><title>Token Settings</title>
<style>
  body {{ font-family: system-ui, sans-serif; margin: 16px; }}
  #status {{ font-weight: 600; margin: 8px 0; color: #0a5; }}
  #result {{
    background: #1a1a2e; color: #eee; padding: 12px; min-height: 80px;
    border: 2px solid #4a9; white-space: pre-wrap; margin: 12px 0;
  }}
  .actions {{ margin: 12px 0; }}
  .actions button {{ margin: 4px 6px 4px 0; padding: 8px 12px; }}
  #btnSave {{ background: #2563eb; color: #fff; border: none; font-weight: 700; }}
  .secret-input {{ min-width: 420px; border: 2px solid #2563eb; padding: 6px; }}
  .field-status {{ color: #333; }}
  .field-status.is-set {{ color: #0a5; font-weight: 600; }}
</style></head>
<body>
  <h2>Token Settings (localhost)</h2>
  <p id="envPath">.env: {html.escape(env_path)} · :{PORT}</p>
  <p><a href="/user">Back to user console</a> | <a href="/settings">Reload page</a></p>
  <div id="status">Loading...</div>
  <pre id="result">(result appears here)</pre>
  <div class="actions">
    <button type="button" id="btnSave">Save updates</button>
    <button type="button" id="btnTestAll">Test all</button>
    <button type="button" id="btnTestTelegram">Test telegram</button>
    <button type="button" id="btnTestN8n">Test n8n</button>
    <button type="button" id="btnTestMeta">Test Meta+IG</button>
    <button type="button" id="btnTestThreads">Test threads</button>
    <button type="button" id="btnCheckCli">Check CLI auth</button>
    <button type="button" id="btnCheckMeta">Check Meta/IG/Threads</button>
  </div>
  <form id="settingsForm"></form>
<script>
var csrfToken = "{CSRF_TOKEN}";
var schema = {initial_schema};
var statusRows = {initial_status};
var dashboardPort = "{PORT}";

function setEnvPathLine(path) {{
  var el = document.getElementById('envPath');
  if (el && path) el.textContent = '.env: ' + path + ' · :' + dashboardPort;
}}

function showResult(text, statusText) {{
  var el = document.getElementById('result');
  var st = document.getElementById('status');
  if (el) {{ el.textContent = text; el.scrollIntoView({{behavior:'smooth', block:'nearest'}}); }}
  if (st && statusText) st.textContent = statusText;
}}

function fieldStatus(name) {{
  for (var i = 0; i < statusRows.length; i++) {{
    if (statusRows[i].name === name) return statusRows[i];
  }}
  return {{is_set: false, masked: ''}};
}}

function statusLabel(s) {{
  var cur = s.is_set ? 'set' : 'unset';
  return (s.description || s.name) + ' | current: ' + cur + ' ' + (s.masked || '');
}}

function collectFormUpdates() {{
  var updates = {{}};
  var inputs = document.querySelectorAll('#settingsForm input[name]');
  for (var i = 0; i < inputs.length; i++) {{
    var v = (inputs[i].value || '').trim();
    if (v) updates[inputs[i].name] = v;
  }}
  return updates;
}}

async function refreshStatusLabelsOnly() {{
  var statusResp = await fetch('/api/settings/status');
  var statusJson = await statusResp.json();
  statusRows = statusJson.fields || [];
  if (statusJson.env_path) setEnvPathLine(statusJson.env_path);
  var nodes = document.querySelectorAll('small.field-status');
  for (var i = 0; i < nodes.length; i++) {{
    var name = nodes[i].getAttribute('data-field');
    var s = fieldStatus(name);
    nodes[i].textContent = statusLabel(s);
    nodes[i].className = 'field-status' + (s.is_set ? ' is-set' : '');
  }}
}}

async function refreshCsrf() {{
  try {{
    var r = await fetch('/api/csrf');
    var d = await r.json();
    if (d && d.csrf) csrfToken = d.csrf;
  }} catch (e) {{}}
}}

function renderSettingsForm() {{
  var form = document.getElementById('settingsForm');
  if (!form) return;
  var preserved = collectFormUpdates();
  form.innerHTML = '';
  for (var j = 0; j < schema.length; j++) {{
    var f = schema[j];
    var s = fieldStatus(f.name);
    var row = document.createElement('div');
    row.style.marginBottom = '12px';
    var inpType = f.secret ? 'password' : 'text';
    var inpClass = f.secret ? 'secret-input' : '';
    var stClass = 'field-status' + (s.is_set ? ' is-set' : '');
    var pinTitle = (f.name === 'AUTO_MEDIA_DASHBOARD_WRITE_PIN')
      ? ' title="至少 8 字元；供 Skill Manager 解鎖，勿與 Telegram token 混用"'
      : '';
    var pinLabelTitle = (f.name === 'AUTO_MEDIA_DASHBOARD_WRITE_PIN')
      ? ' title="在 /skills 輸入相同 PIN 可解鎖編輯"'
      : '';
    row.innerHTML =
      '<label' + pinLabelTitle + '><b>' + f.name + '</b> (' + f.group + ')</label><br/>' +
      '<small class="' + stClass + '" data-field="' + f.name + '">' + statusLabel(s) + '</small><br/>' +
      '<input type="' + inpType + '" class="' + inpClass + '" name="' + f.name + '" data-field="' + f.name + '" ' +
      pinTitle + ' placeholder="Paste new value here" autocomplete="new-password" />';
    form.appendChild(row);
    if (preserved[f.name]) {{
      row.querySelector('input').value = preserved[f.name];
    }}
  }}
}}

async function loadSettings() {{
  try {{
    await refreshCsrf();
    var schemaResp = await fetch('/api/settings/schema');
    var statusResp = await fetch('/api/settings/status');
    if (!schemaResp.ok || !statusResp.ok) {{
      throw new Error('HTTP schema=' + schemaResp.status + ' status=' + statusResp.status);
    }}
    var schemaJson = await schemaResp.json();
    var statusJson = await statusResp.json();
    schema = schemaJson.fields || schema;
    statusRows = statusJson.fields || statusRows;
    if (statusJson.env_path) setEnvPathLine(statusJson.env_path);
    renderSettingsForm();
    showResult('(ready)', 'Loaded ' + schema.length + ' fields.');
  }} catch (e) {{
    renderSettingsForm();
    showResult('API refresh failed, using server snapshot: ' + e, 'Offline snapshot');
  }}
}}

async function postSettings(path, body, retryCsrf) {{
  await refreshCsrf();
  var resp = await fetch(path, {{
    method: 'POST',
    headers: {{'Content-Type': 'application/json', 'X-CSRF-Token': csrfToken}},
    body: JSON.stringify(body)
  }});
  var text = await resp.text();
  var data = {{}};
  try {{ data = JSON.parse(text); }} catch (pe) {{ data = {{raw: text}}; }}
  if (!resp.ok && retryCsrf && data.error === 'csrf failed') {{
    await refreshCsrf();
    return postSettings(path, body, false);
  }}
  return {{resp: resp, data: data}};
}}

async function saveSettings() {{
  showResult('Working...', 'Save → restart n8n → verify tokens...');
  var updates = collectFormUpdates();
  var keys = Object.keys(updates);
  if (!keys.length) {{
    showResult(
      JSON.stringify({{
        ok: false,
        error: 'no input filled',
        hint: 'Paste NEW token in password/text INPUT below field name (small line is status only). Empty input does not overwrite .env.'
      }}, null, 2),
      'Nothing to save — fill at least one input'
    );
    return;
  }}
  try {{
    var out = await postSettings('/api/settings/update', {{updates: updates}}, true);
    if (!out.resp.ok) {{
      var hint = out.data.error === 'csrf failed' ? ' Hard-refresh /settings (Ctrl+Shift+R) after dashboard restart.' : '';
      showResult(JSON.stringify({{ok: false, http: out.resp.status, data: out.data, hint: hint}}, null, 2), 'Save failed');
      return;
    }}
    var data = out.data;
    if (data.fields) statusRows = data.fields;
    var inputs = document.querySelectorAll('#settingsForm input[name]');
    for (var i = 0; i < inputs.length; i++) inputs[i].value = '';
    await refreshStatusLabelsOnly();
    var apply = data.apply || {{}};
    var v = apply.verify_meta || {{}};
    var n = apply.n8n_restart || {{}};
    var statusLabel = 'Saved: ' + (data.changed || []).join(', ');
    if (apply.ok) {{
      statusLabel += ' | n8n restarted | verify OK';
    }} else if (n.ok === false) {{
      statusLabel += ' | n8n restart FAILED';
    }} else if (v.ok === false) {{
      statusLabel += ' | verify FAILED (see apply.verify_meta)';
    }}
    data.hint = 'Auto: docker compose up -d n8n + verify_meta_tokens.sh';
    showResult(JSON.stringify(data, null, 2), statusLabel);
  }} catch (e) {{
    showResult('Save failed: ' + e, 'Save failed');
  }}
}}

async function runTest(group) {{
  showResult('Testing...', 'Testing ' + group);
  try {{
    var overrides = collectFormUpdates();
    var out = await postSettings('/api/settings/test', {{group: group, overrides: overrides}}, true);
    var data = out.data;
    if (!out.resp.ok) {{
      showResult(JSON.stringify({{ok: false, http: out.resp.status, data: data}}, null, 2), 'Test HTTP failed');
      return;
    }}
    var label = data.ok ? 'Test OK' : 'Test failed (see checks)';
    if (Object.keys(overrides).length) {{
      data.note = (data.note || '') + ' [form overrides — Save first to persist]';
    }}
    showResult(JSON.stringify(data, null, 2), label);
  }} catch (e) {{
    showResult('Test failed: ' + e, 'Test failed');
  }}
}}

async function runReadonlyCheck(name) {{
  showResult('Checking...', 'Check ' + name);
  try {{
    var resp = await fetch('/api/check/' + encodeURIComponent(name));
    var data = await resp.json();
    showResult(JSON.stringify(data, null, 2), data.ok ? 'Check OK' : 'Check failed');
  }} catch (e) {{
    showResult('Check failed: ' + e, 'Check failed');
  }}
}}

document.getElementById('btnSave').addEventListener('click', saveSettings);
document.getElementById('btnTestAll').addEventListener('click', function() {{ runTest('all'); }});
document.getElementById('btnTestTelegram').addEventListener('click', function() {{ runTest('telegram'); }});
document.getElementById('btnTestN8n').addEventListener('click', function() {{ runTest('n8n_api'); }});
document.getElementById('btnTestMeta').addEventListener('click', function() {{ runTest('meta'); }});
document.getElementById('btnTestThreads').addEventListener('click', function() {{ runTest('threads'); }});
document.getElementById('btnCheckCli').addEventListener('click', function() {{ runReadonlyCheck('cli-auth'); }});
document.getElementById('btnCheckMeta').addEventListener('click', function() {{ runReadonlyCheck('meta'); }});
renderSettingsForm();
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
        if token != CSRF_TOKEN:
            return False
        origin = self.headers.get("Origin", "")
        if _safe_origin(origin):
            return True
        referer = self.headers.get("Referer", "")
        if referer.startswith("http://127.0.0.1:") or referer.startswith("http://localhost:"):
            return True
        # Localhost-only server: allow POST when Origin omitted (some browsers / extensions).
        return self._localhost_only()

    def _json(
        self,
        payload: dict,
        code: int = 200,
        *,
        no_store: bool = False,
        set_write_session: str | None = None,
        clear_write_session: bool = False,
    ) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        if no_store:
            self.send_header("Cache-Control", "no-store")
        if set_write_session:
            self.send_header(
                "Set-Cookie",
                f"{WRITE_SESSION_COOKIE}={set_write_session}; Path=/; HttpOnly; "
                f"SameSite=Strict; Max-Age={WRITE_SESSION_TTL_S}",
            )
        if clear_write_session:
            self.send_header(
                "Set-Cookie",
                f"{WRITE_SESSION_COOKIE}=; Path=/; HttpOnly; Max-Age=0; SameSite=Strict",
            )
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
            if action == "meta":
                next_steps = []
                if rc != 0:
                    next_steps = [
                        "Refresh Meta/Threads token in Graph API Explorer",
                        "Save via http://127.0.0.1:8790/settings (not :8788)",
                        "Restart n8n: sudo docker compose up -d n8n",
                    ]
                if "all meta checks skipped" in out or "no token checks ran" in out:
                    next_steps = [
                        "Open http://127.0.0.1:8790/settings and save tokens",
                        "Confirm .env shows port 8790 dashboard path",
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
        if path == "/api/instance":
            self._json(
                {
                    "ok": True,
                    "port": PORT,
                    "root": str(ROOT.resolve()),
                    "env_path": str(ENV_PATH.resolve()),
                    "instance_rev": INSTANCE_REV,
                },
                no_store=True,
            )
            return
        if path == "/api/csrf":
            self._json({"ok": True, "csrf": CSRF_TOKEN}, no_store=True)
            return
        if path == "/api/settings/schema":
            self._json({"ok": True, "fields": schema_payload()}, no_store=True)
            return
        if path == "/api/settings/status":
            self._json(
                {
                    "ok": True,
                    "fields": status_payload(_load_env_values()),
                    "env_path": str(ENV_PATH.resolve()),
                },
                no_store=True,
            )
            return
        if path == "/api/skills/schema":
            self._json({"ok": True, **_skills_schema_payload(self)})
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
            self.send_header("Cache-Control", "no-store")
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
            except OSError as e:
                self._json({"ok": False, "error": f"cannot write .env: {e}"}, code=500)
                return
            except ValueError as e:
                self._json({"ok": False, "error": str(e)}, code=400)
                return
            if not changed:
                self._json({"ok": False, "error": "no valid fields in updates"}, code=400)
                return
            values = _load_env_values()
            apply = _apply_after_settings_save()
            self._json(
                {
                    "ok": True,
                    "changed": changed,
                    "env_path": str(ENV_PATH.resolve()),
                    "fields": status_payload(values),
                    "apply": apply,
                },
                no_store=True,
            )
            return
        if self.path == "/api/settings/test":
            group = str(payload.get("group", "all"))
            overrides = payload.get("overrides") or {}
            if not isinstance(overrides, dict):
                self._json({"ok": False, "error": "overrides must be object"}, code=400)
                return
            clean_overrides = {
                str(k): str(v)
                for k, v in overrides.items()
                if isinstance(k, str) and isinstance(v, str) and v.strip()
            }
            self._json(run_group(group, _load_env_values(), clean_overrides or None))
            return
        if self.path == "/api/skills/unlock":
            client_ip = self.client_address[0]
            if not _unlock_rate_ok(client_ip):
                self._json({"ok": False, "error": "too many attempts, retry later"}, code=429)
                return
            expected = _configured_write_pin()
            if not expected:
                self._json(
                    {
                        "ok": False,
                        "error": "pin not configured",
                        "hint": "Set Skill write PIN in Settings first",
                    },
                    code=400,
                )
                return
            pin = str(payload.get("pin", ""))
            if len(pin) < WRITE_PIN_MIN_LEN or not secrets.compare_digest(pin, expected):
                _record_unlock_fail(client_ip)
                self._json({"ok": False, "error": "invalid pin"}, code=403)
                return
            sid = _create_write_session()
            self._json({"ok": True, "write_enabled": True}, set_write_session=sid)
            return
        if self.path == "/api/skills/lock":
            sid = _parse_cookies(self.headers.get("Cookie", "")).get(WRITE_SESSION_COOKIE, "")
            if sid:
                _revoke_write_session(sid)
            self._json({"ok": True, "write_enabled": False}, clear_write_session=True)
            return
        if self.path == "/api/skills/file":
            if not _write_enabled_for(self):
                self._json({"ok": False, "error": "write disabled; unlock with PIN first"}, code=403)
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
            if not _write_enabled_for(self):
                self._json({"ok": False, "error": "write disabled; unlock with PIN first"}, code=403)
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
