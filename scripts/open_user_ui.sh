#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${AUTO_MEDIA_DASHBOARD_HOST:-127.0.0.1}"
PORT="${AUTO_MEDIA_DASHBOARD_PORT:-8790}"
LOG="${ROOT}/data/logs/user-ui.log"
URL="http://${HOST}:${PORT}/user"
SETTINGS_URL="http://${HOST}:${PORT}/settings"
NO_RESTART="${DASHBOARD_NO_RESTART:-0}"

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

stop_listener_on_port() {
  local port="$1"
  local pids
  pids="$(lsof -ti :"${port}" 2>/dev/null || true)"
  if [[ -z "${pids}" ]]; then
    return 0
  fi
  echo "restarting dashboard: stopping listener(s) on :${port}: ${pids}" >&2
  kill ${pids} 2>/dev/null || true
  sleep 1
  pids="$(lsof -ti :"${port}" 2>/dev/null || true)"
  [[ -z "${pids}" ]] || kill -9 ${pids} 2>/dev/null || true
}

is_up() {
  curl -fsS "http://${HOST}:${PORT}/healthz" >/dev/null 2>&1
}

verify_instance() {
  local out
  out="$(curl -fsS "http://${HOST}:${PORT}/api/instance" 2>/dev/null)" || return 1
  echo "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
if not d.get("ok"):
    raise SystemExit("instance not ok")
port = int(d.get("port", 0))
if port != int(sys.argv[1]):
    raise SystemExit(f"wrong port {port}")
print(d.get("instance_rev", ""))
' "$PORT"
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

DASHBOARD_PY="$(pick_python)"
ensure_dashboard_deps || exit 1

if [[ "$NO_RESTART" != "1" ]]; then
  stop_listener_on_port "$PORT"
elif ! is_up; then
  : # leave port alone if down and no-restart mode
else
  echo "dashboard already on :${PORT} (DASHBOARD_NO_RESTART=1)" >&2
fi

if [[ "$NO_RESTART" != "1" ]] || ! is_up; then
  export AUTO_MEDIA_DASHBOARD_PORT="${PORT}"
  export AUTO_MEDIA_ROOT="${ROOT}"
  nohup "$DASHBOARD_PY" "${ROOT}/scripts/am_dashboard.py" >>"$LOG" 2>&1 &
  sleep 2
fi

if ! is_up; then
  echo "failed to start dashboard. check log: $LOG" >&2
  exit 1
fi

REV="$(verify_instance)" || {
  echo "dashboard up but /api/instance failed. check log: $LOG" >&2
  exit 1
}

echo "dashboard: http://${HOST}:${PORT} (rev=${REV})"
echo "user ui: $URL"
echo "token settings: $SETTINGS_URL"
echo "skill manager: http://${HOST}:${PORT}/skills"
echo "engines: http://${HOST}:${PORT}/engines"
open_url
