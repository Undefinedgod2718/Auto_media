#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

RUN_ID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-id) RUN_ID="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "$RUN_ID" ]] || json_err "missing --run-id"

RUN_DIR="$(ensure_run_dir "$RUN_ID")"
IMG=""
for f in post.png post.jpg post.jpeg; do
  [[ -f "${RUN_DIR}/${f}" ]] && IMG="${RUN_DIR}/${f}" && break
done
[[ -n "$IMG" ]] || json_err "missing post.png or post.jpg in ${RUN_DIR}"

python3 - "$IMG" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1])
data = p.read_bytes()
if len(data) > 8 * 1024 * 1024:
    sys.exit("image exceeds 8MB")
if data[:8] == b"\x89PNG\r\n\x1a\n":
    sys.exit(0)
if data[:3] == b"\xff\xd8\xff":
    sys.exit(0)
sys.exit("not a valid PNG or JPEG file")
PY

json_ok "$IMG"
