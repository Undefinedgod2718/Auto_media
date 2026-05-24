#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/read-platform.sh"

RUN_ID="${1:-}"
META_STATUS="${2:-0}"
META_BODY="${3:-unknown}"

[[ -n "$RUN_ID" ]] || json_err "usage: write_circuit_breaker.sh RUN_ID [http_status] [error_body]"

SIGNAL="$(runtime_signal_file)"
mkdir -p "$(dirname "$SIGNAL")"

RUN_DIR="${DATA_ROOT}/runs/${RUN_ID}"
PNG="${RUN_DIR}/post.png"
CAPTION="${RUN_DIR}/post.md"

python3 - <<PY
import json
from datetime import datetime, timezone
from pathlib import Path

doc = {
    "triggered_at": datetime.now(timezone.utc).isoformat(),
    "run_id": "${RUN_ID}",
    "png_path": "${PNG}",
    "caption_path": "${CAPTION}",
    "meta_error": {"status": int("${META_STATUS}" or 0), "body": """${META_BODY}"""},
    "retry_count": 3,
}
Path("${SIGNAL}").write_text(json.dumps(doc, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY

json_ok "$SIGNAL"
