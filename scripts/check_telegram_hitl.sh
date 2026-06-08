#!/usr/bin/env bash
# Diagnose Telegram HITL receive path: Bot API webhook + n8n forwarder + Wait webhooks.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/common.sh" 2>/dev/null || true

load_env() {
  local f="$ROOT/.env"
  [[ -f "$f" ]] || return 0
  set -a
  # shellcheck disable=SC1090
  source "$f"
  set +a
}

load_env

: "${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN missing in .env}"
# Resolve n8n base via the shared helper so Dev Container reaches host Docker
# (N8N_SYNC_API_URL / host.docker.internal) instead of an unreachable localhost.
# shellcheck source=scripts/lib/n8n_api_url.sh
source "$ROOT/scripts/lib/n8n_api_url.sh"
N8N_API_URL="$(n8n_api_url_resolve)"
: "${N8N_API_KEY:=}"

echo "=== 1. Telegram Bot API ==="
me="$(curl -fsS "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getMe")"
echo "$me" | python3 -c "import sys,json; d=json.load(sys.stdin); r=d.get('result',{}); print('  bot:', r.get('username'), '| ok:', d.get('ok'))"

wh="$(curl -fsS "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getWebhookInfo")"
echo "$wh" | python3 -c "
import sys, json
d = json.load(sys.stdin).get('result', {})
print('  webhook url:', repr(d.get('url') or '(empty — no push to n8n)'))
print('  pending updates:', d.get('pending_update_count'))
print('  allowed_updates:', d.get('allowed_updates'))
"

echo ""
echo "=== 2. Recent updates (getUpdates; only when webhook url is empty) ==="
upd="$(curl -fsS "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates?limit=8")"
echo "$upd" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for u in d.get('result', [])[-5:]:
    uid = u.get('update_id')
    if u.get('callback_query'):
        print(f'  [{uid}] callback_query data={u[\"callback_query\"].get(\"data\")!r}')
    elif u.get('message'):
        m = u['message']
        print(f'  [{uid}] message text={m.get(\"text\")!r} reply_to={bool(m.get(\"reply_to_message\"))}')
    else:
        print(f'  [{uid}] other keys={list(u.keys())}')
"

if [[ -n "$N8N_API_KEY" ]]; then
  echo ""
  echo "=== 3. n8n workflows (API) ==="
  curl -fsS -H "X-N8N-API-KEY: $N8N_API_KEY" "${N8N_API_URL}/api/v1/workflows" | python3 -c "
import sys, json
data = json.load(sys.stdin).get('data', json.load(sys.stdin) if False else [])
for w in data:
    if 'auto-media' in w.get('name',''):
        print(f\"  {w['name']}: active={w.get('active')}\")
"

  echo ""
  echo "=== 4. Waiting executions (Wait node must be paused) ==="
  curl -fsS -H "X-N8N-API-KEY: $N8N_API_KEY" "${N8N_API_URL}/api/v1/executions?status=waiting&limit=5" | python3 -c "
import sys, json
rows = json.load(sys.stdin).get('data', [])
if not rows:
    print('  (none) — forwarder has nothing to resume')
else:
    for e in rows:
        print(f\"  execution #{e['id']} workflow={e.get('workflowId')} started={e.get('startedAt')}\")
"

  echo ""
  echo "=== 5. Forwarder recent runs ==="
  curl -fsS -H "X-N8N-API-KEY: $N8N_API_KEY" "${N8N_API_URL}/api/v1/executions?workflowId=auto-media-hitl-forwarder&limit=3" | python3 -c "
import sys, json
rows = json.load(sys.stdin).get('data', [])
if not rows:
    print('  (none) — forwarder never received Telegram events via n8n')
else:
    for e in rows:
        print(f\"  #{e['id']} status={e.get('status')} at {e.get('startedAt')}\")
"
else
  echo ""
  echo "=== 3–5. Skipped (N8N_API_KEY not set) ==="
fi

echo ""
echo "=== 6. Env ==="
echo "  WEBHOOK_URL=${WEBHOOK_URL:-(empty — forwarder resume URL will use localhost)}"

echo ""
echo "=== Verdict ==="
echo "  • Telegram CAN emit callback_query (see getUpdates)."
echo "  • n8n receives ONLY if: auto-media-hitl-forwarder is Active AND webhook url points to n8n."
echo "  • Plain text 'Approve' is NOT a callback — use Inline Keyboard buttons."
echo "  • Wait webhooks work only while main workflow is paused on Wait for approval."
