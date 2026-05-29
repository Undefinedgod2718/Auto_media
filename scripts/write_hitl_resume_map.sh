#!/usr/bin/env bash
# Persist n8n Wait resume URL for a run (forwarder reads this on Telegram callback).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

RUN_ID=""
STAGE="v1"
RESUME_URL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-id) RUN_ID="$2"; shift 2 ;;
    --stage) STAGE="$2"; shift 2 ;;
    --resume-url) RESUME_URL="$2"; shift 2 ;;
    *) json_err "unknown arg: $1" ;;
  esac
done

[[ -n "$RUN_ID" && -n "$RESUME_URL" ]] || json_err "usage: write_hitl_resume_map.sh --run-id ID --resume-url URL [--stage v1]"

MAP_DIR="${DATA_ROOT}/hitl/resume_map"
mkdir -p "$MAP_DIR"
MAP_FILE="${MAP_DIR}/${RUN_ID}-${STAGE}.json"

python3 - "$MAP_FILE" "$RUN_ID" "$STAGE" "$RESUME_URL" <<'PY'
import json
import sys
from datetime import datetime, timezone

path, run_id, stage, resume_url = sys.argv[1:5]
payload = {
    "run_id": run_id,
    "stage": stage,
    "resume_url": resume_url,
    "created_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}
with open(path, "w", encoding="utf-8") as f:
    json.dump(payload, f)
    f.write("\n")
PY

json_ok "$MAP_FILE"
