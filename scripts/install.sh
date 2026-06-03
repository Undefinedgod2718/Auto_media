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
# shellcheck source=scripts/lib/image_policy.sh
source "${ROOT}/scripts/lib/image_policy.sh"
# shellcheck source=scripts/lib/release_guard.sh
source "${ROOT}/scripts/lib/release_guard.sh"

auto_media_load_env_file "$ROOT"
auto_media_apply_image_env
export DATA_ROOT="${DATA_ROOT:-$ROOT/data}"
release_guard_report "$ROOT" "${DATA_ROOT}/state/install.json" || true

init_docker_compose "$ROOT"
if [[ "$HAVE_DOCKER_COMPOSE" == "1" ]]; then
  bash "${ROOT}/scripts/stop_old_dashboard.sh" 2>/dev/null || true
  auto_media_compose_prepare_images "$ROOT" "${DOCKER_COMPOSE[@]}"
  (cd "$ROOT" && "${DOCKER_COMPOSE[@]}" up -d --remove-orphans n8n gateway)
  bash "${ROOT}/scripts/post_docker_rebuild.sh" --skip-secrets
else
  echo "warn: docker compose unavailable; skip compose pull/build/up"
fi

bash "${ROOT}/scripts/amctl.sh" doctor || true
echo "install: done (non-interactive). For guided setup: bash scripts/setup_wizard.sh"
