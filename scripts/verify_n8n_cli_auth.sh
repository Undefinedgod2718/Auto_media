#!/usr/bin/env bash
# Verify n8n container: claude, codex, gemini CLI binaries + auth.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/load_env.sh
source "${ROOT}/scripts/lib/load_env.sh"
load_repo_env "$ROOT"
# shellcheck source=scripts/lib/common.sh
source "${ROOT}/scripts/lib/common.sh"
# shellcheck source=scripts/lib/docker_helpers.sh
source "${ROOT}/scripts/lib/docker_helpers.sh"

export REPO_ROOT="$ROOT"
N8N_CONTAINER="$(resolve_n8n_container "$ROOT")"
export N8N_CONTAINER
STRICT="${VERIFY_CLI_STRICT:-0}"

if ! docker_cli exec "$N8N_CONTAINER" true 2>/dev/null; then
  msg="cannot docker exec ${N8N_CONTAINER} — run: docker compose up -d n8n"
  if [[ "$STRICT" == "1" ]]; then
    json_err "$msg"
  fi
  echo "WARN: $msg" >&2
  json_ok "verify_n8n_cli_auth_skipped"
  exit 0
fi

export AUTO_MEDIA_ROOT="$ROOT"
python3 - <<'PY'
import json
import os
import subprocess

from pathlib import Path

root = Path(os.environ["AUTO_MEDIA_ROOT"])
container = os.environ.get("N8N_CONTAINER", "auto_media-n8n-1")
strict = os.environ.get("VERIFY_CLI_STRICT", "0") == "1"


def docker_run(*args: str) -> tuple[int, str]:
    for sock in ("/var/run/docker.sock", "/var/run/docker-host.sock"):
        if not os.path.exists(sock):
            continue
        cmd = (
            ["sudo", "docker", "exec", container, *args]
            if "docker-host" in sock
            else ["docker", "exec", container, *args]
        )
        p = subprocess.run(cmd, capture_output=True, text=True)
        return p.returncode, (p.stdout or "") + (p.stderr or "")
    return 127, "no docker socket"


def sh_ok(script: str) -> bool:
    rc, _ = docker_run("bash", "-lc", script)
    return rc == 0


checks: dict[str, dict] = {}

checks["claude_cli"] = {
    "ok": sh_ok("command -v claude >/dev/null && claude --version >/dev/null 2>&1"),
    "hint": "rebuild n8n image",
}
oauth = sh_ok("test -r /data/secrets/claude/.credentials.json")
api_env = sh_ok('test -n "${ANTHROPIC_API_KEY:-}" || test -n "${CLAUDE_CODE_OAUTH_TOKEN:-}"')
checks["claude_auth"] = {"ok": oauth or api_env, "hint": "sync_claude_oauth.sh or ANTHROPIC_API_KEY"}

checks["codex_cli"] = {
    "ok": sh_ok("command -v codex >/dev/null && codex --version >/dev/null 2>&1"),
    "hint": "INSTALL_CODEX=true rebuild",
}
checks["codex_auth"] = {"ok": sh_ok("test -r /home/node/.codex/auth.json"), "hint": "sync_codex_oauth.sh"}

checks["gemini_cli"] = {
    "ok": sh_ok("command -v gemini >/dev/null && gemini --version >/dev/null 2>&1"),
    "hint": "rebuild n8n image",
}
g_oauth = sh_ok(
    "test -r /home/node/.gemini/oauth_creds.json || test -s /home/node/.gemini/google_accounts.json"
)
g_api = sh_ok('test -n "${GEMINI_API_KEY:-}"')
checks["gemini_auth"] = {"ok": g_oauth or g_api, "hint": "sync_gemini_oauth.sh or GEMINI_API_KEY"}

providers = {
    "claude": checks["claude_cli"]["ok"] and checks["claude_auth"]["ok"],
    "codex": checks["codex_cli"]["ok"] and checks["codex_auth"]["ok"],
    "gemini": checks["gemini_cli"]["ok"] and checks["gemini_auth"]["ok"],
}
all_ok = all(providers.values())
hints = [f"{k}: not ready" for k, v in providers.items() if not v]

out = {"ok": all_ok, "path": "verify_n8n_cli_auth", "providers": providers, "checks": checks}
if hints:
    out["hints"] = hints
print(json.dumps(out, ensure_ascii=False))
raise SystemExit(0 if all_ok or not strict else 1)
PY
