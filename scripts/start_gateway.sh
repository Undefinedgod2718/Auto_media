#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a

GATEWAY_PORT="${GATEWAY_PORT:-8787}"
MODE="${GATEWAY_RUN_MODE:-compose}"

port_listening() {
  command -v ss >/dev/null 2>&1 && ss -tln "sport = :${GATEWAY_PORT}" 2>/dev/null | grep -q LISTEN
}

if port_listening; then
  echo "Gateway already listening on :${GATEWAY_PORT} (skip start)"
  exit 0
fi

if [[ "$MODE" == "host" ]]; then
  export AUTO_MEDIA_ROOT="$ROOT"
  export DATA_ROOT="${DATA_ROOT:-$ROOT/data}"
  export N8N_API_URL="${GATEWAY_N8N_API_URL:-${N8N_API_URL:-http://localhost:5678}}"
  echo "GATEWAY_RUN_MODE=host — Gateway on host; ensure data/runs matches n8n container (see docs/HERMES_SETUP.md)"
  exec python3 "$ROOT/scripts/hermes_telegram_gateway.py"
fi

cd "$ROOT"
if command -v docker >/dev/null 2>&1; then
  if docker compose version >/dev/null 2>&1; then
    DC=(docker compose)
  else
    DC=(docker-compose)
  fi
  if [[ ! -S /var/run/docker.sock ]] && [[ -S /var/run/docker-host.sock ]]; then
    sudo "${DC[@]}" up -d gateway
  else
    "${DC[@]}" up -d gateway 2>/dev/null || sudo "${DC[@]}" up -d gateway
  fi
  echo "Gateway service started (compose). Poll: GATEWAY_URL=http://localhost:${GATEWAY_PORT}"
  exit 0
fi

echo "docker not found; falling back to host gateway" >&2
export AUTO_MEDIA_ROOT="$ROOT"
export DATA_ROOT="${DATA_ROOT:-$ROOT/data}"
export N8N_API_URL="${GATEWAY_N8N_API_URL:-${N8N_API_URL:-http://localhost:5678}}"
exec python3 "$ROOT/scripts/hermes_telegram_gateway.py"
