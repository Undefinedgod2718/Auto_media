#!/usr/bin/env bash
# Publish Threads: chunk post.md, first post IMAGE+text, replies TEXT with reply_to_id.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

RUN_ID=""
IMAGE_URL=""
MAX_CHARS="${THREADS_CHUNK_MAX_CHARS:-500}"
CHUNK_MODE="${THREADS_CHUNK_MODE:-by_post}"
MAX_WAIT="${THREADS_CONTAINER_MAX_WAIT_SEC:-120}"
POLL_SEC="${THREADS_CONTAINER_POLL_SEC:-3}"

usage() {
  echo "Usage: publish_threads_chain.sh --run-id ID [--image-url URL] [--max-chars N]" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-id) RUN_ID="$2"; shift 2 ;;
    --image-url) IMAGE_URL="$2"; shift 2 ;;
    --max-chars) MAX_CHARS="$2"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -n "$RUN_ID" ]] || usage

RUN_DIR="$(ensure_run_dir "$RUN_ID")"
run_state_ensure "$RUN_DIR" "$RUN_ID"
run_state_require_stage "$RUN_DIR" "$RUN_ID" 7 || json_err "run stage not ready for publish (need pre_publish_ok)"

write_skipped() {
  local reason="${1:-not in publish_targets}"
  python3 - "$RUN_DIR" "$reason" <<'PY'
import json, sys
from pathlib import Path
run_dir, reason = Path(sys.argv[1]), sys.argv[2]
payload = {"ok": True, "skipped": True, "reason": reason, "post_ids": [], "chunk_count": 0}
Path(run_dir, "publish_threads.json").write_text(
    json.dumps(payload, ensure_ascii=False) + "\n", encoding="utf-8"
)
print(json.dumps(payload, ensure_ascii=False))
PY
}

if [[ -f "${RUN_DIR}/publish_threads.json" ]]; then
  if python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get('ok') and not d.get('skipped') else 1)" "${RUN_DIR}/publish_threads.json" 2>/dev/null; then
    write_skipped "already_published"
    exit 0
  fi
fi

set +e
/bin/bash "$(dirname "${BASH_SOURCE[0]}")/lib/publish_target_gate.sh" "$RUN_DIR" threads
GATE_EC=$?
set -e
if [[ "$GATE_EC" -eq 1 ]]; then
  write_skipped "not in publish_targets"
  exit 0
elif [[ "$GATE_EC" -ne 0 ]]; then
  json_err "publish target gate failed (ec=${GATE_EC})"
fi

if [[ -z "$IMAGE_URL" && -f "${RUN_DIR}/catbox_urls.json" ]]; then
  IMAGE_URL="$(python3 -c "import json; print(json.load(open('${RUN_DIR}/catbox_urls.json')).get('first_url',''))")"
fi
IMAGE_URL="$(echo "$IMAGE_URL" | tr -d '\r\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
HAS_IMAGE=0
[[ -n "$IMAGE_URL" ]] && HAS_IMAGE=1
[[ -n "${THREADS_USER_ID:-}" && -n "${THREADS_ACCESS_TOKEN:-}" ]] || json_err "THREADS_USER_ID or THREADS_ACCESS_TOKEN unset"
POST_MD="$(PYTHONPATH="$ROOT/scripts/lib" python3 -c "from pathlib import Path; from media_paths import run_post_md; print(run_post_md(Path('$RUN_DIR'),'threads'))")"
[[ -f "$POST_MD" ]] || json_err "missing post.md at $POST_MD"

CHUNK_JSON="$(python3 "$ROOT/scripts/lib/threads_chunk_post.py" "$POST_MD" --max-chars "$MAX_CHARS" --mode "$CHUNK_MODE")" || json_err "threads_chunk_post failed"

write_result() {
  local ok="$1"
  local err="${2:-}"
  python3 - "$RUN_DIR" "$ok" "$err" "${POST_IDS[@]+"${POST_IDS[@]}"}" <<'PY'
import json, sys
from pathlib import Path
run_dir, ok_s, err = sys.argv[1], sys.argv[2], sys.argv[3]
ids = sys.argv[4:]
payload = {
    "ok": ok_s == "true",
    "skipped": False,
    "error": err or None,
    "post_ids": ids,
    "chunk_count": len(ids),
}
Path(run_dir, "publish_threads.json").write_text(
    json.dumps(payload, ensure_ascii=False) + "\n", encoding="utf-8"
)
print(json.dumps(payload, ensure_ascii=False))
PY
}

