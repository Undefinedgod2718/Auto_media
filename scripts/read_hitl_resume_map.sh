#!/usr/bin/env bash
# Lookup Wait resume URL written before HITL Wait node paused.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

RUN_ID=""
STAGE="v1"
b64dec() {
  python3 -c "import base64,sys; sys.stdout.write(base64.b64decode(sys.argv[1]).decode('utf-8'))" "$1" 2>/dev/null || true
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-id) RUN_ID="$2"; shift 2 ;;
    --run-id-b64) RUN_ID="$(b64dec "$2")"; shift 2 ;;
    --stage) STAGE="$2"; shift 2 ;;
    --stage-b64) STAGE="$(b64dec "$2")"; shift 2 ;;
    *) json_err "unknown arg: $1" ;;
  esac
done

[[ -n "$RUN_ID" ]] || json_err "usage: read_hitl_resume_map.sh --run-id ID [--stage v1]"
# RUN_ID and STAGE are filename components — validate to block path traversal.
[[ "$RUN_ID" =~ ^[A-Za-z0-9_-]+$ ]] || json_err "invalid run_id (expected [A-Za-z0-9_-]+): ${RUN_ID}"
[[ "$STAGE" =~ ^(v1|v2|feedback-v1)$ ]] || json_err "invalid stage: ${STAGE}"

MAP_FILE="${DATA_ROOT}/hitl/resume_map/${RUN_ID}-${STAGE}.json"
[[ -f "$MAP_FILE" ]] || json_err "resume map not found: ${RUN_ID}-${STAGE}"

cat "$MAP_FILE"
