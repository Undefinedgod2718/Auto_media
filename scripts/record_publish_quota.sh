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
[[ -n "$RUN_ID" ]] || json_err "usage: record_publish_quota.sh --run-id ID"

RUN_DIR="$(ensure_run_dir "$RUN_ID")"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PYTHONPATH="$ROOT/scripts/lib" python3 -c "
import json, sys
from pathlib import Path
sys.path.insert(0, '$ROOT/scripts/lib')
from publish_quota import record_from_run
result = record_from_run(Path('$RUN_DIR'))
print(json.dumps(result, ensure_ascii=False))
"
