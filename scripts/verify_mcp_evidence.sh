#!/usr/bin/env bash
# Evidence-based MCP bridge checks (automedia, Hermes mcp.json, n8n reachability, dashboard).
# See docs/MCP_AUTOMEDIA.md § Empirical verification and docs/N8N_MCP.md.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail() { echo "verify_mcp_evidence: FAIL — $*" >&2; exit 1; }
ok() { echo "verify_mcp_evidence: $*"; }

[[ -f "$ROOT/scripts/mcp_automedia.py" ]] || fail "missing scripts/mcp_automedia.py"

# E2: automedia MCP stdio smoke (initialize)
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{}}}' |
  AUTO_MEDIA_ROOT="$ROOT" DATA_ROOT="$ROOT/data" AUTO_MEDIA_MCP_WRITE=0 \
  python3 "$ROOT/scripts/mcp_automedia.py" |
  python3 -c 'import sys,json; d=json.loads(sys.stdin.readline()); assert d.get("result"), d; print("  E2a initialize: PASS")'

# E1: Hermes mcp.json must use repo paths (from amctl apply), not container /data/scripts
HERMES_MCP="$ROOT/config/hermes/mcp.json"
[[ -f "$HERMES_MCP" ]] || fail "missing config/hermes/mcp.json — run amctl apply"
python3 - <<PY || fail "Hermes mcp.json still uses container /data paths"
import json
from pathlib import Path
p = json.loads(Path("$HERMES_MCP").read_text())
auto = p["mcpServers"]["automedia"]
arg0 = auto["args"][0]
env = auto["env"]
assert "/data/scripts/mcp_automedia.py" not in arg0, arg0
assert env["AUTO_MEDIA_ROOT"] != "/data", env["AUTO_MEDIA_ROOT"]
assert env["DATA_ROOT"].endswith("/data"), env["DATA_ROOT"]
assert Path(arg0).is_file(), arg0
print("  E1 Hermes automedia paths: PASS")
PY

# E3: n8n healthz via same resolution as scripts
# shellcheck source=scripts/lib/n8n_api_url.sh
source "$ROOT/scripts/lib/n8n_api_url.sh"
resolved="$(n8n_api_url_resolve_reachable)" || fail "n8n unreachable (E3d)"
BASE="${resolved%%|*}"
SOURCE="${resolved##*|}"
curl -fsS "${BASE%/}/healthz" >/dev/null || fail "n8n healthz at $BASE"
ok "E3 n8n healthz at $BASE (source=$SOURCE)"

if [[ -f "$ROOT/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT/.env"
  set +a
fi
if [[ -n "${N8N_API_KEY:-}" ]]; then
  code="$(curl -s -o /dev/null -w "%{http_code}" -H "X-N8N-API-KEY: ${N8N_API_KEY}" \
    "${BASE%/}/api/v1/workflows?limit=1" || echo 000)"
  [[ "$code" == "200" ]] || fail "n8n workflows API HTTP $code (E3e)"
  ok "E3e n8n REST with N8N_API_KEY: PASS"
else
  echo "verify_mcp_evidence: WARN — N8N_API_KEY unset (E3e skipped; set in .env for full n8n-mcp)"
fi

# E4: dashboard (non-MCP)
code="$(curl -s -o /dev/null -w "%{http_code}" --max-time 2 http://127.0.0.1:8790/healthz 2>/dev/null || echo 000)"
if [[ "$code" == "200" ]]; then
  ok "E4 dashboard :8790 healthz: PASS"
else
  echo "verify_mcp_evidence: WARN — dashboard not on :8790 (E4 skipped; run open_user_ui.sh)"
fi

# Host-only gap marker (informational on devcontainer)
if [[ -f /data/scripts/mcp_automedia.py ]]; then
  echo "verify_mcp_evidence: NOTE — /data/scripts exists (container layout); Hermes uses repo paths"
else
  echo "verify_mcp_evidence: NOTE — /data/scripts absent on host (expected in devcontainer)"
fi

ok "OK"
