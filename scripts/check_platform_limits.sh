#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a

RUN_ID=""
PHASE="pre_hitl"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-id) RUN_ID="$2"; shift 2 ;;
    --phase) PHASE="$2"; shift 2 ;;
    *) json_err "unknown arg: $1" ;;
  esac
done
[[ -n "$RUN_ID" ]] || json_err "usage: check_platform_limits.sh --run-id ID [--phase pre_hitl|pre_publish]"

RUN_DIR="$(ensure_run_dir "$RUN_ID")"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
run_state_ensure "$RUN_DIR" "$RUN_ID"
if [[ "$PHASE" == "pre_publish" ]]; then
  run_state_require_stage "$RUN_DIR" "$RUN_ID" 5 || json_err "run stage not ready for pre_publish check"
fi

set +e
OUT="$(PYTHONPATH="$ROOT/scripts/lib" python3 -c "
import json, os, sys
from pathlib import Path
sys.path.insert(0, '$ROOT/scripts/lib')
from platform_limits import check_run
run_dir = Path('$RUN_DIR')
phase = '$PHASE'
result = check_run(
    run_dir,
    phase,
    ig_enabled=bool(os.environ.get('IG_USER_ID')),
    threads_enabled=bool(os.environ.get('THREADS_USER_ID')),
    fb_enabled=bool(os.environ.get('META_PAGE_ID')),
)
print(json.dumps(result, ensure_ascii=False))
sys.exit(0 if result['ok'] else 1)
" 2>&1)"
EC=$?
set -e
echo "$OUT"
if [[ "$EC" -ne 0 && -z "$OUT" ]]; then
  json_err "check_platform_limits failed (exit ${EC})"
fi
if [[ "$EC" -ne 0 ]]; then
  VIOLATIONS="$(python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin).get('violations',[]), ensure_ascii=False))" <<<"$OUT")"
  /bin/bash "$ROOT/scripts/notify_platform_limit.sh" --run-id "$RUN_ID" --phase "$PHASE" \
    --violations-json "$VIOLATIONS" 2>/dev/null || true
fi
if [[ "$PHASE" == "pre_hitl" && "$EC" -eq 0 ]]; then
  run_state_mark_stage "$RUN_DIR" "$RUN_ID" "validated_pre_hitl" || true
fi
if [[ "$PHASE" == "pre_publish" && "$EC" -eq 0 ]]; then
  run_state_mark_stage "$RUN_DIR" "$RUN_ID" "pre_publish_ok" || true
fi
exit "$EC"
