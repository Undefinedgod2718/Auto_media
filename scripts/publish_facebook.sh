#!/usr/bin/env bash
# Publish to Facebook Page: /photos when catbox URL exists, else /feed for text-only.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_LIB="$(dirname "${BASH_SOURCE[0]}")/lib"
# shellcheck source=lib/load_env.sh
source "${SCRIPT_LIB}/load_env.sh"
load_repo_env "$ROOT"
source "${SCRIPT_LIB}/common.sh"
source "${SCRIPT_LIB}/meta_token_util.sh"

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

write_fb_result() {
  local ok="$1" skipped="$2" reason="${3:-}" err="${4:-}"
  python3 - "$RESULT" "$ok" "$skipped" "$reason" "$err" <<'PY'
import json, sys
from pathlib import Path
path, ok, skipped = sys.argv[1], sys.argv[2] == "true", sys.argv[3] == "true"
reason, err = sys.argv[4], sys.argv[5]
payload = {"ok": ok, "skipped": skipped, "error": err or None}
if reason:
    payload["reason"] = reason
Path(path).write_text(json.dumps(payload, ensure_ascii=False) + "\n", encoding="utf-8")
print(json.dumps(payload, ensure_ascii=False))
PY
}

write_fb_skip() {
  local reason="$1"
  local err="${2:-}"
  write_fb_result true true "$reason" "$err"
  run_state_py "$RUN_DIR" "$RUN_ID" lock --name facebook_writer --artifact "facebook/publish_facebook.json" --revision 1 >/dev/null || true
  exit 0
}

if [[ -f "$RESULT" ]]; then
  if python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get('ok') and not d.get('skipped') else 1)" "$RESULT" 2>/dev/null; then
    write_fb_skip "already_published" ""
  fi
fi

set +e
/bin/bash "$(dirname "${BASH_SOURCE[0]}")/lib/publish_target_gate.sh" "$RUN_DIR" facebook
GATE_EC=$?
set -e
if [[ "$GATE_EC" -eq 1 ]]; then
  write_fb_skip "not in publish_targets" ""
elif [[ "$GATE_EC" -ne 0 ]]; then
  json_err "publish target gate failed (ec=${GATE_EC})"
fi

if [[ -z "${META_PAGE_ID:-}" || -z "${META_PAGE_ACCESS_TOKEN:-}" ]]; then
  write_fb_skip "missing_credentials" ""
fi

if ! is_page_access_token "${META_PAGE_ACCESS_TOKEN:-}"; then
  write_fb_skip "wrong_token_type" \
    "META_PAGE_ACCESS_TOKEN must be a Facebook Page token (EAA...)."
fi

if [[ ! -f "${RUN_DIR}/catbox_urls.json" ]]; then
  /bin/bash "$(dirname "${BASH_SOURCE[0]}")/upload_carousel_catbox.sh" --run-id "$RUN_ID" >/dev/null || true
fi

IMAGE_URL="$(python3 -c "
import json
from pathlib import Path
p = Path('${RUN_DIR}') / 'catbox_urls.json'
print(json.load(open(p)).get('first_url', '') if p.is_file() else '')
" 2>/dev/null || true)"

POST_MD="$(PYTHONPATH="$ROOT/scripts/lib" python3 -c "from pathlib import Path; from media_paths import run_post_md; print(run_post_md(Path('$RUN_DIR'),'facebook'))")"
MESSAGE="$(python3 "$ROOT/scripts/lib/ig_caption.py" "$POST_MD" 2>/dev/null || true)"
FB_MAX="$(PYTHONPATH="$ROOT/scripts/lib" python3 -c "from platform_limits import load_limits; print(load_limits()['facebook']['message_max_chars'])")"
MSG_LEN="${#MESSAGE}"
if [[ "$MSG_LEN" -gt "$FB_MAX" ]]; then
  /bin/bash "$ROOT/scripts/notify_platform_limit.sh" --run-id "$RUN_ID" --phase pre_publish \
    --violations-json "[{\"platform\":\"facebook\",\"code\":\"message_max_chars\",\"message_zh\":\"FB 貼文超過 ${FB_MAX} 字元（目前 ${MSG_LEN}）\"}]" 2>/dev/null || true
  write_fb_result false false "message_too_long" "FB message ${MSG_LEN} chars exceeds limit ${FB_MAX}"
  exit 1
fi

if [[ -z "$IMAGE_URL" && -z "$MESSAGE" ]]; then
  write_fb_skip "empty_content" ""
fi

VERSION="${META_GRAPH_API_VERSION:-v21.0}"

if [[ -n "$IMAGE_URL" ]]; then
  FB_MODE="photo"
  RESP="$(curl -sS -X POST \
    "https://graph.facebook.com/${VERSION}/${META_PAGE_ID}/photos" \
    --data-urlencode "url=${IMAGE_URL}" \
    --data-urlencode "message=${MESSAGE}" \
    --data-urlencode "access_token=${META_PAGE_ACCESS_TOKEN}" 2>&1)" || true
else
  FB_MODE="feed"
  RESP="$(curl -sS -X POST \
    "https://graph.facebook.com/${VERSION}/${META_PAGE_ID}/feed" \
    --data-urlencode "message=${MESSAGE}" \
    --data-urlencode "access_token=${META_PAGE_ACCESS_TOKEN}" 2>&1)" || true
fi
if [[ -z "$RESP" ]]; then
  write_fb_result false false "graph_api_error" "empty response from Graph API (curl failed?)"
  exit 1
fi

ERR_MSG="$(echo "$RESP" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except json.JSONDecodeError:
    print('non-JSON Graph response')
    raise SystemExit(0)
err = d.get('error')
if err:
    print(err.get('message', str(err)))
" 2>/dev/null || true)"

if [[ -n "$ERR_MSG" ]]; then
  if is_meta_token_skip_msg "$ERR_MSG"; then
    write_fb_skip "token_invalid" "$ERR_MSG"
  fi
  if is_meta_publish_permission_skip_msg "$ERR_MSG"; then
    write_fb_skip "missing_publish_permission" "$ERR_MSG"
  fi
  write_fb_result false false "graph_api_error" "$ERR_MSG"
  exit 1
fi

python3 - "$RESULT" "$FB_MODE" "$RESP" <<'PY'
import json, sys
from pathlib import Path
path, mode, raw = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    d = json.loads(raw) if raw.strip() else {}
except json.JSONDecodeError:
    payload = {"ok": False, "skipped": False, "error": "non-JSON Graph response", "reason": "graph_api_error"}
    Path(path).write_text(json.dumps(payload, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps(payload, ensure_ascii=False))
    raise SystemExit(1)
post_id = d.get("post_id") or d.get("id") or ""
if not post_id and d.get("error"):
    err = d["error"]
    msg = err.get("message", str(err)) if isinstance(err, dict) else str(err)
    payload = {"ok": False, "skipped": False, "error": msg, "reason": "graph_api_error"}
    Path(path).write_text(json.dumps(payload, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps(payload, ensure_ascii=False))
    raise SystemExit(1)
payload = {
    "ok": True,
    "skipped": False,
    "error": None,
    "mode": mode,
    "post_id": post_id,
}
Path(path).write_text(json.dumps(payload, ensure_ascii=False) + "\n", encoding="utf-8")
print(json.dumps(payload, ensure_ascii=False))
PY
run_state_py "$RUN_DIR" "$RUN_ID" lock --name facebook_writer --artifact "facebook/publish_facebook.json" --revision 1 >/dev/null || true
