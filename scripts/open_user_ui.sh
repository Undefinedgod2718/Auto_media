#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${AUTO_MEDIA_DASHBOARD_HOST:-127.0.0.1}"
PORT="${AUTO_MEDIA_DASHBOARD_PORT:-8790}"
LOG="${ROOT}/data/logs/user-ui.log"
URL="http://${HOST}:${PORT}/user"
SETTINGS_URL="http://${HOST}:${PORT}/settings"

mkdir -p "$(dirname "$LOG")"
bash "${ROOT}/scripts/stop_old_dashboard.sh" 2>/dev/null || true

pick_python() {
  if [[ -x "${ROOT}/.venv/bin/python3" ]]; then
    echo "${ROOT}/.venv/bin/python3"
    return
  fi
  echo "python3"
}

ensure_dashboard_deps() {
  local py
  py="$(pick_python)"
  if "$py" -c "import yaml" 2>/dev/null; then
    return 0
  fi
  echo "installing PyYAML for dashboard..." >&2
  if command -v uv >/dev/null 2>&1; then
    uv pip install pyyaml >/dev/null 2>&1 || true
  fi
  if ! "$py" -c "import yaml" 2>/dev/null; then
    python3 -m pip install --user pyyaml >/dev/null 2>&1 || true
  fi
  "$py" -c "import yaml" 2>/dev/null || {
    echo "PyYAML missing. Run: uv pip install pyyaml" >&2
    return 1
  }
}

DASHBOARD_PY="$(pick_python)"
ensure_dashboard_deps || exit 1

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
  export AUTO_MEDIA_DASHBOARD_PORT="${PORT}"
  nohup "$DASHBOARD_PY" "${ROOT}/scripts/am_dashboard.py" >>"$LOG" 2>&1 &
  sleep 1
fi

if is_up; then
  echo "user ui: $URL"
  echo "token settings: $SETTINGS_URL"
  echo "skill manager: http://${HOST}:${PORT}/skills (read-only until PIN unlock)"
  open_url
  exit 0
fi

echo "failed to start dashboard. check log: $LOG" >&2
exit 1
