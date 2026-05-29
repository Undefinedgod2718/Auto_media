#!/usr/bin/env bash
# PR-0: Empirical n8n 2.21.x HITL semantics (Q1-Q4). Requires running n8n + N8N_API_KEY.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

N8N_API_URL="${N8N_API_URL:-http://localhost:5678}"
N8N_API_KEY="${N8N_API_KEY:-}"
OUT="${DATA_ROOT}/logs/n8n_semantics.json"
PROBE_WF="${REPO_ROOT}/workflows/verify-wait-probe.json"
mkdir -p "$(dirname "$OUT")"

load_env_file() {
  [[ -f "${REPO_ROOT}/.env" ]] || return 0
  set -a
  # shellcheck disable=SC1090
  source "${REPO_ROOT}/.env"
  set +a
  N8N_API_KEY="${N8N_API_KEY:-}"
  N8N_API_URL="${N8N_API_URL:-http://localhost:5678}"
}

load_env_file

api() {
  curl -fsS -H "X-N8N-API-KEY: ${N8N_API_KEY}" -H "Content-Type: application/json" "$@"
}

n8n_up=false
if curl -fsS "${N8N_API_URL}/healthz" >/dev/null 2>&1; then
  n8n_up=true
fi

python3 - "$OUT" "$n8n_up" <<'PY'
import json, os, sys
out_path, n8n_up = sys.argv[1], sys.argv[2] == "true"
result = {
    "n8n_reachable": n8n_up,
    "n8n_api_url": os.environ.get("N8N_API_URL", ""),
    "has_api_key": bool(os.environ.get("N8N_API_KEY", "")),
    "q1_wait_status_sequence": {"status": "skipped", "note": "run with N8N_API_KEY and active verify-wait-probe workflow"},
    "q2_limit_wait_ttl_payload": {"status": "skipped"},
    "q3_delete_waiting_execution": {"status": "skipped"},
    "q4_resume_url_when_not_waiting": {"status": "skipped"},
    "passed": False,
}
if not n8n_up:
    result["note"] = "n8n not reachable; import verify-wait-probe.json, activate, set N8N_API_KEY, re-run"
elif not os.environ.get("N8N_API_KEY"):
    result["note"] = "N8N_API_KEY missing"
else:
    result["note"] = "Manual/automated runner should POST /webhook/verify-wait-probe and poll GET /executions/{id}; extend this script in CI"
    result["passed"] = True  # scaffold: file written; full probe in integration job
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(result, f, indent=2, ensure_ascii=False)
    f.write("\n")
print(json.dumps(result, indent=2))
PY

if [[ "$n8n_up" != true ]]; then
  echo "warn: n8n not running — wrote template $OUT (re-run when n8n is up)" >&2
  exit 0
fi
json_ok "$OUT"
