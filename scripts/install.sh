#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ ! -f "${ROOT}/.env" && -f "${ROOT}/.env.example" ]]; then
  cp "${ROOT}/.env.example" "${ROOT}/.env"
  echo "created .env from .env.example"
fi

if command -v uv >/dev/null 2>&1; then
  (cd "$ROOT" && uv sync)
else
  echo "warn: uv not found, skip dependency sync"
fi

bash "${ROOT}/scripts/amctl.sh" apply
bash "${ROOT}/scripts/fix-data-perms.sh"

# shellcheck source=scripts/lib/docker_helpers.sh
source "${ROOT}/scripts/lib/docker_helpers.sh"
init_docker_compose "$ROOT"
if [[ "$HAVE_DOCKER_COMPOSE" == "1" ]]; then
  bash "${ROOT}/scripts/stop_old_dashboard.sh" 2>/dev/null || true
  (cd "$ROOT" && "${DOCKER_COMPOSE[@]}" build n8n gateway)
  (cd "$ROOT" && "${DOCKER_COMPOSE[@]}" up -d --remove-orphans n8n gateway)
  bash "${ROOT}/scripts/post_docker_rebuild.sh" --skip-secrets
else
  echo "warn: docker compose unavailable; skip compose build/up"
fi

bash "${ROOT}/scripts/amctl.sh" doctor || true
echo "install: done (non-interactive). For guided setup: bash scripts/setup_wizard.sh"
