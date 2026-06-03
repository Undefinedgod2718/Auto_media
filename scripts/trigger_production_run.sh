#!/usr/bin/env bash
# Trigger auto-media-happy-path via published Webhook Run (production execution).
# Do NOT use the editor "Execute workflow" button for HITL tests.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
source "$(dirname "${BASH_SOURCE[0]}")/lib/n8n_api_url.sh"

N8N_API_URL="$(n8n_api_url_resolve)"
WEBHOOK_PATH="${AUTO_MEDIA_RUN_WEBHOOK_PATH:-auto-media-run}"
BASE="${WEBHOOK_URL:-${N8N_API_URL}}"
BASE="${BASE%/}"

echo "POST ${BASE}/webhook/${WEBHOOK_PATH}"
resp="$(curl -sS -w '\nHTTP_CODE:%{http_code}' -X POST \
  "${BASE}/webhook/${WEBHOOK_PATH}" \
  -H "Content-Type: application/json" \
  -d '{}')"
code="${resp##*HTTP_CODE:}"
body="${resp%HTTP_CODE:*}"

echo "  HTTP ${code}"
echo "  ${body}"

if [[ "$code" != "200" && "$code" != "201" && "$code" != "202" ]]; then
  echo "ERROR: webhook trigger failed. Ensure workflow is Published + Active." >&2
  exit 1
fi

echo ""
echo "Next:"
echo "  1. Wait for Telegram HITL preview."
if [[ -z "${WEBHOOK_URL:-}" ]]; then
  echo "  2. bash scripts/telegram_poll_forwarder.sh   # forward Telegram callbacks"
else
  echo "  2. Telegram Trigger handles callbacks (WEBHOOK_URL set)."
fi
echo "  3. Click inline Approve / Revise / Reject."
echo "  4. bash scripts/check_telegram_hitl.sh"
