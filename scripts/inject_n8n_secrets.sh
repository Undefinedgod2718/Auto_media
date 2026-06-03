#!/usr/bin/env bash
# Copy OAuth dirs from workspace into running n8n container (bind mounts may be empty on Docker Desktop virtiofs).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTAINER="${N8N_CONTAINER:-auto_media-n8n-1}"

docker_cp() {
  if [[ -S /var/run/docker.sock ]]; then
    docker cp "$1" "${CONTAINER}:$2"
  else
    sudo docker cp "$1" "${CONTAINER}:$2"
  fi
}

docker_exec() {
  if [[ -S /var/run/docker.sock ]]; then
    docker exec "$CONTAINER" "$@"
  else
    sudo docker exec "$CONTAINER" "$@"
  fi
}

injected=0
for pair in \
  "${ROOT}/data/secrets/claude:/data/secrets/claude" \
  "${ROOT}/data/secrets/gemini:/home/node/.gemini" \
  "${ROOT}/data/secrets/codex:/home/node/.codex"; do
  src="${pair%%:*}"
  dest="${pair##*:}"
  [[ -d "$src" ]] || { echo "skip missing $src" >&2; continue; }
  docker_cp "${src}/." "${dest}/"
  echo "injected $src -> $dest"
  injected=$((injected + 1))
done

[[ "$injected" -ge 1 ]] || { echo '{"ok":false,"error":"no secret dirs to inject"}' >&2; exit 1; }

docker_exec chown -R node:node /data/secrets/claude /home/node/.gemini /home/node/.codex 2>/dev/null || true
docker_exec runuser -u node -- test -f /data/secrets/claude/.credentials.json
docker_exec runuser -u node -- test -f /home/node/.codex/auth.json
echo '{"ok":true,"container":"'"$CONTAINER"'","hint":"claude + gemini + codex oauth injected (docker cp; bind mount may lag on virtiofs)"}'
