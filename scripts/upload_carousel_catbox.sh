#!/usr/bin/env bash
# Upload carousel/*.png (or post.png fallback) to catbox; emit JSON with all URLs.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

RUN_ID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-id) RUN_ID="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [[ -z "$RUN_ID" ]]; then
  echo '{"ok":false,"error":"missing --run-id"}' >&2
  exit 1
fi

RUN_DIR="$(ensure_run_dir "$RUN_ID")" || json_err "missing or unreadable run dir: ${DATA_ROOT}/runs/${RUN_ID}"
CAROUSEL_DIR="${RUN_DIR}/carousel"
URLS=()

upload_one() {
  local path="$1"
  if [[ "${AUTO_MEDIA_MOCK:-0}" == "1" ]]; then
    local n="${#URLS[@]}"
    URLS+=("https://placehold.co/1080x1080/222222/FFFFFF?text=MOCK${n}")
    return 0
  fi
  local url
  url="$(curl -s -F "fileToUpload=@${path}" -F 'reqtype=fileupload' 'https://catbox.moe/user/api.php' | tr -d '\r')"
  if [[ -z "$url" || "${url:0:4}" != "http" ]]; then
    echo "{\"ok\":false,\"error\":\"catbox failed for ${path}: ${url}\"}" >&2
    return 1
  fi
  URLS+=("$url")
}

if [[ -d "$CAROUSEL_DIR" ]]; then
  shopt -s nullglob
  mapfile -t FILES < <(find "$CAROUSEL_DIR" -maxdepth 1 -name '*.png' -o -name '*.jpg' -o -name '*.jpeg' | sort)
  shopt -u nullglob
  if [[ ${#FILES[@]} -gt 0 ]]; then
    for f in "${FILES[@]}"; do
      upload_one "$f" || exit 1
    done
  fi
fi

CAROUSEL_COUNT=0
if [[ -d "$CAROUSEL_DIR" ]]; then
  CAROUSEL_COUNT="$(find "$CAROUSEL_DIR" -maxdepth 1 \( -name '*.png' -o -name '*.jpg' \) 2>/dev/null | wc -l | tr -d ' ')"
fi

if [[ ${#URLS[@]} -eq 0 ]]; then
  if [[ "$CAROUSEL_COUNT" -gt 0 ]]; then
    echo "{\"ok\":false,\"error\":\"carousel dir has files but upload failed\"}" >&2
    exit 1
  fi
  for f in post.png post.jpg post.jpeg; do
    if [[ -f "${RUN_DIR}/${f}" ]]; then
      upload_one "${RUN_DIR}/${f}" || exit 1
      break
    fi
  done
fi

if [[ ${#URLS[@]} -eq 0 ]]; then
  python3 - "$RUN_DIR" <<'PY'
import json, sys
from pathlib import Path

run_dir = Path(sys.argv[1])
payload = {
    "ok": True,
    "skipped": True,
    "reason": f"no images under {run_dir}/carousel or post.png",
    "image_urls": [],
    "first_url": "",
}
print(json.dumps(payload, ensure_ascii=False))
PY
  exit 0
fi

python3 - "$RUN_DIR" "${URLS[@]}" <<'PY'
import json, sys
from pathlib import Path

run_dir = Path(sys.argv[1])
urls = sys.argv[2:]
payload = {"ok": True, "image_urls": urls, "first_url": urls[0] if urls else ""}
try:
    (run_dir / "catbox_urls.json").write_text(
        json.dumps({"image_urls": urls, "first_url": payload["first_url"]}, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
except OSError:
    pass
print(json.dumps(payload, ensure_ascii=False))
PY
