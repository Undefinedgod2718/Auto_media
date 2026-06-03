#!/usr/bin/env bash
# Stop non-canonical dashboard listeners (8788 legacy docker + 8798/8799 dev smoke).
# Canonical user UI stays on AUTO_MEDIA_DASHBOARD_PORT (default 8790) — not touched here.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LEGACY_PORTS=(8788 8798 8799)

stop_legacy_container() {
  if ! command -v docker >/dev/null 2>&1; then
    return 0
  fi
  docker rm -f auto_media-dashboard-1 2>/dev/null || true
}

stop_port_listener() {
  local port="$1"
  local pids
  pids="$(lsof -ti :"${port}" 2>/dev/null || true)"
  if [[ -z "${pids}" ]]; then
    return 0
  fi
  echo "stopping process on :${port}: ${pids}" >&2
  kill ${pids} 2>/dev/null || true
  sleep 1
  pids="$(lsof -ti :"${port}" 2>/dev/null || true)"
  [[ -z "${pids}" ]] || kill -9 ${pids} 2>/dev/null || true
}

stop_legacy_container
for port in "${LEGACY_PORTS[@]}"; do
  stop_port_listener "${port}"
done

warn=0
for port in "${LEGACY_PORTS[@]}"; do
  if curl -fsS "http://127.0.0.1:${port}/healthz" >/dev/null 2>&1; then
    echo "WARN: :${port} still responds (likely host process outside devcontainer)." >&2
    warn=1
  fi
done

if [[ "${warn}" -eq 1 ]]; then
  echo "  Close apps bound to 127.0.0.1 on ports: ${LEGACY_PORTS[*]}" >&2
  exit 1
fi

echo "stray dashboard ports stopped: ${LEGACY_PORTS[*]} (canonical :8790 unchanged)"
