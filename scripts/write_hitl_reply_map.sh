#!/usr/bin/env bash
# Map Telegram Force-Reply prompt message_id -> run_id for feedback routing.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

MESSAGE_ID=""
RUN_ID=""
STAGE="v1"
DECISION="revise"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --message-id) MESSAGE_ID="$2"; shift 2 ;;
    --run-id) RUN_ID="$2"; shift 2 ;;
    --stage) STAGE="$2"; shift 2 ;;
    --decision) DECISION="$2"; shift 2 ;;
    *) json_err "unknown arg: $1" ;;
  esac
done

[[ -n "$MESSAGE_ID" && -n "$RUN_ID" ]] || json_err "usage: write_hitl_reply_map.sh --message-id ID --run-id RUN_ID [--stage v1]"

MAP_DIR="${DATA_ROOT}/hitl/reply_map"
mkdir -p "$MAP_DIR"
MAP_FILE="${MAP_DIR}/${MESSAGE_ID}.json"

python3 - "$MAP_FILE" "$RUN_ID" "$STAGE" "$DECISION" <<'PY'
import json
import sys
from datetime import datetime, timezone

path, run_id, stage, decision = sys.argv[1:5]
payload = {
    "run_id": run_id,
    "stage": stage,
    "created_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "decision": decision,
}
with open(path, "w", encoding="utf-8") as f:
    json.dump(payload, f)
    f.write("\n")
PY

json_ok "$MAP_FILE"
