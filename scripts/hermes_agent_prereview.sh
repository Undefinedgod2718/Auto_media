#!/usr/bin/env bash
# Agent prereview (optional): falls back to rule script on failure.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

RUN_ID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-id) RUN_ID="$2"; shift 2 ;;
    *) json_err "unknown arg: $1" ;;
  esac
done
[[ -n "$RUN_ID" ]] || json_err "usage: hermes_agent_prereview.sh --run-id ID"

# v1: delegate to rule-based prereview (Agent skill can replace this later).
exec "$(dirname "${BASH_SOURCE[0]}")/hermes_prereview.sh" --run-id "$RUN_ID"
