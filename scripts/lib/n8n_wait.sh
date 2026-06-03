#!/usr/bin/env bash
# Wait until n8n answers /healthz (post-restart). Source after n8n_api_url.sh is available.
# shellcheck disable=SC2034
wait_n8n_healthz() {
  local i resolved
  for i in $(seq 1 30); do
    if resolved="$(n8n_api_url_resolve_reachable 2>/dev/null)"; then
      printf '%s' "$resolved"
      return 0
    fi
    sleep 2
  done
  return 1
}
