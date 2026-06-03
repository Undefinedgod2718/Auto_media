#!/usr/bin/env bash
# Gateway exclusivity: setWebhook to Gateway, disable n8n Telegram Trigger nodes.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/n8n_api_url.sh"

: "${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN missing}"
: "${TELEGRAM_WEBHOOK_SECRET:?TELEGRAM_WEBHOOK_SECRET missing (1-256 chars; must match Gateway env)}"
GATEWAY_PUBLIC_URL="${GATEWAY_PUBLIC_URL:-${GATEWAY_URL:-http://localhost:8787}}"
N8N_API_URL="$(n8n_api_url_resolve)"
N8N_API_KEY="${N8N_API_KEY:-}"

echo "=== enforce_telegram_gateway ==="

curl -fsS "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/deleteWebhook?drop_pending_updates=false" >/dev/null || true
webhook_url="${GATEWAY_PUBLIC_URL%/}/telegram"
if [[ "$webhook_url" =~ ^https:// ]]; then
  set_wh="$(curl -fsS -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/setWebhook" \
    --data-urlencode "url=${webhook_url}" \
    --data-urlencode "secret_token=${TELEGRAM_WEBHOOK_SECRET}")"
  echo "$set_wh" | python3 -c "import json,sys; d=json.load(sys.stdin); print('  setWebhook ok:', d.get('ok'))"
else
  echo "  skip setWebhook (dev: ${webhook_url} is not https — use bash scripts/telegram_poll_forwarder.sh)"
fi

if [[ -n "$N8N_API_KEY" ]]; then
  bash "${REPO_ROOT}/scripts/verify_n8n_node_disable.sh" || echo "  warn: verify_n8n_node_disable failed" >&2
  for wf in auto-media-hitl-forwarder auto-media-happy-path; do
    tmp_in="$(mktemp)"
    tmp_out="$(mktemp)"
    curl -fsS -H "X-N8N-API-KEY: ${N8N_API_KEY}" "${N8N_API_URL}/api/v1/workflows/${wf}" >"$tmp_in" || continue
    python3 - "$tmp_in" >"$tmp_out" <<'PY'
import json, sys
wf = json.load(open(sys.argv[1], encoding="utf-8"))
preview_nodes = {"Telegram HITL preview", "Telegram HITL preview (stage2)"}
node_names = {n.get("name") for n in wf.get("nodes", [])}
for n in wf.get("nodes", []):
    if n.get("type") == "n8n-nodes-base.telegramTrigger":
        n["disabled"] = True
    if preview_nodes & node_names and n.get("name") in preview_nodes:
        n["disabled"] = True
settings = {"executionOrder": wf.get("settings", {}).get("executionOrder", "v1")}
print(json.dumps({"name": wf["name"], "nodes": wf["nodes"], "connections": wf["connections"], "settings": settings}, ensure_ascii=False))
PY
    curl -fsS -X PUT "${N8N_API_URL}/api/v1/workflows/${wf}" \
      -H "X-N8N-API-KEY: ${N8N_API_KEY}" -H "Content-Type: application/json" -d @"$tmp_out" >/dev/null
    rm -f "$tmp_in" "$tmp_out"
    echo "  disabled telegramTrigger in ${wf}"
  done
else
  echo "  skip n8n API (N8N_API_KEY empty)"
fi

json_ok "enforce_telegram_gateway"
