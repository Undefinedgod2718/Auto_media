#!/usr/bin/env bash
# Verify n8n container has claude CLI + copy engine auth (OAuth or API key).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

N8N_CONTAINER="${N8N_CONTAINER:-auto_media-n8n-1}"
STRICT="${VERIFY_CLAUDE_STRICT:-0}"
HOST_CREDS="${REPO_ROOT}/data/secrets/claude/.credentials.json"

docker_exec() {
  if [[ -S /var/run/docker.sock ]] || [[ -S /var/run/docker-host.sock ]]; then
    if [[ -S /var/run/docker.sock ]]; then
      docker exec "$N8N_CONTAINER" "$@"
    else
      sudo docker exec "$N8N_CONTAINER" "$@"
    fi
  else
    return 127
  fi
}

failures=()
warnings=()
checks=()

add_check() {
  local name="$1" ok="$2" hint="${3:-}"
  checks+=("${name}=${ok}")
  if [[ "$ok" != "true" ]]; then
    failures+=("${name}: ${hint}")
  fi
}

if ! docker_exec true 2>/dev/null; then
  msg="cannot docker exec ${N8N_CONTAINER} — run: docker compose up -d n8n"
  if [[ "$STRICT" == "1" ]]; then
    json_err "$msg"
  fi
  echo "WARN: $msg" >&2
  json_ok "verify_n8n_claude_engine_skipped"
  exit 0
fi

if docker_exec bash -lc 'command -v claude >/dev/null && claude --version >/dev/null 2>&1'; then
  add_check "claude_cli" true ""
else
  add_check "claude_cli" false "rebuild n8n image (docker/n8n/Dockerfile includes claude-code)"
fi

auth_ok=false
if docker_exec bash -lc 'test -r /data/secrets/claude/.credentials.json'; then
  auth_ok=true
  add_check "oauth_credentials" true ""
else
  add_check "oauth_credentials" false "./scripts/sync_claude_oauth.sh && ./scripts/inject_n8n_secrets.sh"
fi

if [[ -f "$HOST_CREDS" ]] && [[ "$auth_ok" != "true" ]]; then
  echo "WARN: host has Claude OAuth but n8n container does not — running ensure_n8n_oauth.sh" >&2
  if bash "${ROOT}/scripts/ensure_n8n_oauth.sh" >/dev/null 2>&1 \
    && docker_exec bash -lc 'test -r /data/secrets/claude/.credentials.json'; then
    auth_ok=true
    add_check "virtiofs_inject" true "auto-injected via ensure_n8n_oauth.sh"
  else
    add_check "virtiofs_inject" false "./scripts/ensure_n8n_oauth.sh (host has .credentials.json, container does not)"
  fi
fi

if docker_exec bash -lc 'test -n "${ANTHROPIC_API_KEY:-}" || test -n "${CLAUDE_CODE_OAUTH_TOKEN:-}"'; then
  add_check "api_key_env" true ""
  auth_ok=true
else
  checks+=("api_key_env=optional")
fi

if [[ "$auth_ok" == "true" ]]; then
  add_check "auth_any" true ""
else
  add_check "auth_any" false "sync_claude_oauth.sh → inject_n8n_secrets.sh → docker compose restart n8n"
  failures+=("auth_any: no OAuth file or API key in container")
fi

runtime_ok=false
if docker_exec bash -lc 'command -v jq >/dev/null && jq -e ".engines.copy.provider == \"claude_cli\" and .engines.copy.status == \"active\"" /data/config/platform.runtime.json >/dev/null 2>&1'; then
  runtime_ok=true
  add_check "runtime_copy" true ""
else
  add_check "runtime_copy" false "amctl apply or check data/config/platform.runtime.json"
fi

claude_engine_ok=true
if ((${#failures[@]} > 0)); then
  claude_engine_ok=false
fi

summary="$(IFS=,; echo "${checks[*]}")"
if [[ "$claude_engine_ok" == "true" ]]; then
  printf '{"ok":true,"path":"verify_n8n_claude_engine","claude_engine_ok":true,"checks":"%s"}\n' "$summary"
  exit 0
fi

for f in "${failures[@]}"; do
  echo "FAIL: $f" >&2
done
printf '{"ok":false,"error":"claude engine not ready","claude_engine_ok":false,"checks":"%s","hints":%s}\n' \
  "$summary" \
  "$(printf '%s\n' "${failures[@]}" | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')"

if [[ "$STRICT" == "1" ]]; then
  exit 1
fi
echo "WARN: Claude engine checks failed (VERIFY_CLAUDE_STRICT=0, continuing)" >&2
json_ok "verify_n8n_claude_engine_warn"
