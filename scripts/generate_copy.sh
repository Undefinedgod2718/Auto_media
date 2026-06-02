#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
RUN_ID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-id) RUN_ID="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "$RUN_ID" ]] || { echo '{"ok":false,"error":"missing --run-id"}' >&2; exit 1; }
RUN_DIR="$(ensure_run_dir "$RUN_ID")"
run_state_ensure "$RUN_DIR" "$RUN_ID"
/bin/bash "$(dirname "${BASH_SOURCE[0]}")/lib/invoke-engine.sh" --run-id "$RUN_ID" --engine copywriter
/bin/bash "$(dirname "${BASH_SOURCE[0]}")/split_post_by_platform.sh" --run-id "$RUN_ID" >/dev/null || true
run_state_mark_stage "$RUN_DIR" "$RUN_ID" "writers_done" || true
