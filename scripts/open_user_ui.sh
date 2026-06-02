#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${AUTO_MEDIA_DASHBOARD_HOST:-127.0.0.1}"
PORT="${AUTO_MEDIA_DASHBOARD_PORT:-8788}"
URL="http://${HOST}:${PORT}/user"
LOG="${ROOT}/data/logs/user-ui.log"

mkdir -p "$(dirname "$LOG")"

is_up() {
  curl -fsS "http://${HOST}:${PORT}/healthz" >/dev/null 2>&1
}

open_url() {
  if command -v wslview >/dev/null 2>&1; then
    wslview "$URL" >/dev/null 2>&1 || true
    return
  fi
  if command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$URL" >/dev/null 2>&1 || true
    return
  fi
  echo "Open this URL in browser: $URL"
}

if ! is_up; then
  nohup python3 "${ROOT}/scripts/am_dashboard.py" >>"$LOG" 2>&1 &
  sleep 1
fi

if is_up; then
  echo "user ui: $URL"
  open_url
  exit 0
fi

echo "failed to start dashboard. check log: $LOG" >&2
exit 1
