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
run_state_ensure "$RUN_DIR" "$RUN_ID"
run_state_require_stage "$RUN_DIR" "$RUN_ID" 7 || json_err "run stage not ready for publish (need pre_publish_ok)"

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

if [[ -f "$RESULT" ]]; then
  if python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get('ok') and not d.get('skipped') else 1)" "$RESULT" 2>/dev/null; then
    write_result true true "already_published"
    exit 0
  fi
fi

set +e
/bin/bash "$(dirname "${BASH_SOURCE[0]}")/lib/publish_target_gate.sh" "$RUN_DIR" facebook
GATE_EC=$?
set -e
if [[ "$GATE_EC" -eq 1 ]]; then
  write_result true true ""
  exit 0
elif [[ "$GATE_EC" -ne 0 ]]; then
  json_err "publish target gate failed (ec=${GATE_EC})"
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

POST_MD="$(PYTHONPATH="$ROOT/scripts/lib" python3 -c "from pathlib import Path; from media_paths import run_post_md; print(run_post_md(Path('$RUN_DIR'),'facebook'))")"
MESSAGE="$(python3 "$ROOT/scripts/lib/ig_caption.py" "$POST_MD" 2>/dev/null || true)"
FB_MAX="$(PYTHONPATH="$ROOT/scripts/lib" python3 -c "from platform_limits import load_limits; print(load_limits()['facebook']['message_max_chars'])")"
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
run_state_py "$RUN_DIR" "$RUN_ID" lock --name facebook_writer --artifact "facebook/publish_facebook.json" --revision 1 >/dev/null || true
