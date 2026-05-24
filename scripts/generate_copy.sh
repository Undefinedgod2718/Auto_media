#!/usr/bin/env bash
set -euo pipefail
RUN_ID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-id) RUN_ID="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "$RUN_ID" ]] || { echo '{"ok":false,"error":"missing --run-id"}' >&2; exit 1; }
exec "$(dirname "${BASH_SOURCE[0]}")/lib/invoke-engine.sh" --run-id "$RUN_ID" --engine copywriter
