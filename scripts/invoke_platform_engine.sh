#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

RUN_ID=""
PLATFORM=""
ARTIFACT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-id) RUN_ID="$2"; shift 2 ;;
    --platform) PLATFORM="$2"; shift 2 ;;
    --artifact) ARTIFACT="$2"; shift 2 ;; # writer | artist
    *) json_err "unknown arg: $1" ;;
  esac
done
[[ -n "$RUN_ID" && -n "$PLATFORM" && -n "$ARTIFACT" ]] || json_err "usage: invoke_platform_engine.sh --run-id ID --platform threads|instagram|facebook --artifact writer|artist"

case "$ARTIFACT" in
  writer)
    exec /bin/bash "$(dirname "${BASH_SOURCE[0]}")/generate_copy.sh" --run-id "$RUN_ID"
    ;;
  artist)
    if [[ "$PLATFORM" == "instagram" ]]; then
      exec /bin/bash "$(dirname "${BASH_SOURCE[0]}")/generate_carousel_images.sh" --run-id "$RUN_ID"
    fi
    exec /bin/bash "$(dirname "${BASH_SOURCE[0]}")/generate_image.sh" --run-id "$RUN_ID"
    ;;
  *)
    json_err "artifact must be writer|artist"
    ;;
esac
