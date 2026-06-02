#!/usr/bin/env bash
# Sync TASK.md carousel_total from post.md planning (2–10).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

RUN_ID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-id) RUN_ID="$2"; shift 2 ;;
    *) json_err "unknown arg: $1" ;;
  esac
done
[[ -n "$RUN_ID" ]] || json_err "usage: sync_carousel_total.sh --run-id ID"

RUN_DIR="$(ensure_run_dir "$RUN_ID")"
TASK_FILE="${RUN_DIR}/TASK.md"
POST_MD="${RUN_DIR}/post.md"
[[ -f "$TASK_FILE" ]] || json_err "missing TASK.md"

DEFAULT="$(grep -E '^carousel_total:' "$TASK_FILE" | head -1 | cut -d: -f2- | tr -d ' ' || true)"
[[ -n "$DEFAULT" ]] || DEFAULT="0"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -f "$POST_MD" ]]; then
  TOTAL="$(python3 "$ROOT/scripts/lib/parse_carousel_total.py" "$POST_MD" --task-md "$TASK_FILE" --default "$DEFAULT")"
else
  TOTAL="$DEFAULT"
fi

GEN_FLAG="false"
if [[ "$TOTAL" -gt 0 ]]; then
  GEN_FLAG="true"
fi

python3 - "$TASK_FILE" "$TOTAL" "$GEN_FLAG" <<'PY'
import re
import sys
from pathlib import Path

task, total, gen_flag = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
lines = task.read_text(encoding="utf-8").splitlines()
out, found_total, found_gen = [], False, False
for line in lines:
    if re.match(r"^carousel_total:\s*", line):
        out.append(f"carousel_total: {total}")
        found_total = True
    elif re.match(r"^generate_carousel:\s*", line):
        out.append(f"generate_carousel: {gen_flag}")
        found_gen = True
    else:
        out.append(line)
if not found_total:
    out.append(f"carousel_total: {total}")
if not found_gen:
    out.append(f"generate_carousel: {gen_flag}")
task.write_text("\n".join(out).rstrip() + "\n", encoding="utf-8")
print(f'{{"ok":true,"carousel_total":{total},"generate_carousel":{gen_flag}}}')
PY
