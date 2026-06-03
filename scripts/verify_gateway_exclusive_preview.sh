#!/usr/bin/env bash
# Assert happy-path Telegram HITL preview nodes are disabled and Render PNG uses Gateway chain.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/n8n_api_url.sh"

N8N_API_URL="$(n8n_api_url_resolve)"
N8N_API_KEY="${N8N_API_KEY:-}"
WF_ID="${AUTO_MEDIA_HAPPY_PATH_ID:-auto-media-happy-path}"

if [[ -z "$N8N_API_KEY" ]]; then
  REPO_WF="${REPO_ROOT}/workflows/auto-media-happy-path.json"
  [[ -f "$REPO_WF" ]] || json_err "workflow file missing: $REPO_WF"
  python3 - "$REPO_WF" <<'PY'
import json, sys
wf = json.load(open(sys.argv[1], encoding="utf-8"))
preview = {"Telegram HITL preview", "Telegram HITL preview (stage2)"}
for n in wf.get("nodes", []):
    if n.get("name") in preview and not n.get("disabled"):
        raise SystemExit(f"node not disabled: {n['name']}")
conn = wf.get("connections", {})
render = conn.get("Render PNG", {}).get("main", [[]])[0]
targets = {e.get("node") for e in render}
if "Telegram HITL preview" in targets:
    raise SystemExit("Render PNG still connects to Telegram HITL preview")
if "Save wait resume URL (stage1)" not in targets:
    raise SystemExit("Render PNG must connect to Save wait resume URL (stage1)")
rerun = conn.get("Rerun render PNG", {}).get("main", [[]])[0]
rt = {e.get("node") for e in rerun}
if "Save wait resume URL (stage2)" not in rt:
    raise SystemExit("Rerun render PNG must connect to Save wait resume URL (stage2)")
print("ok repo workflow gateway-exclusive preview")
PY
  json_ok "verify_gateway_exclusive_preview (repo)"
  exit 0
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
curl -fsS -H "X-N8N-API-KEY: ${N8N_API_KEY}" "${N8N_API_URL}/api/v1/workflows/${WF_ID}" >"$tmp"
python3 - "$tmp" <<'PY'
import json, sys
wf = json.load(open(sys.argv[1], encoding="utf-8"))
preview = {"Telegram HITL preview", "Telegram HITL preview (stage2)"}
for n in wf.get("nodes", []):
    if n.get("name") in preview:
        if not n.get("disabled"):
            raise SystemExit(f"node not disabled: {n['name']}")
conn = wf.get("connections", {})
render = conn.get("Render PNG", {}).get("main", [[]])[0]
targets = {e.get("node") for e in render}
if "Telegram HITL preview" in targets:
    raise SystemExit("Render PNG still connects to Telegram HITL preview")
if "Save wait resume URL (stage1)" not in targets:
    raise SystemExit("Render PNG must connect to Save wait resume URL (stage1)")
rerun = conn.get("Rerun render PNG", {}).get("main", [[]])[0]
rt = {e.get("node") for e in rerun}
if "Save wait resume URL (stage2)" not in rt:
    raise SystemExit("Rerun render PNG must connect to Save wait resume URL (stage2)")
print("ok live workflow gateway-exclusive preview")
PY
json_ok "verify_gateway_exclusive_preview"
