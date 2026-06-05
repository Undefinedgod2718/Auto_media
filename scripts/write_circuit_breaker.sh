#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/read-platform.sh"

RUN_ID=""
META_STATUS="0"
META_BODY="unknown"

# Decode base64 args. The HTTP error body ($json.body) is attacker-influenced
# and was previously interpolated into both the shell command AND a python
# heredoc — base64 + argv-passed python closes both injection paths.
b64dec() {
  python3 -c "import base64,sys; sys.stdout.write(base64.b64decode(sys.argv[1]).decode('utf-8','replace'))" "$1" 2>/dev/null || true
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-id) RUN_ID="$2"; shift 2 ;;
    --status) META_STATUS="$2"; shift 2 ;;
    --status-b64) META_STATUS="$(b64dec "$2")"; shift 2 ;;
    --body-b64) META_BODY="$(b64dec "$2")"; shift 2 ;;
    *) json_err "unknown arg: $1" ;;
  esac
done

[[ -n "$RUN_ID" ]] || json_err "usage: write_circuit_breaker.sh --run-id ID [--status N] [--body-b64 B64]"

SIGNAL="$(runtime_signal_file)"
mkdir -p "$(dirname "$SIGNAL")"

RUN_DIR="$(ensure_run_dir "$RUN_ID")"
PNG="${RUN_DIR}/post.png"
CAPTION="${RUN_DIR}/post.md"

python3 - "$SIGNAL" "$RUN_ID" "$PNG" "$CAPTION" "$META_STATUS" "$META_BODY" <<'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

signal, run_id, png, caption, status, body = sys.argv[1:7]
try:
    status_int = int(status or 0)
except ValueError:
    status_int = 0

doc = {
    "triggered_at": datetime.now(timezone.utc).isoformat(),
    "run_id": run_id,
    "png_path": png,
    "caption_path": caption,
    "meta_error": {"status": status_int, "body": body},
    "retry_count": 3,
}
Path(signal).write_text(json.dumps(doc, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY

json_ok "$SIGNAL"
