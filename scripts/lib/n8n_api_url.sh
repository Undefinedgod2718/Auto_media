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

n8n_api_url_resolve_reachable() {
  local base source
  base="$(n8n_api_url_resolve)"
  source="env"
  if curl -fsS "${base%/}/healthz" >/dev/null 2>&1; then
    printf '%s|%s\n' "${base%/}" "$source"
    return 0
  fi
  if curl -fsS "http://host.docker.internal:5678/healthz" >/dev/null 2>&1; then
    printf '%s|%s\n' "http://host.docker.internal:5678" "fallback_host_docker_internal"
    return 0
  fi
  if curl -fsS "http://172.17.0.1:5678/healthz" >/dev/null 2>&1; then
    printf '%s|%s\n' "http://172.17.0.1:5678" "fallback_17217"
    return 0
  fi
  printf '%s|%s\n' "${base%/}" "unreachable"
  return 1
}
