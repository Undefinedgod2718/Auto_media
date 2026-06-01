#!/usr/bin/env bash
# Verify n8n REST API honors node.disabled on workflow PUT (pin n8n 2.21.7).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

N8N_API_URL="${N8N_API_URL:-http://localhost:5678}"
N8N_API_KEY="${N8N_API_KEY:-}"
WF_ID="${AUTO_MEDIA_FORWARDER_ID:-auto-media-hitl-forwarder}"

[[ -n "$N8N_API_KEY" ]] || json_err "N8N_API_KEY required"

tmp_in="$(mktemp)"
tmp_out="$(mktemp)"
curl -fsS -H "X-N8N-API-KEY: ${N8N_API_KEY}" "${N8N_API_URL}/api/v1/workflows/${WF_ID}" >"$tmp_in"
python3 - "$tmp_in" >"$tmp_out" <<'PY'
import json, sys
wf = json.load(open(sys.argv[1], encoding="utf-8"))
for n in wf.get("nodes", []):
    if n.get("name") == "Telegram Trigger":
        n["disabled"] = True
        break
else:
    raise SystemExit("Telegram Trigger node not found")
settings = {"executionOrder": wf.get("settings", {}).get("executionOrder", "v1")}
print(json.dumps({"name": wf["name"], "nodes": wf["nodes"], "connections": wf["connections"], "settings": settings}, ensure_ascii=False))
PY
curl -fsS -X PUT "${N8N_API_URL}/api/v1/workflows/${WF_ID}" \
  -H "X-N8N-API-KEY: ${N8N_API_KEY}" -H "Content-Type: application/json" -d @"$tmp_out" >/dev/null

got="$(curl -fsS -H "X-N8N-API-KEY: ${N8N_API_KEY}" "${N8N_API_URL}/api/v1/workflows/${WF_ID}" | python3 -c "
import json,sys
wf=json.load(sys.stdin)
for n in wf.get('nodes',[]):
  if n.get('name')=='Telegram Trigger':
    print('true' if n.get('disabled') else 'false')
    break
else:
  print('missing')
")"
rm -f "$tmp_in" "$tmp_out"

if [[ "$got" != "true" ]]; then
  json_err "node.disabled not persisted (got: $got)"
fi
json_ok "verify_n8n_node_disable"
