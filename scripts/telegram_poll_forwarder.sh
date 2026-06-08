#!/usr/bin/env bash
# Local dev: poll Telegram getUpdates and POST to n8n Webhook Telegram IN.
# Use when Telegram Trigger cannot register HTTPS webhook (localhost).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a

: "${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN missing}"
source "$(dirname "${BASH_SOURCE[0]}")/lib/gateway_url.sh"

GATEWAY_BASE=""
if [[ -n "${GATEWAY_URL:-}" ]] || [[ -n "${GATEWAY_POLL_URL:-}" ]]; then
  GATEWAY_BASE="$(gateway_url_resolve)"
fi
if [[ -n "$GATEWAY_BASE" ]]; then
  # Gateway endpoint is /telegram (not /webhook/...); requires the secret header.
  TARGET_URL="${GATEWAY_BASE%/}/telegram"
  TG_SECRET="${TELEGRAM_WEBHOOK_SECRET:-}"
else
  N8N_BASE="${N8N_WEBHOOK_BASE:-http://localhost:5678}"
  WEBHOOK_PATH="${TELEGRAM_IN_WEBHOOK_PATH:-auto-media-telegram-in}"
  TARGET_URL="${N8N_BASE%/}/webhook/${WEBHOOK_PATH}"
  TG_SECRET=""
fi
OFFSET_FILE="${ROOT}/data/hitl/telegram_poll_offset.txt"
mkdir -p "$(dirname "$OFFSET_FILE")"

offset=""
if [[ -f "$OFFSET_FILE" ]]; then
  offset="$(tr -d '\r\n' < "$OFFSET_FILE")"
fi

# Long-poll: getUpdates blocks up to TELEGRAM_LONGPOLL_TIMEOUT s waiting for an
# update, so the loop spawns curl/python far less often than short-poll (timeout=0)
# — lower CPU/memory churn, lower latency. curl --max-time must exceed it.
LONGPOLL="${TELEGRAM_LONGPOLL_TIMEOUT:-25}"
query="limit=20&timeout=${LONGPOLL}&allowed_updates[]=callback_query&allowed_updates[]=message"
[[ -n "$offset" ]] && query="${query}&offset=${offset}"

resp="$(curl -fsS --max-time "$((LONGPOLL + 10))" "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates?${query}")"
count="$(echo "$resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('result',[])))")"
[[ "$count" == "0" ]] && { echo "No new Telegram updates."; exit 0; }

RESPONSE="$resp" python3 - "$TARGET_URL" "$TG_SECRET" "$OFFSET_FILE" <<'PY'
import json, os, sys, urllib.request, urllib.error

data = json.loads(os.environ["RESPONSE"])
url, tg_secret, offset_file = sys.argv[1:4]
headers = {"Content-Type": "application/json"}
if tg_secret:
    headers["X-Telegram-Bot-Api-Secret-Token"] = tg_secret
max_id = 0
for u in data.get("result", []):
    max_id = max(max_id, u.get("update_id", 0))
    body = json.dumps(u).encode()
    req = urllib.request.Request(url, data=body, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            print(f"update {u.get('update_id')}: forwarded -> HTTP {r.status}")
    except urllib.error.HTTPError as e:
        print(f"update {u.get('update_id')}: HTTP {e.code} {e.read().decode(errors='replace')[:200]}")

if max_id:
    with open(offset_file, "w", encoding="utf-8", newline="\n") as f:
        f.write(str(max_id + 1))
    print(f"Next offset: {max_id + 1}")
PY
