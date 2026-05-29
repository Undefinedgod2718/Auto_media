#!/usr/bin/env bash
# Local dev: poll Telegram getUpdates and POST to n8n Webhook Telegram IN.
# Use when Telegram Trigger cannot register HTTPS webhook (localhost).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a

: "${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN missing}"
GATEWAY_BASE="${GATEWAY_URL:-}"
if [[ -n "$GATEWAY_BASE" ]]; then
  N8N_BASE="${GATEWAY_BASE%/}"
  WEBHOOK_PATH="${TELEGRAM_IN_WEBHOOK_PATH:-telegram}"
else
  N8N_BASE="${N8N_WEBHOOK_BASE:-http://localhost:5678}"
  WEBHOOK_PATH="${TELEGRAM_IN_WEBHOOK_PATH:-auto-media-telegram-in}"
fi
OFFSET_FILE="${ROOT}/data/hitl/telegram_poll_offset.txt"
mkdir -p "$(dirname "$OFFSET_FILE")"

offset=""
[[ -f "$OFFSET_FILE" ]] && offset="$(cat "$OFFSET_FILE")"

query="limit=20&timeout=0&allowed_updates[]=callback_query&allowed_updates[]=message"
[[ -n "$offset" ]] && query="${query}&offset=${offset}"

resp="$(curl -fsS "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates?${query}")"
count="$(echo "$resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('result',[])))")"
[[ "$count" == "0" ]] && { echo "No new Telegram updates."; exit 0; }

echo "$resp" | python3 - "$N8N_BASE" "$WEBHOOK_PATH" "$OFFSET_FILE" <<'PY'
import json, sys, urllib.request

data = json.load(sys.stdin)
base, path, offset_file = sys.argv[1:4]
url = f"{base.rstrip('/')}/webhook/{path}"
max_id = 0
for u in data.get("result", []):
    max_id = max(max_id, u.get("update_id", 0))
    body = json.dumps(u).encode()
    req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            print(f"update {u.get('update_id')}: forwarded -> HTTP {r.status}")
    except urllib.error.HTTPError as e:
        print(f"update {u.get('update_id')}: HTTP {e.code} {e.read().decode(errors='replace')[:200]}")

if max_id:
    with open(offset_file, "w") as f:
        f.write(str(max_id + 1))
    print(f"Next offset: {max_id + 1}")
PY
