#!/usr/bin/env bash
# Exit 0 if carousel generation should run (IG selected); exit 1 to skip.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

RUN_ID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-id) RUN_ID="$2"; shift 2 ;;
    --json) JSON_OUT=1; shift ;;
    *) json_err "unknown arg: $1" ;;
  esac
done
[[ -n "$RUN_ID" ]] || json_err "usage: should_generate_carousel.sh --run-id ID [--json]"

RUN_DIR="$(ensure_run_dir "$RUN_ID")"
TASK_FILE="${RUN_DIR}/TASK.md"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

set +e
OUT="$(PYTHONPATH="$ROOT/scripts/lib" python3 -c "
import json, sys
from pathlib import Path
from carousel_policy import publish_targets, should_generate_carousel

task = Path(sys.argv[1])
ok = should_generate_carousel(task)
targets = sorted(publish_targets(task))
print(json.dumps({'ok': True, 'should_generate': ok, 'publish_targets': targets}, ensure_ascii=False))
sys.exit(0 if ok else 1)
" "$TASK_FILE" 2>&1)"
EC=$?
set -e
echo "$OUT"
exit "$EC"
