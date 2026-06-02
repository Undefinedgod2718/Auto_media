#!/usr/bin/env bash
# Publish one image to Facebook Page via Graph API (image_url, no multipart).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

RUN_ID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-id) RUN_ID="$2"; shift 2 ;;
    *) json_err "unknown arg: $1" ;;
  esac
done
[[ -n "$RUN_ID" ]] || json_err "usage: publish_facebook.sh --run-id ID"

RUN_DIR="$(ensure_run_dir "$RUN_ID")"
RESULT="${RUN_DIR}/publish_facebook.json"

write_result() {
  local ok="$1" skipped="$2" err="${3:-}"
  python3 - "$RESULT" "$ok" "$skipped" "$err" <<'PY'
import json, sys
from pathlib import Path
path, ok, skipped, err = sys.argv[1], sys.argv[2] == "true", sys.argv[3] == "true", sys.argv[4]
payload = {"ok": ok, "skipped": skipped, "error": err or None}
Path(path).write_text(json.dumps(payload, ensure_ascii=False) + "\n", encoding="utf-8")
print(json.dumps(payload, ensure_ascii=False))
PY
}

if ! /bin/bash "$(dirname "${BASH_SOURCE[0]}")/lib/publish_target_gate.sh" "$RUN_DIR" facebook; then
  write_result true true ""
  exit 0
fi

if [[ -z "${META_PAGE_ID:-}" || -z "${META_PAGE_ACCESS_TOKEN:-}" ]]; then
  write_result true true ""
  exit 0
fi

if [[ ! -f "${RUN_DIR}/catbox_urls.json" ]]; then
  /bin/bash "$(dirname "${BASH_SOURCE[0]}")/upload_carousel_catbox.sh" --run-id "$RUN_ID" >/dev/null || true
fi

IMAGE_URL="$(python3 -c "import json; print(json.load(open('${RUN_DIR}/catbox_urls.json')).get('first_url',''))" 2>/dev/null || true)"
[[ -n "$IMAGE_URL" ]] || { write_result false false "no catbox URL"; exit 1; }

POST_MD="${RUN_DIR}/post.md"
MESSAGE="$(python3 "$ROOT/scripts/lib/ig_caption.py" "$POST_MD" 2>/dev/null || true)"
FB_MAX="$(python3 -c "import json; print(json.load(open('$ROOT/data/config/platform_limits.json'))['facebook']['message_max_chars'])")"
MSG_LEN="${#MESSAGE}"
if [[ "$MSG_LEN" -gt "$FB_MAX" ]]; then
  write_result false false "FB message ${MSG_LEN} chars exceeds limit ${FB_MAX}"
  /bin/bash "$ROOT/scripts/notify_platform_limit.sh" --run-id "$RUN_ID" --phase pre_publish \
    --violations-json "[{\"platform\":\"facebook\",\"code\":\"message_max_chars\",\"message_zh\":\"FB 貼文超過 ${FB_MAX} 字元（目前 ${MSG_LEN}）\"}]" 2>/dev/null || true
  exit 1
fi
VERSION="${META_GRAPH_API_VERSION:-v21.0}"

RESP="$(curl -sS -X POST \
  "https://graph.facebook.com/${VERSION}/${META_PAGE_ID}/photos" \
  --data-urlencode "url=${IMAGE_URL}" \
  --data-urlencode "message=${MESSAGE}" \
  --data-urlencode "access_token=${META_PAGE_ACCESS_TOKEN}")"

if echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(1 if d.get('error') else 0)" 2>/dev/null; then
  write_result false false "$RESP"
  exit 1
fi

POST_ID="$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('post_id',''))")"
python3 - "$RESULT" "$POST_ID" <<'PY'
import json, sys
from pathlib import Path
path, post_id = sys.argv[1], sys.argv[2]
payload = {"ok": True, "skipped": False, "error": None, "post_id": post_id}
Path(path).write_text(json.dumps(payload, ensure_ascii=False) + "\n", encoding="utf-8")
print(json.dumps(payload, ensure_ascii=False))
PY
