#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

RUN_ID=""
DECISION=""
FEEDBACK_FILE=""
REVIEW_ROUND="1"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-id) RUN_ID="$2"; shift 2 ;;
    --decision) DECISION="$2"; shift 2 ;;
    --feedback-file) FEEDBACK_FILE="$2"; shift 2 ;;
    --review-round) REVIEW_ROUND="$2"; shift 2 ;;
    *) json_err "unknown arg: $1" ;;
  esac
done

[[ -n "$RUN_ID" && -n "$DECISION" ]] || json_err "usage: hermes_revision_plan.sh --run-id ID --decision revise|reject [--feedback-file PATH] [--review-round N]"
RUN_DIR="$(ensure_run_dir "$RUN_ID")"
ASSESS_FILE="${RUN_DIR}/hermes_assessment.json"
PLAN_FILE="${RUN_DIR}/hermes_revision_plan.json"
[[ -f "$ASSESS_FILE" ]] || json_err "missing hermes_assessment.json"

python3 - "$RUN_ID" "$DECISION" "$FEEDBACK_FILE" "$ASSESS_FILE" "$PLAN_FILE" "$REVIEW_ROUND" <<'PYCODE'
import json
import sys
from pathlib import Path

run_id, decision, feedback_file, assess_file, plan_file, review_round = sys.argv[1:]
assessment = json.loads(Path(assess_file).read_text(encoding="utf-8"))
feedback = ""
if feedback_file and Path(feedback_file).exists():
    feedback = Path(feedback_file).read_text(encoding="utf-8", errors="ignore").strip()

suggestions = []
if feedback:
    suggestions.append(f"優先採納人類建議: {feedback}")
else:
    suggestions.extend(assessment.get("suggestions") or ["依品牌語氣優化文案並補強 CTA"])

text = feedback.lower()
if any(k in text for k in ["圖", "svg", "視覺", "重畫"]):
    rerun = "full"
elif any(k in text for k in ["排版", "圖片"]):
    rerun = "copy_render"
else:
    rerun = "copy_only"
if decision == "reject" and rerun == "copy_only":
    rerun = "copy_render"

plan = {
    "run_id": run_id,
    "review_round": int(review_round),
    "decision": decision,
    "human_feedback": feedback,
    "rerun_scope": rerun,
    "revision_plan": suggestions,
}
Path(plan_file).write_text(json.dumps(plan, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(json.dumps(plan, ensure_ascii=False))
PYCODE
