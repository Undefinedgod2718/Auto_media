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
[[ -n "$RUN_ID" ]] || json_err "usage: verify_run_artifacts.sh --run-id ID"

RUN_DIR="$(ensure_run_dir "$RUN_ID")"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

FAIL=0
POST="${RUN_DIR}/post.md"
if [[ -f "$POST" ]]; then
  VAL="$(python3 "$ROOT/scripts/lib/validate_post_md.py" "$POST")"
  echo "post.md: $VAL"
  python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin)["ok"] else 1)' <<<"$VAL" || FAIL=1
else
  echo "post.md: missing" >&2
  FAIL=1
fi

SLIDES="$(find "${RUN_DIR}/carousel" -maxdepth 1 \( -name '*.png' -o -name '*.jpg' \) 2>/dev/null | wc -l | tr -d ' ')"
echo "carousel slides: ${SLIDES}"
[[ "$SLIDES" -ge 2 ]] || { echo "need >=2 slides" >&2; FAIL=1; }

for f in publish_threads.json publish_ig.json publish_facebook.json; do
  if [[ -f "${RUN_DIR}/${f}" ]]; then
    echo "${f}: $(cat "${RUN_DIR}/${f}")"
  fi
done

exit "$FAIL"
