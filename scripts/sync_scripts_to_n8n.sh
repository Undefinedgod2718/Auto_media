#!/usr/bin/env bash
# Copy repo scripts (+ config) into running n8n / gateway containers (until image rebuild).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTAINER="${N8N_CONTAINER:-auto_media-n8n-1}"
GATEWAY_CONTAINER="${GATEWAY_CONTAINER:-auto_media-gateway-1}"

# shellcheck source=scripts/lib/docker_helpers.sh
source "$ROOT/scripts/lib/docker_helpers.sh"
init_docker_compose "$ROOT"
CONTAINER="$(resolve_n8n_container "$ROOT")"
if [[ "$HAVE_DOCKER_COMPOSE" == "1" ]]; then
  gid="$("${DOCKER_COMPOSE[@]}" ps -q gateway 2>/dev/null | head -1)"
  if [[ -n "$gid" ]]; then
    gname="$("${DOCKER_EXEC[@]}" inspect --format '{{.Name}}' "$gid" 2>/dev/null | sed 's/^\///')"
    [[ -n "$gname" ]] && GATEWAY_CONTAINER="$gname"
  fi
fi

if ! "${DOCKER_EXEC[@]}" ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
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
  "${DOCKER_EXEC[@]}" cp "${src}/." "${CONTAINER}:${dest}/"
  echo "synced ${src} -> ${dest}"
done

for cfg in platform_limits.json platform.runtime.json; do
  if [[ -f "${ROOT}/data/config/${cfg}" ]]; then
    "${DOCKER_EXEC[@]}" exec "$CONTAINER" mkdir -p /data/config
    "${DOCKER_EXEC[@]}" cp "${ROOT}/data/config/${cfg}" "${CONTAINER}:/data/config/${cfg}"
    echo "synced ${ROOT}/data/config/${cfg} -> /data/config/${cfg}"
  fi
done

if [[ -d "${ROOT}/config/meta" ]]; then
  "${DOCKER_EXEC[@]}" exec "$CONTAINER" mkdir -p /data/config/meta
  "${DOCKER_EXEC[@]}" cp "${ROOT}/config/meta/." "${CONTAINER}:/data/config/meta/"
  echo "synced ${ROOT}/config/meta -> /data/config/meta"
fi

"${DOCKER_EXEC[@]}" exec "$CONTAINER" chmod -R a+rx /data/scripts 2>/dev/null || true
"${DOCKER_EXEC[@]}" exec "$CONTAINER" test -x /data/scripts/sync_carousel_total.sh

if "${DOCKER_EXEC[@]}" ps --format '{{.Names}}' | grep -qx "$GATEWAY_CONTAINER"; then
  "${DOCKER_EXEC[@]}" cp "${ROOT}/scripts/." "${GATEWAY_CONTAINER}:/app/scripts/"
  "${DOCKER_EXEC[@]}" exec "$GATEWAY_CONTAINER" chmod -R a+rx /app/scripts 2>/dev/null || true
  "${DOCKER_EXEC[@]}" exec "$GATEWAY_CONTAINER" grep -q send_platform_select /app/scripts/hermes_telegram_gateway.py
  echo "synced ${ROOT}/scripts -> ${GATEWAY_CONTAINER}:/app/scripts"
  if [[ -f "${ROOT}/data/config/platform_limits.json" ]]; then
    "${DOCKER_EXEC[@]}" exec "$GATEWAY_CONTAINER" mkdir -p /data/config
    "${DOCKER_EXEC[@]}" cp "${ROOT}/data/config/platform_limits.json" "${GATEWAY_CONTAINER}:/data/config/platform_limits.json"
    echo "synced platform_limits.json -> ${GATEWAY_CONTAINER}:/data/config/"
  fi
  if [[ -d "${ROOT}/config/meta" ]]; then
    "${DOCKER_EXEC[@]}" exec "$GATEWAY_CONTAINER" mkdir -p /data/config/meta
    "${DOCKER_EXEC[@]}" cp "${ROOT}/config/meta/." "${GATEWAY_CONTAINER}:/data/config/meta/"
    echo "synced config/meta -> ${GATEWAY_CONTAINER}:/data/config/meta/"
  fi
fi

echo '{"ok":true,"n8n":"'"$CONTAINER"'","gateway":"'"$GATEWAY_CONTAINER"'","hint":"rebuild images for permanent bake: docker compose build n8n gateway"}'
