#!/usr/bin/env bash
# Assert live n8n happy-path matches B-prime repo wiring (Gateway chain).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/n8n_api_url.sh"

N8N_API_URL="$(n8n_api_url_resolve)"
N8N_API_KEY="${N8N_API_KEY:-}"
WF_ID="${AUTO_MEDIA_HAPPY_PATH_ID:-auto-media-happy-path}"

[[ -n "$N8N_API_KEY" ]] || json_err "N8N_API_KEY required for live parity check"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
if ! curl -fsS -H "X-N8N-API-KEY: ${N8N_API_KEY}" "${N8N_API_URL}/api/v1/workflows/${WF_ID}" >"$tmp"; then
  json_err "cannot GET workflow from ${N8N_API_URL}"
fi

python3 - "$tmp" <<'PY'
import json, sys
wf = json.load(open(sys.argv[1], encoding="utf-8"))
conn = wf.get("connections", {})
nodes = {n["name"]: n for n in wf.get("nodes", [])}
errors = []

def targets(name):
    return {e.get("node") for e in conn.get(name, {}).get("main", [[]])[0]}

render_t = targets("Render PNG")
if "Save wait resume URL (stage1)" not in render_t:
    errors.append(f"Render PNG targets {render_t}, expected Save wait resume URL (stage1)")
if "Read post.png" in render_t or "Telegram HITL preview" in render_t:
    errors.append("Render PNG still wired to legacy Read/Telegram path")

for preview in ("Telegram HITL preview", "Telegram HITL preview (stage2)"):
    if preview in nodes and not nodes[preview].get("disabled"):
        errors.append(f"{preview} is not disabled")

if "Schedule Gateway prereview (stage1)" not in nodes:
    errors.append("missing Schedule Gateway prereview (stage1)")
else:
    save_t = targets("Save wait resume URL (stage1)")
    if "Schedule Gateway prereview (stage1)" not in save_t:
        errors.append(f"Save wait stage1 targets {save_t}")
    sched_t = targets("Schedule Gateway prereview (stage1)")
    if "Wait for approval (stage1)" not in sched_t:
        errors.append(f"Schedule Gateway stage1 targets {sched_t}")

rerun_t = targets("Rerun render PNG")
if "Save wait resume URL (stage2)" not in rerun_t:
    errors.append(f"Rerun render PNG targets {rerun_t}, expected Save wait resume URL (stage2)")

if errors:
    for e in errors:
        print(f"FAIL: {e}", file=sys.stderr)
    sys.exit(1)
print("ok live workflow B-prime parity")
PY

json_ok "verify_workflow_live_parity"
