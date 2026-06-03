#!/usr/bin/env bash
# Phase 2: Threads CAROUSEL API (up to 20 media). Not wired in happy-path yet.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

RUN_ID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-id) RUN_ID="$2"; shift 2 ;;
    *) json_err "unknown arg: $1" ;;
  esac
done
[[ -n "$RUN_ID" ]] || json_err "usage: publish_threads_carousel.sh --run-id ID"

RUN_DIR="$(ensure_run_dir "$RUN_ID")"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! /bin/bash "$ROOT/scripts/lib/publish_target_gate.sh" "$RUN_DIR" threads; then
  python3 -c "import json; print(json.dumps({'ok':True,'skipped':True,'reason':'not in publish_targets'},ensure_ascii=False))"
  exit 0
fi

json_err "publish_threads_carousel: Phase 2 not implemented (use publish_threads_chain.sh for TEXT+IMAGE chain)"
