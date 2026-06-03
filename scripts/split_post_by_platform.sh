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
[[ -n "$RUN_ID" ]] || json_err "usage: split_post_by_platform.sh --run-id ID"

RUN_DIR="$(ensure_run_dir "$RUN_ID")"
POST_MD="${RUN_DIR}/post.md"
[[ -f "$POST_MD" ]] || json_err "missing post.md"

TARGETS="$(PYTHONPATH="${REPO_ROOT}/scripts/lib" python3 -c "from pathlib import Path; import parse_task as p; print(','.join(sorted(p.publish_targets(Path('$RUN_DIR/TASK.md')))))")"
[[ -n "$TARGETS" ]] || TARGETS="threads"
for p in ${TARGETS//,/ }; do
  dir="${RUN_DIR}/${p}"
  mkdir -p "$dir"
  cp -f "$POST_MD" "${dir}/post.md"
done
python3 -c "import json; print(json.dumps({'ok': True, 'targets': '${TARGETS}'.split(',')}, ensure_ascii=False))"
