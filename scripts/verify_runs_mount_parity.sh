#!/usr/bin/env bash
# Assert n8n and gateway containers see the same artifacts under /data/runs/<run_id>.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

RUN_ID="${1:-}"
N8N_CONTAINER="${N8N_CONTAINER:-auto_media-n8n-1}"
GATEWAY_CONTAINER="${GATEWAY_CONTAINER:-auto_media-gateway-1}"
REQUIRED_TEXT="TASK.md post.md"

[[ -n "$RUN_ID" ]] || json_err "usage: verify_runs_mount_parity.sh <run_id>"

docker_exec() {
  local c="$1"
  shift
  if [[ -S /var/run/docker.sock ]]; then
    docker exec "$c" "$@"
  else
    sudo docker exec "$c" "$@"
  fi
}

list_files() {
  local c="$1"
  docker_exec "$c" sh -c "ls -1 /data/runs/${RUN_ID} 2>/dev/null | sort | tr '\n' ' '" 2>/dev/null || true
}

n8n_files="$(list_files "$N8N_CONTAINER")"
gw_files="$(list_files "$GATEWAY_CONTAINER")"
host_files=""
if [[ -d "${DATA_ROOT}/runs/${RUN_ID}" ]]; then
  host_files="$(ls -1 "${DATA_ROOT}/runs/${RUN_ID}" 2>/dev/null | sort | tr '\n' ' ')"
fi

errors=()
for f in $REQUIRED_TEXT; do
  if ! docker_exec "$N8N_CONTAINER" test -f "/data/runs/${RUN_ID}/${f}" 2>/dev/null; then
    errors+=("n8n missing ${f}")
  fi
  if ! docker_exec "$GATEWAY_CONTAINER" test -f "/data/runs/${RUN_ID}/${f}" 2>/dev/null; then
    errors+=("gateway missing ${f}")
  fi
done

has_image_any() {
  local c="$1"
  docker_exec "$c" sh -c "
    test -f '/data/runs/${RUN_ID}/post.png' \
      || test -f '/data/runs/${RUN_ID}/post.jpg' \
      || test -f '/data/runs/${RUN_ID}/post.jpeg' \
      || ls '/data/runs/${RUN_ID}/carousel'/*.png >/dev/null 2>&1 \
      || ls '/data/runs/${RUN_ID}/carousel'/*.jpg >/dev/null 2>&1 \
      || ls '/data/runs/${RUN_ID}/carousel'/*.jpeg >/dev/null 2>&1
  " 2>/dev/null
}

if ! has_image_any "$N8N_CONTAINER"; then
  errors+=("n8n missing image artifact (need post.png/jpg/jpeg or carousel/*.png/jpg/jpeg)")
fi
if ! has_image_any "$GATEWAY_CONTAINER"; then
  errors+=("gateway missing image artifact (need post.png/jpg/jpeg or carousel/*.png/jpg/jpeg)")
fi

if [[ "$n8n_files" != "$gw_files" ]]; then
  errors+=("file list mismatch n8n=[${n8n_files}] gateway=[${gw_files}]")
fi

if ((${#errors[@]} > 0)); then
  for e in "${errors[@]}"; do
    echo "FAIL: $e" >&2
  done
  python3 - <<PY
import json
print(json.dumps({
  "ok": False,
  "error": "runs mount parity failed",
  "run_id": "$RUN_ID",
  "n8n_files": "$n8n_files".split(),
  "gateway_files": "$gw_files".split(),
  "host_files": "$host_files".split(),
  "errors": $(printf '%s\n' "${errors[@]}" | python3 -c 'import json,sys; print(json.dumps([l for l in sys.stdin.read().splitlines() if l]))'),
}, ensure_ascii=False))
PY
  exit 1
fi

python3 - <<PY
import json
print(json.dumps({
  "ok": True,
  "path": "verify_runs_mount_parity",
  "run_id": "$RUN_ID",
  "n8n_files": "$n8n_files".split(),
  "gateway_files": "$gw_files".split(),
  "host_files": "$host_files".split(),
}, ensure_ascii=False))
PY
