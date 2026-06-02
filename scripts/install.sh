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

if command -v docker >/dev/null 2>&1; then
  (cd "$ROOT" && docker compose build n8n gateway)
  (cd "$ROOT" && docker compose up -d n8n gateway)
else
  echo "warn: docker not found; skip compose build/up"
fi

bash "${ROOT}/scripts/amctl.sh" doctor || true
echo "install: done"
