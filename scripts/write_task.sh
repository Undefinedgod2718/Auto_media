#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

RUN_ID=""
TOPIC=""
AUDIENCE="general"
ACTION="generate_copy"
CAROUSEL_TOTAL=""
PAGE_TYPE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-id) RUN_ID="$2"; shift 2 ;;
    --topic) TOPIC="$2"; shift 2 ;;
    --audience) AUDIENCE="$2"; shift 2 ;;
    --action) ACTION="$2"; shift 2 ;;
    --carousel-total) CAROUSEL_TOTAL="$2"; shift 2 ;;
    --page-type) PAGE_TYPE="$2"; shift 2 ;;
    *) json_err "unknown arg: $1" ;;
  esac
done

[[ -n "$RUN_ID" && -n "$TOPIC" ]] || json_err "usage: write_task.sh --run-id ID --topic TEXT [--audience A] [--action A]"

RUN_DIR="$(ensure_run_dir "$RUN_ID")"
TASK_FILE="${RUN_DIR}/TASK.md"

{
  echo "# TASK"
  echo "topic: ${TOPIC}"
  echo "audience: ${AUDIENCE}"
  echo "action: ${ACTION}"
  [[ -n "$CAROUSEL_TOTAL" ]] && echo "carousel_total: ${CAROUSEL_TOTAL}"
  [[ -n "$PAGE_TYPE" ]] && echo "page_type: ${PAGE_TYPE}"
} >"$TASK_FILE"

json_ok "$TASK_FILE"
