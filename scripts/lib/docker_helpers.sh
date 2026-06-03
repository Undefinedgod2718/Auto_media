#!/usr/bin/env bash
# Resolve compose service container names and run docker exec consistently.
# shellcheck disable=SC2034

HAVE_DOCKER_COMPOSE=0
DOCKER_COMPOSE=()
DOCKER_EXEC=()

docker_cli() {
  if [[ -S /var/run/docker.sock ]]; then
    docker "$@"
  elif [[ -S /var/run/docker-host.sock ]]; then
    sudo docker "$@"
  else
    return 127
  fi
}

# Probe docker compose / sudo -n docker compose / sudo docker compose via compose ps -q n8n.
# On success sets DOCKER_COMPOSE=(prefix... -f compose_file) and returns 0.
docker_compose_prefix() {
  local root="$1"
  local cf="${root}/docker-compose.yml"
  DOCKER_COMPOSE=()
  HAVE_DOCKER_COMPOSE=0
  if [[ ! -f "$cf" ]]; then
    return 1
  fi
  if docker compose -f "$cf" ps -q n8n &>/dev/null; then
    DOCKER_COMPOSE=(docker compose -f "$cf")
    HAVE_DOCKER_COMPOSE=1
    return 0
  fi
  if sudo -n docker compose -f "$cf" ps -q n8n &>/dev/null; then
    DOCKER_COMPOSE=(sudo -n docker compose -f "$cf")
    HAVE_DOCKER_COMPOSE=1
    return 0
  fi
  if sudo docker compose -f "$cf" ps -q n8n &>/dev/null; then
    DOCKER_COMPOSE=(sudo docker compose -f "$cf")
    HAVE_DOCKER_COMPOSE=1
    return 0
  fi
  return 1
}

# Set DOCKER_EXEC for docker cp / exec / ps (not compose subcommand).
docker_exec_prefix() {
  DOCKER_EXEC=()
  if docker ps &>/dev/null; then
    DOCKER_EXEC=(docker)
    return 0
  fi
  if sudo -n docker ps &>/dev/null; then
    DOCKER_EXEC=(sudo docker)
    return 0
  fi
  if sudo docker ps &>/dev/null; then
    DOCKER_EXEC=(sudo docker)
    return 0
  fi
  DOCKER_EXEC=(docker)
  return 1
}

# Initialize DOCKER_COMPOSE and DOCKER_EXEC for repo root. Exports HAVE_DOCKER_COMPOSE.
init_docker_compose() {
  local root="${1:-${REPO_ROOT:-.}}"
  REPO_ROOT="$root"
  docker_compose_prefix "$root" || true
  docker_exec_prefix || true
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
  local -a dc=()
  if [[ "${#DOCKER_COMPOSE[@]}" -gt 0 ]]; then
    dc=("${DOCKER_COMPOSE[@]}")
  elif docker_compose_prefix "$root"; then
    dc=("${DOCKER_COMPOSE[@]}")
  fi
  if [[ "${#dc[@]}" -gt 0 ]]; then
    local id name
    id="$("${dc[@]}" ps -q "$service" 2>/dev/null | head -1)"
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
  if [[ "${#DOCKER_EXEC[@]}" -gt 0 ]]; then
    "${DOCKER_EXEC[@]}" exec "$c" "$@"
  else
    docker_cli exec "$c" "$@"
  fi
}
