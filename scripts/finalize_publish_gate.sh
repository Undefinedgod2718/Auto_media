#!/usr/bin/env bash
# Aggregate publish_*.json; exit 1 if any required platform failed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_LIB="$(dirname "${BASH_SOURCE[0]}")/lib"
# shellcheck source=lib/load_env.sh
source "${SCRIPT_LIB}/load_env.sh"
load_repo_env "$ROOT"
source "${SCRIPT_LIB}/common.sh"

RUN_ID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-id) RUN_ID="$2"; shift 2 ;;
    *) json_err "unknown arg: $1" ;;
  esac
done
[[ -n "$RUN_ID" ]] || json_err "usage: finalize_publish_gate.sh --run-id ID"

RUN_DIR="$(ensure_run_dir "$RUN_ID")"
run_state_ensure "$RUN_DIR" "$RUN_ID"
run_state_require_stage "$RUN_DIR" "$RUN_ID" 7 || json_err "run stage not ready for finalize publish"

check_file() {
  local name="$1"
  local required="$2"
  local path="${RUN_DIR}/${name}"
  if [[ ! -f "$path" ]]; then
    if [[ "$required" == "1" ]]; then
      echo "missing required ${name}" >&2
      return 1
    fi
    return 0
  fi
  python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
if d.get('skipped'):
    sys.exit(0)
if not d.get('ok'):
    print(d.get('error') or 'publish failed', file=sys.stderr)
    sys.exit(1)
" "$path"
}

FAIL=0
TARGETS=()
TASK_FILE="${RUN_DIR}/TASK.md"
USE_TASK_TARGETS=0
[[ -f "$TASK_FILE" ]] && grep -qi '^publish_targets:' "$TASK_FILE" && USE_TASK_TARGETS=1

gate_platform() {
  local platform="$1"
  local env_set="$2"
  local json_name="$3"
  local label="$4"
  if [[ "$USE_TASK_TARGETS" -eq 1 ]]; then
    PYTHONPATH="${ROOT}/scripts/lib" python3 -c "import sys; from pathlib import Path; from parse_task import has_target; sys.exit(0 if has_target(Path(sys.argv[1]), sys.argv[2]) else 1)" \
      "$TASK_FILE" "$platform" || return 0
  else
    [[ "$env_set" == "1" ]] || return 0
  fi
  { check_file "$json_name" 1 || FAIL=1; TARGETS+=("$label"); }
}

gate_platform facebook "$([[ -n "${META_PAGE_ID:-}" ]] && echo 1 || echo 0)" publish_facebook.json facebook
gate_platform threads "$([[ -n "${THREADS_USER_ID:-}" ]] && echo 1 || echo 0)" publish_threads.json threads
gate_platform instagram "$([[ -n "${IG_USER_ID:-}" ]] && echo 1 || echo 0)" publish_ig.json instagram

TARGETS_CSV="$(IFS=,; echo "${TARGETS[*]}")"

if [[ "$FAIL" -ne 0 ]]; then
  /bin/bash "$(dirname "${BASH_SOURCE[0]}")/finalize_review_summary.sh" \
    --run-id "$RUN_ID" --publish-status fail --publish-targets "$TARGETS_CSV"
  /bin/bash "$(dirname "${BASH_SOURCE[0]}")/notify_platform_limit.sh" \
    --run-id "$RUN_ID" --gate-fail 2>/dev/null || true
  json_err "publish gate failed"
fi

/bin/bash "$(dirname "${BASH_SOURCE[0]}")/finalize_review_summary.sh" \
  --run-id "$RUN_ID" --publish-status success --publish-targets "$TARGETS_CSV"

/bin/bash "$(dirname "${BASH_SOURCE[0]}")/record_publish_quota.sh" --run-id "$RUN_ID" >/dev/null
run_state_mark_stage "$RUN_DIR" "$RUN_ID" "publish_done" || true

python3 -c 'import json; print(json.dumps({"ok": True, "gate": "passed"}, ensure_ascii=False))'
