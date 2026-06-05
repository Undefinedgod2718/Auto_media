#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

MESSAGE_ID=""
b64dec() {
  python3 -c "import base64,sys; sys.stdout.write(base64.b64decode(sys.argv[1]).decode('utf-8'))" "$1" 2>/dev/null || true
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --message-id) MESSAGE_ID="$2"; shift 2 ;;
    --message-id-b64) MESSAGE_ID="$(b64dec "$2")"; shift 2 ;;
    *) json_err "unknown arg: $1" ;;
  esac
done

[[ -n "$MESSAGE_ID" ]] || json_err "usage: read_hitl_reply_map.sh --message-id ID"
# message_id is a filename component — reject non-digits to block path traversal.
[[ "$MESSAGE_ID" =~ ^[0-9]+$ ]] || json_err "invalid message_id (expected digits): ${MESSAGE_ID}"

MAP_FILE="${DATA_ROOT}/hitl/reply_map/${MESSAGE_ID}.json"
[[ -f "$MAP_FILE" ]] || json_err "no mapping for message_id=${MESSAGE_ID}"

cat "$MAP_FILE"
