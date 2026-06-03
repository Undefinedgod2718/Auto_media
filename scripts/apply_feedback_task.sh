#!/usr/bin/env bash
# Apply one round of HITL feedback to TASK.md; preserve publish/carousel fields and infer IG from feedback.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

RUN_ID=""
FEEDBACK=""
FEEDBACK_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-id) RUN_ID="$2"; shift 2 ;;
    --feedback) FEEDBACK="$2"; shift 2 ;;
    --feedback-file) FEEDBACK_FILE="$2"; shift 2 ;;
    *) json_err "unknown arg: $1" ;;
  esac
done

[[ -n "$RUN_ID" ]] || json_err "usage: apply_feedback_task.sh --run-id ID (--feedback TEXT | --feedback-file PATH)"

if [[ -n "$FEEDBACK_FILE" ]]; then
  [[ -f "$FEEDBACK_FILE" ]] || json_err "feedback file not found: $FEEDBACK_FILE"
  FEEDBACK="$(cat "$FEEDBACK_FILE")"
fi

[[ -n "${FEEDBACK// }" ]] || json_err "empty feedback"

RUN_DIR="$(ensure_run_dir "$RUN_ID")"
TASK_FILE="${RUN_DIR}/TASK.md"
[[ -f "$TASK_FILE" ]] || json_err "missing TASK.md at $TASK_FILE"

python3 - "$TASK_FILE" "$FEEDBACK" <<'PYCODE'
import re
import sys
from pathlib import Path

task_file = Path(sys.argv[1])
feedback = sys.argv[2]
text = task_file.read_text(encoding="utf-8")


def field(key: str, default: str = "") -> str:
    prefix = f"{key}:"
    for line in text.splitlines():
        if line.strip().lower().startswith(prefix.lower()):
            return line.split(":", 1)[1].strip()
    return default


topic = field("topic", "Untitled")
audience = field("audience", "general")
action = field("action", "generate_copy")
publish_targets = field("publish_targets")
carousel_total = field("carousel_total")
generate_carousel = field("generate_carousel")
publish_mode_threads = field("publish_mode_threads", "carousel")
page_type = field("page_type")

new_topic = topic
if feedback.strip():
    new_topic = f"{topic} — 修正意見：{feedback}"

fb = feedback.lower()
targets = {p.strip().lower() for p in publish_targets.split(",") if p.strip()}
ig_keywords = ("ig", "instagram", "insta", "上傳", "上传")
carousel_keywords = ("ig", "instagram", "insta", "上傳", "上传", "輪播", "轮播", "圖", "图", "圖片", "图片")
if any(k in fb for k in ig_keywords):
    targets.add("instagram")
if any(k in fb for k in carousel_keywords):
    generate_carousel = "true"
    if not carousel_total:
        carousel_total = "0"

targets_sorted = ",".join(sorted(targets)) if targets else publish_targets

lines = ["# TASK", f"topic: {new_topic}", f"audience: {audience}", f"action: {action}"]
if carousel_total:
    lines.append(f"carousel_total: {carousel_total}")
if page_type:
    lines.append(f"page_type: {page_type}")
if targets_sorted:
    lines.append(f"publish_targets: {targets_sorted}")
if publish_mode_threads:
    lines.append(f"publish_mode_threads: {publish_mode_threads}")
if generate_carousel:
    lines.append(f"generate_carousel: {generate_carousel}")
lines.append(f"hitl_feedback: {feedback}")

task_file.write_text("\n".join(lines) + "\n", encoding="utf-8")
print(str(task_file))
PYCODE

json_ok "$TASK_FILE"
