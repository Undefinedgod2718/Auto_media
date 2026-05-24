#!/usr/bin/env bash
# Shared helpers (UTF-8). Source from other scripts.
set -eo pipefail

export LANG="${LANG:-C.UTF-8}"
export LC_ALL="${LC_ALL:-C.UTF-8}"

REPO_ROOT="${AUTO_MEDIA_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
if [[ -z "${DATA_ROOT:-}" ]]; then
  if [[ -d "/data/runs" || -d "/data/config" ]]; then
    DATA_ROOT="/data"
  else
    DATA_ROOT="${REPO_ROOT}/data"
  fi
fi
export DATA_ROOT REPO_ROOT
RUNTIME_JSON="${DATA_ROOT}/config/platform.runtime.json"
SCRIPTS_ROOT="${SCRIPTS_ROOT:-/data/scripts}"

log_json() {
  local level="$1"
  shift
  local msg="$*"
  printf '{"level":"%s","ts":"%s","msg":%s}\n' \
    "$level" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$(printf '%s' "$msg" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null || echo "\"$msg\"")"
}

die() {
  log_json error "$*"
  exit 1
}

require_cmd() {
  local c="$1"
  command -v "$c" >/dev/null 2>&1 || die "missing command: $c"
}

json_ok() {
  local path="$1"
  printf '{"ok":true,"path":"%s"}\n' "$path"
}

json_err() {
  local msg="$1"
  printf '{"ok":false,"error":%s}\n' \
    "$(printf '%s' "$msg" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null || echo "\"$msg\"")"
  exit 1
}

ensure_run_dir() {
  local run_id="$1"
  local dir="${DATA_ROOT}/runs/${run_id}"
  mkdir -p "$dir"
  printf '%s' "$dir"
}
