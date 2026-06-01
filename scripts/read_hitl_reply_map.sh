#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

MESSAGE_ID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --message-id) MESSAGE_ID="$2"; shift 2 ;;
    *) json_err "unknown arg: $1" ;;
  esac
done

[[ -n "$MESSAGE_ID" ]] || json_err "usage: read_hitl_reply_map.sh --message-id ID"

MAP_FILE="${DATA_ROOT}/hitl/reply_map/${MESSAGE_ID}.json"
[[ -f "$MAP_FILE" ]] || json_err "no mapping for message_id=${MESSAGE_ID}"

cat "$MAP_FILE"
