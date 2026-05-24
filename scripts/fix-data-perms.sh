#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="${AUTO_MEDIA_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
DATA="${REPO_ROOT}/data"

mkdir -p "${DATA}/runs" "${DATA}/logs" "${DATA}/config" \
  "${DATA}/browser_profiles/meta" \
  "${DATA}/secrets/claude" "${DATA}/secrets/codex"

if [[ "$(uname -s)" == "Linux" ]]; then
  if id -u node >/dev/null 2>&1; then
    chown -R node:node "$DATA" 2>/dev/null || chown -R 1000:1000 "$DATA" 2>/dev/null || true
  else
    chown -R 1000:1000 "$DATA" 2>/dev/null || true
  fi
  chmod -R u+rwX,g+rwX "$DATA/runs" "$DATA/logs" 2>/dev/null || true
fi

if [[ "${AUTO_MEDIA_DEV_PERMS:-0}" == "1" ]]; then
  chmod -R a+rwX "$DATA" 2>/dev/null || true
fi

echo "data permissions updated under ${DATA}"
