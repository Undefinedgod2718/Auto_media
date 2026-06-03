#!/usr/bin/env bash
# Resolve compose service container names and run docker exec consistently.
# shellcheck disable=SC2034

docker_cli() {
  if [[ -S /var/run/docker.sock ]]; then
    docker "$@"
  elif [[ -S /var/run/docker-host.sock ]]; then
    sudo docker "$@"
  else
    return 127
  fi
}

resolve_compose_container() {
  local root="$1"
  local service="$2"
  local fallback="$3"
  if [[ -n "${N8N_CONTAINER:-}" && "$service" == "n8n" ]]; then
    printf '%s' "$N8N_CONTAINER"
    return 0
  fi
  if [[ -n "${GATEWAY_CONTAINER:-}" && "$service" == "gateway" ]]; then
    printf '%s' "$GATEWAY_CONTAINER"
    return 0
  fi
  if command -v docker >/dev/null 2>&1 && [[ -f "${root}/docker-compose.yml" ]]; then
    local id name
    id="$(docker compose -f "${root}/docker-compose.yml" ps -q "$service" 2>/dev/null | head -1)"
    if [[ -n "$id" ]]; then
      name="$(docker_cli inspect --format '{{.Name}}' "$id" 2>/dev/null | sed 's/^\///')"
      if [[ -n "$name" ]]; then
        printf '%s' "$name"
        return 0
      fi
    fi
  fi
  printf '%s' "$fallback"
}

resolve_n8n_container() {
  resolve_compose_container "${1:-${REPO_ROOT:-.}}" "n8n" "auto_media-n8n-1"
}

docker_exec_n8n() {
  local root="${1:-${REPO_ROOT:-.}}"
  shift
  local c
  c="$(resolve_n8n_container "$root")"
  docker_cli exec "$c" "$@"
}
