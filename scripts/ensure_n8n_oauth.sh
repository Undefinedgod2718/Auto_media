#!/usr/bin/env bash
# Ensure n8n container sees CLI OAuth (auto-inject when host has secrets but bind mount is empty).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

CONTAINER="${N8N_CONTAINER:-auto_media-n8n-1}"
INJECT="${ROOT}/scripts/inject_n8n_secrets.sh"

docker_exec() {
  if [[ -S /var/run/docker.sock ]]; then
    docker exec "$CONTAINER" "$@"
  elif [[ -S /var/run/docker-host.sock ]]; then
    sudo docker exec "$CONTAINER" "$@"
  else
    return 127
  fi
}

container_running() {
  docker_exec true 2>/dev/null
}

host_has_claude() {
  [[ -f "${REPO_ROOT}/data/secrets/claude/.credentials.json" ]]
}

host_has_gemini() {
  [[ -f "${REPO_ROOT}/data/secrets/gemini/oauth_creds.json" ]] \
    || [[ -s "${REPO_ROOT}/data/secrets/gemini/google_accounts.json" ]]
}

host_has_codex() {
  [[ -f "${REPO_ROOT}/data/secrets/codex/auth.json" ]]
}

container_has_claude() {
  docker_exec runuser -u node -- test -r /data/secrets/claude/.credentials.json 2>/dev/null
}

container_has_gemini() {
  docker_exec runuser -u node -- sh -c '
    test -r /home/node/.gemini/oauth_creds.json \
      || test -s /home/node/.gemini/google_accounts.json
  ' 2>/dev/null
}

container_has_codex() {
  docker_exec runuser -u node -- test -r /home/node/.codex/auth.json 2>/dev/null
}

needs_inject=false
reasons=()

if ! container_running; then
  python3 -c 'import json; print(json.dumps({"ok":True,"skipped":True,"reason":"n8n container not running","container":"'"$CONTAINER"'"}))'
  exit 0
fi

if host_has_claude && ! container_has_claude; then
  needs_inject=true
  reasons+=("claude_credentials_missing_in_container")
fi
if host_has_gemini && ! container_has_gemini; then
  needs_inject=true
  reasons+=("gemini_oauth_missing_in_container")
fi
if host_has_codex && ! container_has_codex; then
  needs_inject=true
  reasons+=("codex_auth_missing_in_container")
fi

if [[ "$needs_inject" != "true" ]]; then
  python3 -c 'import json; print(json.dumps({"ok":True,"injected":False,"container":"'"$CONTAINER"'","hint":"oauth already visible in n8n"}))'
  exit 0
fi

echo "ensure_n8n_oauth: injecting (${reasons[*]})" >&2
bash "$INJECT" >&2

claude_ok=false
gemini_ok=false
codex_ok=false
container_has_claude && claude_ok=true
container_has_gemini && gemini_ok=true
container_has_codex && codex_ok=true

REASONS_JSON="$(printf '%s\n' "${reasons[@]}" | python3 -c 'import json,sys; print(json.dumps([l for l in sys.stdin.read().splitlines() if l]))')"
python3 -c 'import json,sys
print(json.dumps({
    "ok": True,
    "injected": True,
    "container": sys.argv[1],
    "reasons": json.loads(sys.argv[2]),
    "claude_ok": sys.argv[3] == "true",
    "gemini_ok": sys.argv[4] == "true",
    "codex_ok": sys.argv[5] == "true",
}, ensure_ascii=False))' \
  "$CONTAINER" "$REASONS_JSON" "$claude_ok" "$gemini_ok" "$codex_ok"
