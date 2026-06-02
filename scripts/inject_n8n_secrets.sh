#!/usr/bin/env bash
# Copy OAuth dirs from workspace into running n8n container (bind mounts may be empty on Docker Desktop virtiofs).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTAINER="${N8N_CONTAINER:-auto_media-n8n-1}"

for pair in \
  "${ROOT}/data/secrets/claude:/data/secrets/claude" \
  "${ROOT}/data/secrets/gemini:/home/node/.gemini" \
  "${ROOT}/data/secrets/codex:/home/node/.codex"; do
  src="${pair%%:*}"
  dest="${pair##*:}"
  [[ -d "$src" ]] || { echo "skip missing $src" >&2; continue; }
  sudo docker cp "${src}/." "${CONTAINER}:${dest}/"
  echo "injected $src -> $dest"
done

sudo docker exec "$CONTAINER" chown -R node:node /data/secrets/claude /home/node/.gemini /home/node/.codex 2>/dev/null || true
sudo docker exec "$CONTAINER" runuser -u node -- test -f /data/secrets/claude/.credentials.json
sudo docker exec "$CONTAINER" runuser -u node -- test -f /home/node/.codex/auth.json
echo '{"ok":true,"container":"'"$CONTAINER"'","hint":"claude + gemini + codex oauth injected (docker cp; bind mount may lag on virtiofs)"}'