fail_threads() {
  local msg="$1"
  echo "$msg" >&2
  POST_IDS=()
  write_result false "$msg" >&2
  exit 1
}

API_BASE="https://graph.threads.net/v1.0"
TOKEN="$THREADS_ACCESS_TOKEN"
USER="$THREADS_USER_ID"

graph_get() {
  curl -fsS -G "$1" --data-urlencode "access_token=$TOKEN" "${@:2}"
}

graph_form() {
  local url="$1"
  shift
  local -a args=(-sS -X POST "$url" --data-urlencode "access_token=$TOKEN")
  while [[ $# -gt 0 ]]; do
    args+=(--data-urlencode "$1")
    shift
  done
  local resp
  resp="$(curl "${args[@]}")" || { echo "curl failed: $url" >&2; return 1; }
  if ! echo "$resp" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if not d.get('error') else 1)" 2>/dev/null; then
    echo "Threads API error: $resp" >&2
    return 1
  fi
  echo "$resp"
}

wait_ready() {
  local cid="$1"
  local elapsed=0
  while [[ "$elapsed" -lt "$MAX_WAIT" ]]; do
    local body status
    body="$(graph_get "${API_BASE}/${cid}" -d "fields=status,error_message" 2>/dev/null || echo '{}')"
    status="$(echo "$body" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('status',''))" 2>/dev/null || true)"
    if [[ "$status" == "FINISHED" || "$status" == "READY" ]]; then
      return 0
    fi
    if [[ "$status" == "ERROR" || "$status" == "EXPIRED" ]]; then
      echo "container ${cid} status=${status} body=${body}" >&2
      return 1
    fi
    sleep "$POLL_SEC"
    elapsed=$((elapsed + POLL_SEC))
  done
  echo "timeout waiting READY for container ${cid}" >&2
  return 1
}

publish_container() {
  local creation_id="$1"
  wait_ready "$creation_id" || return 1
  local resp
  resp="$(graph_form "${API_BASE}/${USER}/threads_publish" "creation_id=${creation_id}")"
  echo "$resp" | python3 -c "
import sys, json
d = json.load(sys.stdin)
if d.get('error'):
    raise SystemExit(d['error'].get('message', 'publish failed'))
print(d.get('id', ''))
"
}

CHUNK_COUNT="$(echo "$CHUNK_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['chunk_count'])")"
[[ "$CHUNK_COUNT" -ge 1 ]] || json_err "no text chunks"

POST_IDS=()
PUBLISHED_ID=""
i=0
while [[ "$i" -lt "$CHUNK_COUNT" ]]; do
  TEXT="$(echo "$CHUNK_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['chunks'][$i])")"
  if [[ "$i" -eq 0 && "$HAS_IMAGE" -eq 1 ]]; then
    CREATE_RESP="$(graph_form "${API_BASE}/${USER}/threads" \
      "media_type=IMAGE" \
      "image_url=${IMAGE_URL}" \
      "text=${TEXT}")"
  elif [[ "$i" -eq 0 ]]; then
    CREATE_RESP="$(graph_form "${API_BASE}/${USER}/threads" \
      "media_type=TEXT" \
      "text=${TEXT}")"
  else
    [[ -n "$PUBLISHED_ID" ]] || json_err "missing reply_to_id"
    CREATE_RESP="$(graph_form "${API_BASE}/${USER}/threads" \
      "media_type=TEXT" \
      "text=${TEXT}" \
      "reply_to_id=${PUBLISHED_ID}")"
  fi
  CONTAINER_ID="$(echo "$CREATE_RESP" | python3 -c "
import sys,json
d=json.load(sys.stdin)
if d.get('error'):
    print(json.dumps(d.get('error', d), ensure_ascii=False), file=sys.stderr)
    raise SystemExit('create failed')
print(d.get('id',''))
")" || fail_threads "threads create failed chunk ${i}: ${CREATE_RESP}"
  PUBLISHED_ID="$(publish_container "$CONTAINER_ID")" || fail_threads "threads_publish failed chunk ${i}"
  POST_IDS+=("$PUBLISHED_ID")
  i=$((i + 1))
done

write_result true ""
run_state_py "$RUN_DIR" "$RUN_ID" lock --name threads_writer --artifact "threads/publish_threads.json" --revision 1 >/dev/null || true
