#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

RUN_ID=""
MIN_SEQ=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-id) RUN_ID="$2"; shift 2 ;;
    --min-seq) MIN_SEQ="$2"; shift 2 ;;
    *) json_err "unknown arg: $1" ;;
  esac
done
[[ -n "$RUN_ID" ]] || json_err "usage: verify_run_state.sh --run-id ID [--min-seq N]"

RUN_DIR="$(ensure_run_dir "$RUN_ID")"
run_state_ensure "$RUN_DIR" "$RUN_ID"
if [[ -n "$MIN_SEQ" ]]; then
  run_state_require_stage "$RUN_DIR" "$RUN_ID" "$MIN_SEQ" || json_err "run state below min seq $MIN_SEQ"
fi
run_state_py "$RUN_DIR" "$RUN_ID" status
