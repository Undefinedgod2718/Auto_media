#!/usr/bin/env bash
# Aggregate publish_*.json; exit 1 if any required platform failed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

RUN_ID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-id) RUN_ID="$2"; shift 2 ;;
    *) json_err "unknown arg: $1" ;;
  esac
done
[[ -n "$RUN_ID" ]] || json_err "usage: finalize_publish_gate.sh --run-id ID"

RUN_DIR="$(ensure_run_dir "$RUN_ID")"
run_state_ensure "$RUN_DIR" "$RUN_ID"
run_state_require_stage "$RUN_DIR" "$RUN_ID" 7 || json_err "run stage not ready for finalize publish"

check_file() {
  local name="$1"
  local required="$2"
  local path="${RUN_DIR}/${name}"
  if [[ ! -f "$path" ]]; then
    if [[ "$required" == "1" ]]; then
      echo "missing required ${name}" >&2
      return 1
    fi
    return 0
  fi
  python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
if d.get('skipped'):
    sys.exit(0)
if not d.get('ok'):
    print(d.get('error') or 'publish failed', file=sys.stderr)
    sys.exit(1)
" "$path"
}

FAIL=0
TARGETS=()

[[ -n "${META_PAGE_ID:-}" ]] && { check_file publish_facebook.json 1 || FAIL=1; TARGETS+=(facebook); }
[[ -n "${THREADS_USER_ID:-}" ]] && { check_file publish_threads.json 1 || FAIL=1; TARGETS+=(threads); }
[[ -n "${IG_USER_ID:-}" ]] && { check_file publish_ig.json 1 || FAIL=1; TARGETS+=(instagram); }

TARGETS_CSV="$(IFS=,; echo "${TARGETS[*]}")"

if [[ "$FAIL" -ne 0 ]]; then
  /bin/bash "$(dirname "${BASH_SOURCE[0]}")/finalize_review_summary.sh" \
    --run-id "$RUN_ID" --publish-status fail --publish-targets "$TARGETS_CSV"
  /bin/bash "$(dirname "${BASH_SOURCE[0]}")/notify_platform_limit.sh" \
    --run-id "$RUN_ID" --gate-fail 2>/dev/null || true
  json_err "publish gate failed"
fi

/bin/bash "$(dirname "${BASH_SOURCE[0]}")/finalize_review_summary.sh" \
  --run-id "$RUN_ID" --publish-status success --publish-targets "$TARGETS_CSV"

/bin/bash "$(dirname "${BASH_SOURCE[0]}")/record_publish_quota.sh" --run-id "$RUN_ID" >/dev/null
run_state_mark_stage "$RUN_DIR" "$RUN_ID" "publish_done" || true

python3 -c 'import json; print(json.dumps({"ok": True, "gate": "passed"}, ensure_ascii=False))'
