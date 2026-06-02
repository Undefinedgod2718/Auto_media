#!/usr/bin/env bash
# Resolve Gateway base URL for host-side scripts (poll forwarder) in Dev Container.
# shellcheck disable=SC2034
gateway_url_resolve() {
  if [[ -n "${GATEWAY_POLL_URL:-}" ]]; then
    printf '%s' "${GATEWAY_POLL_URL%/}"
    return 0
  fi

  local candidates=()
  if [[ -n "${GATEWAY_URL:-}" ]]; then
    candidates+=("${GATEWAY_URL%/}")
  fi
  candidates+=(
    "http://host.docker.internal:${GATEWAY_PORT:-8787}"
    "http://172.17.0.1:${GATEWAY_PORT:-8787}"
    "http://127.0.0.1:${GATEWAY_PORT:-8787}"
  )

  local base
  for base in "${candidates[@]}"; do
    if curl -fsS -m 3 "${base}/healthz" >/dev/null 2>&1; then
      printf '%s' "$base"
      return 0
    fi
  done

  printf '%s' "${GATEWAY_URL:-http://127.0.0.1:${GATEWAY_PORT:-8787}}"
}
