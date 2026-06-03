#!/usr/bin/env bash
# One-shot production stack: verify gates → compose up (n8n + gateway).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a

cd "$ROOT"
DC=(docker compose)
[[ -S /var/run/docker.sock ]] || DC=(sudo docker compose)

"${DC[@]}" up -d n8n gateway

export VERIFY_CLAUDE_STRICT="${VERIFY_CLAUDE_STRICT:-1}"
bash "$ROOT/scripts/ensure_n8n_oauth.sh" || {
  echo "OAuth inject failed. Fix: sync_*_oauth.sh → inject_n8n_secrets.sh" >&2
  exit 1
}
bash "$ROOT/scripts/verify_n8n_claude_engine.sh" || {
  echo "Claude engine check failed. Fix: sync_claude_oauth.sh → ensure_n8n_oauth.sh → docker compose restart n8n" >&2
  exit 1
}
bash "$ROOT/scripts/verify_workflow_live_parity.sh"
bash "$ROOT/scripts/verify_gateway_exclusive_preview.sh"
RUN_ID="${1:-}"
if [[ -n "$RUN_ID" ]]; then
  GATEWAY_CONTAINER="${GATEWAY_CONTAINER:-auto_media-gateway-1}" bash "$ROOT/scripts/verify_runs_mount_parity.sh" "$RUN_ID"
fi
echo '{"ok":true,"hint":"Run: bash scripts/telegram_poll_forwarder.sh (dev) or HTTPS setWebhook"}'
