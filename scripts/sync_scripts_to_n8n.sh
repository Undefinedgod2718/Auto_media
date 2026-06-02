#!/usr/bin/env bash
# Copy repo scripts (+ config) into running n8n / gateway containers (until image rebuild).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTAINER="${N8N_CONTAINER:-auto_media-n8n-1}"
GATEWAY_CONTAINER="${GATEWAY_CONTAINER:-auto_media-gateway-1}"

# Dev Container: docker.sock is root-owned (see docs/DEVCONTAINER.md)
DOCKER=(docker)
if ! docker ps >/dev/null 2>&1; then
  if sudo -n docker ps >/dev/null 2>&1; then
    DOCKER=(sudo docker)
  fi
fi

if ! "${DOCKER[@]}" ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  echo "Container $CONTAINER not running. Start: docker compose up -d n8n" >&2
  exit 1
fi

# Windows CRLF in .sh breaks bash (set: pipefail: invalid option name). Normalize before docker cp.
while IFS= read -r -d '' f; do
  if grep -q $'\r' "$f" 2>/dev/null; then
    sed -i 's/\r$//' "$f"
    echo "stripped CRLF: ${f#"$ROOT"/}"
  fi
done < <(find "${ROOT}/scripts" -name '*.sh' -print0)

for pair in \
  "${ROOT}/scripts:/data/scripts" \
  "${ROOT}/config/skills:/data/config/skills"; do
  src="${pair%%:*}"
  dest="${pair##*:}"
  "${DOCKER[@]}" cp "${src}/." "${CONTAINER}:${dest}/"
  echo "synced ${src} -> ${dest}"
done

for cfg in platform_limits.json platform.runtime.json; do
  if [[ -f "${ROOT}/data/config/${cfg}" ]]; then
    "${DOCKER[@]}" exec "$CONTAINER" mkdir -p /data/config
    "${DOCKER[@]}" cp "${ROOT}/data/config/${cfg}" "${CONTAINER}:/data/config/${cfg}"
    echo "synced ${ROOT}/data/config/${cfg} -> /data/config/${cfg}"
  fi
done

"${DOCKER[@]}" exec "$CONTAINER" chmod -R a+rx /data/scripts 2>/dev/null || true
"${DOCKER[@]}" exec "$CONTAINER" test -x /data/scripts/sync_carousel_total.sh

if "${DOCKER[@]}" ps --format '{{.Names}}' | grep -qx "$GATEWAY_CONTAINER"; then
  "${DOCKER[@]}" cp "${ROOT}/scripts/." "${GATEWAY_CONTAINER}:/app/scripts/"
  "${DOCKER[@]}" exec "$GATEWAY_CONTAINER" chmod -R a+rx /app/scripts 2>/dev/null || true
  "${DOCKER[@]}" exec "$GATEWAY_CONTAINER" grep -q send_platform_select /app/scripts/hermes_telegram_gateway.py
  echo "synced ${ROOT}/scripts -> ${GATEWAY_CONTAINER}:/app/scripts"
  if [[ -f "${ROOT}/data/config/platform_limits.json" ]]; then
    "${DOCKER[@]}" exec "$GATEWAY_CONTAINER" mkdir -p /data/config
    "${DOCKER[@]}" cp "${ROOT}/data/config/platform_limits.json" "${GATEWAY_CONTAINER}:/data/config/platform_limits.json"
    echo "synced platform_limits.json -> ${GATEWAY_CONTAINER}:/data/config/"
  fi
fi

echo '{"ok":true,"n8n":"'"$CONTAINER"'","gateway":"'"$GATEWAY_CONTAINER"'","hint":"rebuild images for permanent bake: docker compose build n8n gateway"}'
