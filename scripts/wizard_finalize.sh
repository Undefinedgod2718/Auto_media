#!/usr/bin/env bash
# End-of-wizard checks without duplicating amctl apply (see setup_wizard.sh).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

log() { echo "wizard_finalize: $*"; }
warn() { echo "wizard_finalize: WARN — $*" >&2; }

# shellcheck source=scripts/lib/docker_helpers.sh
source "$ROOT/scripts/lib/docker_helpers.sh"
init_docker_compose "$ROOT"

bash "$ROOT/scripts/stop_old_dashboard.sh" 2>/dev/null || true
if [[ "$HAVE_DOCKER_COMPOSE" == "1" ]] && "${DOCKER_COMPOSE[@]}" ps -q n8n 2>/dev/null | grep -q .; then
  log "n8n already up — skip compose (orphans cleaned via stop_old_dashboard)"
elif [[ "$HAVE_DOCKER_COMPOSE" == "1" ]]; then
  log "ensure n8n + gateway (--remove-orphans)"
  "${DOCKER_COMPOSE[@]}" up -d --remove-orphans n8n gateway
else
  warn "docker compose unavailable — skip n8n/gateway up"
fi

# shellcheck source=scripts/lib/n8n_api_url.sh
source "$ROOT/scripts/lib/n8n_api_url.sh"
# shellcheck source=scripts/lib/n8n_wait.sh
source "$ROOT/scripts/lib/n8n_wait.sh"
if resolved="$(wait_n8n_healthz)"; then
  BASE="${resolved%%|*}"
  curl -fsS "${BASE%/}/healthz" >/dev/null
  log "n8n healthz OK at ${BASE}"
else
  warn "n8n unreachable — check docker compose / .env N8N_API_URL / N8N_SYNC_API_URL"
fi

if bash "$ROOT/scripts/check_dashboard.sh" >/dev/null 2>&1; then
  log "check_dashboard: OK"
else
  warn "dashboard :8790 not ready — run: bash scripts/open_user_ui.sh"
fi

log "done"
