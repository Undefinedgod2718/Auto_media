#!/usr/bin/env bash
# Resolve n8n REST API base URL (Dev Container → host Docker).
# shellcheck disable=SC2034
n8n_api_url_resolve() {
  if [[ -n "${N8N_SYNC_API_URL:-}" ]]; then
    printf '%s' "${N8N_SYNC_API_URL%/}"
    return 0
  fi
  if [[ -n "${GATEWAY_N8N_API_URL:-}" ]]; then
    printf '%s' "${GATEWAY_N8N_API_URL%/}"
    return 0
  fi
  printf '%s' "${N8N_API_URL:-http://localhost:5678}"
}
