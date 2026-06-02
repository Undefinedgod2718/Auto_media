#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

RUN_ID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-id) RUN_ID="$2"; shift 2 ;;
    *) json_err "unknown arg: $1" ;;
  esac
done
[[ -n "$RUN_ID" ]] || json_err "usage: hermes_content_review.sh --run-id ID"

RUN_DIR="$(ensure_run_dir "$RUN_ID")"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Root-owned hermes_plan.json (e.g. manual docker exec) blocks n8n user overwrite.
PLAN_FILE="$RUN_DIR/hermes_plan.json"
if [[ -f "$PLAN_FILE" && ! -w "$PLAN_FILE" ]]; then
  rm -f "$PLAN_FILE" 2>/dev/null || true
fi

set +e
OUT="$(PYTHONPATH="$ROOT/scripts/lib" python3 "$ROOT/scripts/lib/hermes_content_review.py" "$RUN_DIR" 2>&1)"
EC=$?
set -e
echo "$OUT"
exit "$EC"
