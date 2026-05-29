#!/usr/bin/env bash
# Lookup Wait resume URL written before HITL Wait node paused.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

RUN_ID=""
STAGE="v1"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-id) RUN_ID="$2"; shift 2 ;;
    --stage) STAGE="$2"; shift 2 ;;
    *) json_err "unknown arg: $1" ;;
  esac
done

[[ -n "$RUN_ID" ]] || json_err "usage: read_hitl_resume_map.sh --run-id ID [--stage v1]"

MAP_FILE="${DATA_ROOT}/hitl/resume_map/${RUN_ID}-${STAGE}.json"
[[ -f "$MAP_FILE" ]] || json_err "resume map not found: ${RUN_ID}-${STAGE}"

cat "$MAP_FILE"
