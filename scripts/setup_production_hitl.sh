#!/usr/bin/env bash
# Configure HITL for production (HTTPS WEBHOOK_URL) or document dev poll fallback.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a

: "${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN missing}"
: "${N8N_API_URL:=http://localhost:5678}"
: "${N8N_API_KEY:=}"

FWD_ID="${AUTO_MEDIA_FORWARDER_ID:-auto-media-hitl-forwarder}"
HAPPY_ID="${AUTO_MEDIA_WORKFLOW_ID:-auto-media-happy-path}"

api() {
  curl -fsS -H "X-N8N-API-KEY: ${N8N_API_KEY}" -H "Content-Type: application/json" "$@"
}

patch_forwarder_telegram_trigger() {
  local disabled_flag="$1"
  [[ -n "$N8N_API_KEY" ]] || { echo "Skip n8n API (N8N_API_KEY empty)"; return 0; }
  local wf tmp
  wf="$(api "${N8N_API_URL}/api/v1/workflows/${FWD_ID}")"
  tmp="$(mktemp)"
  echo "$wf" | python3 - "$disabled_flag" >"$tmp" <<'PY'
import json, sys
disabled = sys.argv[1].lower() == 'true'
wf = json.load(sys.stdin)
for n in wf.get("nodes", []):
    if n.get("name") == "Telegram Trigger":
        n["disabled"] = disabled
settings = {"executionOrder": wf.get("settings", {}).get("executionOrder", "v1")}
out = {"name": wf["name"], "nodes": wf["nodes"], "connections": wf["connections"], "settings": settings}
print(json.dumps(out))
PY
  api -X PUT "${N8N_API_URL}/api/v1/workflows/${FWD_ID}" -d @"$tmp" >/dev/null
  rm -f "$tmp"
  echo "  forwarder Telegram Trigger disabled=${disabled_flag}"
}

echo "=== Auto Media HITL production setup ==="
echo ""

if [[ -n "${WEBHOOK_URL:-}" ]]; then
  base="${WEBHOOK_URL%/}"
  echo "Mode: PRODUCTION (WEBHOOK_URL=${base})"
  echo ""
  echo "1. Enable Telegram Trigger on forwarder (disable Webhook IN is optional)."
  patch_forwarder_telegram_trigger "false"
  echo ""
  echo "2. In n8n UI: Publish auto-media-hitl-forwarder, then Activate."
  echo "   n8n will register Telegram webhook on activate."
  echo ""
  echo "3. Ensure auto-media-happy-path is Published + Active (Schedule Trigger)."
  echo ""
  echo "4. Trigger a run (production execution, NOT editor Execute):"
  echo "   bash scripts/trigger_production_run.sh"
  echo ""
  echo "5. Verify:"
  echo "   bash scripts/check_telegram_hitl.sh"
else
  echo "Mode: LOCAL DEV (WEBHOOK_URL empty)"
  echo ""
  echo "Production Wait resume requires a PRODUCTION execution:"
  echo "  • Use Schedule Trigger or: bash scripts/trigger_production_run.sh"
  echo "  • Do NOT use editor 'Execute workflow' for HITL tests"
  echo ""
  echo "Telegram ingress (no HTTPS):"
  patch_forwarder_telegram_trigger "true"
  echo "  • Publish forwarder (Webhook Telegram IN path: auto-media-telegram-in)"
  echo "  • Run poll bridge while testing:"
  echo "    bash scripts/telegram_poll_forwarder.sh"
  echo ""
  echo "Before go-live, set WEBHOOK_URL=https://your-domain and re-run this script."
fi

echo ""
echo "=== Telegram Bot (optional manual webhook clear for poll mode) ==="
if [[ -z "${WEBHOOK_URL:-}" ]]; then
  curl -fsS "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/deleteWebhook?drop_pending_updates=false" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print('  deleteWebhook ok:', d.get('ok'))"
else
  echo "  (skipped — WEBHOOK_URL set; n8n Telegram Trigger owns webhook on activate)"
fi
