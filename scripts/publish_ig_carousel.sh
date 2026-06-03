#!/usr/bin/env bash
# Publish Instagram post or carousel via Graph API (/media → /media_publish).
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
[[ -n "$RUN_ID" ]] || json_err "usage: publish_ig_carousel.sh --run-id ID"

RUN_DIR="$(ensure_run_dir "$RUN_ID")"
run_state_ensure "$RUN_DIR" "$RUN_ID"
run_state_require_stage "$RUN_DIR" "$RUN_ID" 7 || json_err "run stage not ready for publish (need pre_publish_ok)"

if [[ -f "${RUN_DIR}/publish_ig.json" ]]; then
  if python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get('ok') and not d.get('skipped') else 1)" "${RUN_DIR}/publish_ig.json" 2>/dev/null; then
    python3 - "$RUN_DIR" <<'PY'
import json, sys
from pathlib import Path
run_dir = Path(sys.argv[1])
payload = {"ok": True, "skipped": True, "reason": "already_published"}
Path(run_dir, "publish_ig.json").write_text(json.dumps(payload, ensure_ascii=False) + "\n", encoding="utf-8")
print(json.dumps(payload, ensure_ascii=False))
PY
    exit 0
  fi
fi

set +e
/bin/bash "$(dirname "${BASH_SOURCE[0]}")/lib/publish_target_gate.sh" "$RUN_DIR" instagram
GATE_EC=$?
set -e
if [[ "$GATE_EC" -eq 1 ]]; then
  python3 - "$RUN_DIR" <<'PY'
import json, sys
from pathlib import Path
run_dir = Path(sys.argv[1])
payload = {"ok": True, "skipped": True, "reason": "not in publish_targets"}
Path(run_dir, "publish_ig.json").write_text(json.dumps(payload, ensure_ascii=False) + "\n", encoding="utf-8")
print(json.dumps(payload, ensure_ascii=False))
PY
  exit 0
elif [[ "$GATE_EC" -ne 0 ]]; then
  json_err "publish target gate failed (ec=${GATE_EC})"
fi

write_ig_skip() {
  local reason="$1"
  local err="${2:-}"
  python3 - "$RUN_DIR" "$reason" "$err" <<'PY'
import json, sys
from pathlib import Path
run_dir, reason, err = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
payload = {"ok": True, "skipped": True, "reason": reason}
if err:
    payload["error"] = err
Path(run_dir, "publish_ig.json").write_text(json.dumps(payload, ensure_ascii=False) + "\n", encoding="utf-8")
print(json.dumps(payload, ensure_ascii=False))
PY
  run_state_py "$RUN_DIR" "$RUN_ID" lock --name instagram_artist --artifact "instagram/publish_ig.json" --revision 1 >/dev/null || true
  exit 0
}

if [[ -z "${IG_USER_ID:-}" || -z "${META_PAGE_ACCESS_TOKEN:-}" ]]; then
  write_ig_skip "missing_credentials" ""
fi

if ! is_page_access_token "${META_PAGE_ACCESS_TOKEN:-}"; then
  write_ig_skip "wrong_token_type" \
    "META_PAGE_ACCESS_TOKEN must be a Facebook Page token (EAA...). Threads token (THAA...) cannot publish IG."
fi

CATBOX_JSON="${RUN_DIR}/catbox_urls.json"
POST_MD="$(PYTHONPATH="$ROOT/scripts/lib" python3 -c "from pathlib import Path; from media_paths import run_post_md; print(run_post_md(Path('$RUN_DIR'),'instagram'))")"

if [[ ! -f "$CATBOX_JSON" ]]; then
  /bin/bash "$(dirname "${BASH_SOURCE[0]}")/upload_carousel_catbox.sh" --run-id "$RUN_ID" >/dev/null || true
fi
if [[ ! -f "$CATBOX_JSON" ]]; then
  write_ig_skip "no_images" ""
fi

URL_COUNT="$(python3 -c "import json; print(len(json.load(open('${CATBOX_JSON}')).get('image_urls') or []))" 2>/dev/null || echo 0)"
if [[ "${URL_COUNT:-0}" -eq 0 ]]; then
  write_ig_skip "no_images" ""
fi

URLS_JSON="$(python3 -c "import json; print(json.dumps(json.load(open('$CATBOX_JSON'))['image_urls']))")"
CAPTION_FILE="${RUN_DIR}/.ig_caption.txt"
python3 "$ROOT/scripts/lib/ig_caption.py" "$POST_MD" >"$CAPTION_FILE" 2>/dev/null || echo "" >"$CAPTION_FILE"

OUT="$(python3 "$ROOT/scripts/lib/ig_publish.py" \
  --urls-json "$URLS_JSON" \
  --caption-file "$CAPTION_FILE" 2>&1)" || {
  msg="$(printf '%s' "$OUT" | tail -1)"
  if is_meta_token_skip_msg "$msg"; then
    write_ig_skip "token_invalid" "$msg"
  fi
  python3 - "$RUN_DIR" "$OUT" <<'PY'
import json, sys
from pathlib import Path
run_dir, err = Path(sys.argv[1]), sys.argv[2]
payload = {"ok": False, "skipped": False, "error": str(err or "").strip()}
Path(run_dir, "publish_ig.json").write_text(json.dumps(payload, ensure_ascii=False) + "\n", encoding="utf-8")
print(json.dumps(payload, ensure_ascii=False))
raise SystemExit(1)
PY
}

python3 - "$RUN_DIR" "$OUT" <<'PY'
import json, sys
from pathlib import Path
run_dir = Path(sys.argv[1])
result = json.loads(sys.argv[2])
payload = {"ok": bool(result.get("ok")), "skipped": bool(result.get("skipped")), "error": result.get("error")}
if not payload["skipped"]:
    payload.update({k: result[k] for k in ("post_id", "mode", "slide_count") if k in result})
if (not payload["ok"]) and isinstance(payload.get("error"), str):
    msg = payload["error"].lower()
    skip_terms = (
        "session has expired",
        "error validating access token",
        "cannot parse access token",
        "invalid oauth access token",
        "code 190",
    )
    if any(t in msg for t in skip_terms):
        payload["ok"] = True
        payload["skipped"] = True
        payload["reason"] = "token_invalid"
Path(run_dir, "publish_ig.json").write_text(json.dumps(payload, ensure_ascii=False) + "\n", encoding="utf-8")
print(json.dumps(payload, ensure_ascii=False))
if not payload["ok"] and not payload["skipped"]:
    sys.exit(1)
PY
