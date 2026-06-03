#!/usr/bin/env bash
# Host-mode control for telegram poll forwarder (when not using compose profile).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIDFILE="${ROOT}/data/locks/forwarder.pid"
LOG="${ROOT}/data/logs/forwarder.log"
LOOP="${ROOT}/scripts/telegram_poll_forwarder_loop.sh"

cmd="${1:-status}"
mkdir -p "$(dirname "$PIDFILE")" "$(dirname "$LOG")"

is_running() {
  [[ -f "$PIDFILE" ]] || return 1
  local pid
  pid="$(tr -d '\r\n' < "$PIDFILE")"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

case "$cmd" in
  start)
    if is_running; then
      echo "forwarder already running pid=$(cat "$PIDFILE")"
      exit 0
    fi
    # shellcheck source=scripts/lib/load_env.sh
    source "${ROOT}/scripts/lib/load_env.sh"
    load_repo_env "$ROOT"
    : "${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN missing}"
    nohup bash "$LOOP" >>"$LOG" 2>&1 &
    echo $! >"$PIDFILE"
    echo "forwarder started pid=$(cat "$PIDFILE") log=$LOG"
    ;;
  stop)
    if ! is_running; then
      rm -f "$PIDFILE"
      echo "forwarder not running"
      exit 0
    fi
    pid="$(tr -d '\r\n' < "$PIDFILE")"
    kill "$pid" 2>/dev/null || true
    rm -f "$PIDFILE"
    echo "forwarder stopped"
    ;;
  status)
    if is_running; then
      echo "forwarder running pid=$(cat "$PIDFILE")"
      exit 0
    fi
    echo "forwarder stopped"
    exit 1
    ;;
  *)
    echo "usage: $0 start|stop|status" >&2
    exit 1
    ;;
esac
