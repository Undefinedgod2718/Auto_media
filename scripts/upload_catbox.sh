#!/usr/bin/env bash
set -euo pipefail

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

if [[ "${AUTO_MEDIA_MOCK:-0}" == "1" ]]; then
  echo '{"ok":true,"image_url":"https://placehold.co/1080x1080/FF0000/FFFFFF?text=MOCK"}'
  exit 0
fi

PNG_PATH="/data/runs/${RUN_ID}/post.png"
if [[ ! -f "$PNG_PATH" ]]; then
  echo "{\"ok\":false,\"error\":\"post.png not found: ${PNG_PATH}\"}" >&2
  exit 1
fi

IMAGE_URL="$(curl -s -F "fileToUpload=@${PNG_PATH}" -F 'reqtype=fileupload' 'https://catbox.moe/user/api.php' | tr -d '\r')"
if [[ -z "$IMAGE_URL" || "${IMAGE_URL:0:4}" != "http" ]]; then
  echo "{\"ok\":false,\"error\":\"catbox invalid response: ${IMAGE_URL}\"}" >&2
  exit 1
fi

echo "{\"ok\":true,\"image_url\":\"${IMAGE_URL}\"}"
