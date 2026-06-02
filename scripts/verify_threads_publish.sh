#!/usr/bin/env bash
# Dry-run: verify Threads token + image_url + first chunk from post.md.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

RUN_ID=""
IMAGE_URL=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-id) RUN_ID="$2"; shift 2 ;;
    --image-url) IMAGE_URL="$2"; shift 2 ;;
    *) json_err "unknown arg: $1" ;;
  esac
done

[[ -n "${THREADS_USER_ID:-}" && -n "${THREADS_ACCESS_TOKEN:-}" ]] || json_err "THREADS_USER_ID or THREADS_ACCESS_TOKEN unset"

if [[ -n "$RUN_ID" ]]; then
  RUN_DIR="$(ensure_run_dir "$RUN_ID")"
  POST="${RUN_DIR}/post.md"
  [[ -f "$POST" ]] || json_err "missing post.md"
  if [[ -z "$IMAGE_URL" && -f "${RUN_DIR}/catbox_urls.json" ]]; then
    IMAGE_URL="$(python3 -c "import json; print(json.load(open('${RUN_DIR}/catbox_urls.json')).get('first_url',''))")"
  fi
  CHUNK_JSON="$(python3 "$ROOT/scripts/lib/threads_chunk_post.py" "$POST" --max-chars 500 --mode by_post)"
else
  json_err "provide --run-id"
fi

[[ -n "$IMAGE_URL" ]] || json_err "missing image URL (upload catbox first)"

TEXT="$(echo "$CHUNK_JSON" | python3 -c "import sys,json; c=json.load(sys.stdin)['chunks']; print(c[0] if c else '')")"
LEN="${#TEXT}"

API_BASE="https://graph.threads.net/v1.0"
CREATE_RESP="$(curl -sS -X POST "${API_BASE}/${THREADS_USER_ID}/threads" \
  --data-urlencode "access_token=${THREADS_ACCESS_TOKEN}" \
  --data-urlencode "media_type=IMAGE" \
  --data-urlencode "image_url=${IMAGE_URL}" \
  --data-urlencode "text=${TEXT}")"

python3 - "$CREATE_RESP" "$LEN" "$CHUNK_JSON" <<'PY'
import json, sys
resp, text_len, chunks = sys.argv[1], int(sys.argv[2]), json.loads(sys.argv[3])
d = json.loads(resp)
ok = not d.get("error")
out = {
    "ok": ok,
    "dry_run": True,
    "first_chunk_chars": text_len,
    "chunk_count": chunks.get("chunk_count"),
    "mode": chunks.get("mode"),
    "container_id": d.get("id"),
    "error": d.get("error"),
}
print(json.dumps(out, ensure_ascii=False))
sys.exit(0 if ok else 1)
PY
