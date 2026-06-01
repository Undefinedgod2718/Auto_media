#!/usr/bin/env bash
# Apply one round of HITL feedback to TASK.md (topic line only; copywriter rerun reads this).
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

TOPIC="$(grep -E '^topic:' "$TASK_FILE" | head -1 | cut -d: -f2- | sed 's/^[[:space:]]*//' || true)"
AUDIENCE="$(grep -E '^audience:' "$TASK_FILE" | head -1 | cut -d: -f2- | sed 's/^[[:space:]]*//' || true)"
ACTION="$(grep -E '^action:' "$TASK_FILE" | head -1 | cut -d: -f2- | sed 's/^[[:space:]]*//' || echo generate_copy)"

# Single revision round: fold feedback into topic for the copywriter prompt.
NEW_TOPIC="${TOPIC:-Untitled}"
if [[ -n "${FEEDBACK// }" ]]; then
  NEW_TOPIC="${NEW_TOPIC} — 修正意見：${FEEDBACK}"
fi

{
  echo "# TASK"
  echo "topic: ${NEW_TOPIC}"
  echo "audience: ${AUDIENCE:-general}"
  echo "action: ${ACTION}"
  echo "hitl_feedback: ${FEEDBACK}"
} >"$TASK_FILE"

json_ok "$TASK_FILE"
