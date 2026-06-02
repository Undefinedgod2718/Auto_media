#!/usr/bin/env bash
# Publish Instagram post or carousel via Graph API (/media → /media_publish).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

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

if [[ -z "${IG_USER_ID:-}" || -z "${META_PAGE_ACCESS_TOKEN:-}" ]]; then
  python3 - "$RUN_DIR" <<'PY'
import json, sys
from pathlib import Path
run_dir = Path(sys.argv[1])
payload = {"ok": True, "skipped": True, "error": None}
Path(run_dir, "publish_ig.json").write_text(json.dumps(payload, ensure_ascii=False) + "\n", encoding="utf-8")
print(json.dumps(payload, ensure_ascii=False))
PY
run_state_py "$RUN_DIR" "$RUN_ID" lock --name instagram_artist --artifact "instagram/publish_ig.json" --revision 1 >/dev/null || true
  exit 0
fi

CATBOX_JSON="${RUN_DIR}/catbox_urls.json"
POST_MD="$(PYTHONPATH="$ROOT/scripts/lib" python3 -c "from pathlib import Path; from media_paths import run_post_md; print(run_post_md(Path('$RUN_DIR'),'instagram'))")"

if [[ ! -f "$CATBOX_JSON" ]]; then
  /bin/bash "$(dirname "${BASH_SOURCE[0]}")/upload_carousel_catbox.sh" --run-id "$RUN_ID" >/dev/null
fi
[[ -f "$CATBOX_JSON" ]] || json_err "missing catbox_urls.json — run upload_carousel_catbox first"

URLS_JSON="$(python3 -c "import json; print(json.dumps(json.load(open('$CATBOX_JSON'))['image_urls']))")"
CAPTION_FILE="${RUN_DIR}/.ig_caption.txt"
python3 "$ROOT/scripts/lib/ig_caption.py" "$POST_MD" >"$CAPTION_FILE" 2>/dev/null || echo "" >"$CAPTION_FILE"

OUT="$(python3 "$ROOT/scripts/lib/ig_publish.py" \
  --urls-json "$URLS_JSON" \
  --caption-file "$CAPTION_FILE")" || {
  python3 - "$RUN_DIR" "$OUT" <<'PY'
import json, sys
from pathlib import Path
run_dir, err = Path(sys.argv[1]), sys.argv[2]
Path(run_dir, "publish_ig.json").write_text(
    json.dumps({"ok": False, "skipped": False, "error": err}, ensure_ascii=False) + "\n",
    encoding="utf-8",
)
PY
  exit 1
}

python3 - "$RUN_DIR" "$OUT" <<'PY'
import json, sys
from pathlib import Path
run_dir = Path(sys.argv[1])
result = json.loads(sys.argv[2])
payload = {"ok": bool(result.get("ok")), "skipped": bool(result.get("skipped")), "error": result.get("error")}
if not payload["skipped"]:
    payload.update({k: result[k] for k in ("post_id", "mode", "slide_count") if k in result})
Path(run_dir, "publish_ig.json").write_text(json.dumps(payload, ensure_ascii=False) + "\n", encoding="utf-8")
print(json.dumps(payload, ensure_ascii=False))
if not payload["ok"] and not payload["skipped"]:
    sys.exit(1)
PY
