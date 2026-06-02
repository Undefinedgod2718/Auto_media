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

run_state_py() {
  local run_dir="$1"
  local run_id="$2"
  shift 2
  PYTHONPATH="${REPO_ROOT}/scripts/lib" python3 "${REPO_ROOT}/scripts/lib/run_state.py" \
    --run-dir "$run_dir" \
    --run-id "$run_id" \
    "$@"
}

run_state_ensure() {
  local run_dir="$1"
  local run_id="$2"
  run_state_py "$run_dir" "$run_id" ensure >/dev/null
}

run_state_require_stage() {
  local run_dir="$1"
  local run_id="$2"
  local min_seq="$3"
  run_state_py "$run_dir" "$run_id" require --min-seq "$min_seq" >/dev/null
}

run_state_mark_stage() {
  local run_dir="$1"
  local run_id="$2"
  local stage="$3"
  run_state_py "$run_dir" "$run_id" mark --stage "$stage" >/dev/null
}

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

# run_id is a directory name, never a path or template. Reject anything that
# is not [A-Za-z0-9_-]+ so unexpanded n8n templates like "{{ .run_id }}" or
# "={{ .item.json.run_id }}" cannot be mkdir'd into data/runs/.
ensure_run_dir() {
  local run_id="$1"
  if [[ ! "$run_id" =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "ensure_run_dir: invalid run_id (expected [A-Za-z0-9_-]+): '${run_id}'" >&2
    return 1
  fi
  local dir="${DATA_ROOT}/runs/${run_id}"
  if [[ ! -d "$dir" ]]; then
    mkdir -p "$dir" || return 1
  fi
  printf '%s' "$dir"
}
