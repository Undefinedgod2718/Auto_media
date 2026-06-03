#!/usr/bin/env bash
# Quick checks: gateway code has platform FSM; poll targets /telegram when GATEWAY_URL set.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a

ok=true
if ! grep -q 'send_platform_select' "$ROOT/scripts/hermes_telegram_gateway.py"; then
  echo "FAIL: hermes_telegram_gateway.py missing send_platform_select"
  ok=false
else
  echo "OK: platform FSM present in gateway"
fi

if [[ -n "${GATEWAY_URL:-}${GATEWAY_POLL_URL:-}" ]]; then
  base="$(bash "$ROOT/scripts/lib/gateway_url.sh" 2>/dev/null || true)"
  if [[ -n "$base" ]]; then
    echo "OK: Telegram poll/webhook should POST to ${base%/}/telegram"
  fi
else
  echo "WARN: GATEWAY_URL unset — poll may go directly to n8n (no platform buttons)"
fi

if curl -fsS "${GATEWAY_URL:-http://localhost:8787}/healthz" >/dev/null 2>&1; then
  echo "OK: gateway healthz"
else
  echo "WARN: gateway not reachable at ${GATEWAY_URL:-http://localhost:8787} — run: sudo docker compose up -d gateway"
fi

if curl -fsS "${GATEWAY_URL:-http://localhost:8787}/healthz" >/dev/null 2>&1; then
  echo "OK: gateway healthz"
else
  echo "WARN: gateway not reachable at ${GATEWAY_URL:-http://localhost:8787} — run: sudo docker compose up -d gateway"
fi

HAPPY_WF="$ROOT/workflows/auto-media-happy-path.json"
FWD_WF="$ROOT/workflows/auto-media-hitl-forwarder.json"
if [[ -f "$HAPPY_WF" ]]; then
  if grep -q 'publish-targets' "$HAPPY_WF" && grep -q 'IF Should generate carousel' "$HAPPY_WF"; then
    echo "OK: happy-path has publish-targets + carousel gate"
  else
    echo "FAIL: happy-path missing publish-targets or IF Should generate carousel — run patch_bprime_workflows.py"
    ok=false
  fi
  if grep -q 'Check should generate carousel' "$HAPPY_WF" && grep -q 'Parse should generate carousel' "$HAPPY_WF"; then
    echo "OK: happy-path uses script-based carousel gate"
  else
    echo "FAIL: happy-path missing Check/Parse should generate carousel nodes"
    ok=false
  fi
  if grep -q "require('fs')" "$HAPPY_WF" && grep -q 'IF Should generate carousel' "$HAPPY_WF"; then
    if python3 - "$HAPPY_WF" <<'PY'
import json, sys
wf = json.load(open(sys.argv[1], encoding="utf-8"))
for n in wf.get("nodes", []):
    if n.get("name") == "IF Should generate carousel":
        lv = n["parameters"]["conditions"]["conditions"][0].get("leftValue", "")
        if "require('fs')" in lv:
            raise SystemExit(1)
raise SystemExit(0)
PY
    then
      :
    else
      echo "FAIL: IF Should generate carousel still uses inline fs IIFE (expect script gate)"
      ok=false
    fi
  fi
  if grep -q 'Save wait resume URL (feedback-v1)' "$HAPPY_WF"; then
    echo "OK: happy-path saves feedback resume URL"
  else
    echo "FAIL: happy-path missing Save wait resume URL (feedback-v1)"
    ok=false
  fi
fi
if [[ -f "$FWD_WF" ]]; then
  if grep -q 'Read feedback resume map' "$FWD_WF" && grep -q 'Parse feedback resume map' "$FWD_WF"; then
    echo "OK: forwarder has feedback resume map chain"
  else
    echo "FAIL: forwarder missing feedback resume map nodes"
    ok=false
  fi
  if python3 - "$FWD_WF" <<'PY'
import json, sys
wf = json.load(open(sys.argv[1], encoding="utf-8"))
nodes = {n["name"]: n for n in wf.get("nodes", [])}
n = nodes.get("Resume Wait feedback-v1") or {}
params = n.get("parameters") or {}
if params.get("method") == "GET" and "resume_url" in str(params.get("url", "")):
    raise SystemExit(0)
raise SystemExit(1)
PY
  then
    echo "OK: forwarder Resume Wait feedback-v1 uses GET resume_url"
  else
    echo "FAIL: forwarder feedback resume is not GET dynamic URL"
    ok=false
  fi
fi

$ok && echo '{"ok":true}' || { echo '{"ok":false}'; exit 1; }
