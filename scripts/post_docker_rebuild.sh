#!/usr/bin/env bash
# After docker compose build n8n gateway: refresh config, perms, secrets, verify stack.
# Image already bakes /data/scripts — usually no sync_scripts_to_n8n.sh needed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SKIP_SECRETS=0
SKIP_DASHBOARD=0
for arg in "$@"; do
  case "$arg" in
    --skip-secrets) SKIP_SECRETS=1 ;;
    --skip-dashboard) SKIP_DASHBOARD=1 ;;
    -h|--help)
      echo "Usage: bash scripts/post_docker_rebuild.sh [--skip-secrets] [--skip-dashboard]"
      exit 0
      ;;
    *) echo "Unknown arg: $arg" >&2; exit 2 ;;
  esac
done

log() { echo "post_docker_rebuild: $*"; }
warn() { echo "post_docker_rebuild: WARN — $*" >&2; }

DOCKER=(docker)
if ! docker ps >/dev/null 2>&1; then
  if sudo -n docker ps >/dev/null 2>&1; then
    DOCKER=(sudo docker)
  fi
fi

log "remove legacy dashboard container (8788 compose service)"
bash "$ROOT/scripts/stop_old_dashboard.sh" 2>/dev/null || true

log "ensure n8n + gateway up (--remove-orphans drops stale auto_media-dashboard-1)"
"${DOCKER[@]}" compose -f "$ROOT/docker-compose.yml" up -d --remove-orphans n8n gateway

log "amctl apply"
bash "$ROOT/scripts/amctl.sh" apply

log "fix-data-perms"
bash "$ROOT/scripts/fix-data-perms.sh"

if [[ "$SKIP_SECRETS" == "0" && -f "$ROOT/.env" ]]; then
  log "inject_n8n_secrets + restart n8n"
  bash "$ROOT/scripts/inject_n8n_secrets.sh"
  "${DOCKER[@]}" compose -f "$ROOT/docker-compose.yml" restart n8n
else
  [[ "$SKIP_SECRETS" == "1" ]] && warn "skipped secrets inject (--skip-secrets)"
fi

# shellcheck source=scripts/lib/n8n_api_url.sh
source "$ROOT/scripts/lib/n8n_api_url.sh"
# shellcheck source=scripts/lib/n8n_wait.sh
source "$ROOT/scripts/lib/n8n_wait.sh"
resolved="$(wait_n8n_healthz)" || { warn "n8n unreachable after wait"; exit 1; }
BASE="${resolved%%|*}"
SOURCE="${resolved##*|}"
curl -fsS "${BASE%/}/healthz" >/dev/null
log "n8n healthz OK at $BASE (source=$SOURCE)"

if [[ -f "$ROOT/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT/.env"
  set +a
fi
VERIFY_CLAUDE_STRICT=0 bash "$ROOT/scripts/verify_n8n_claude_engine.sh" >/dev/null 2>&1 \
  && log "verify_n8n_claude_engine: OK" \
  || warn "verify_n8n_claude_engine failed (non-fatal)"

log "verify_mcp_evidence"
bash "$ROOT/scripts/verify_mcp_evidence.sh"

if [[ "$SKIP_DASHBOARD" == "0" ]]; then
  if bash "$ROOT/scripts/check_dashboard.sh" >/dev/null 2>&1; then
    log "check_dashboard: OK"
  else
    warn "dashboard not ready — run: bash scripts/open_user_ui.sh"
  fi
else
  warn "skipped dashboard check (--skip-dashboard)"
fi

cat <<EOF

post_docker_rebuild: done
  Next (optional):
    bash scripts/open_user_ui.sh
    cp .mcp.json.example .mcp.json   # then set N8N_API_KEY from .env for Cursor n8n-mcp
  Script-only changes without rebuild: bash scripts/sync_scripts_to_n8n.sh
EOF
