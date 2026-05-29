#!/usr/bin/env bash
# Capture n8n execution logs for debugging / n8n-mcp analysis.
# Usage:
#   ./scripts/capture_n8n_logs.sh --execution-id 35
#   ./scripts/capture_n8n_logs.sh --execution-id 35 --run-id 20260529-103449-35
#   ./scripts/capture_n8n_logs.sh --workflow auto-media-happy-path --limit 10
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT}/.env"
OUT_BASE="${ROOT}/data/logs/n8n-mcp"

load_env() {
  [[ -f "$ENV_FILE" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    [[ "$line" != *"="* ]] && continue
    local k="${line%%=*}" v="${line#*=}"
    v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
    export "$k=$v"
  done < "$ENV_FILE"
}

EXECUTION_ID=""
RUN_ID=""
WORKFLOW=""
LIMIT=5

while [[ $# -gt 0 ]]; do
  case "$1" in
    --execution-id) EXECUTION_ID="$2"; shift 2 ;;
    --run-id) RUN_ID="$2"; shift 2 ;;
    --workflow) WORKFLOW="$2"; shift 2 ;;
    --limit) LIMIT="$2"; shift 2 ;;
    --out) OUT_BASE="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,8p' "$0"
      exit 0
      ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

load_env
API_URL="${N8N_API_URL:-http://localhost:5678}"
API_URL="${API_URL%/}"
API_KEY="${N8N_API_KEY:-}"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
BUNDLE_DIR="${OUT_BASE}/capture-${TS}"
mkdir -p "$BUNDLE_DIR"

api_get() {
  local path="$1" out="$2"
  if [[ -z "$API_KEY" ]]; then
    echo '{"error":"N8N_API_KEY not set in .env"}' >"$out"
    return 1
  fi
  curl -fsS -m 30 \
    -H "X-N8N-API-KEY: ${API_KEY}" \
    -H "Accept: application/json" \
    "${API_URL}${path}" -o "$out"
}

manifest="$(mktemp)"
{
  echo "{"
  echo "  \"captured_at_utc\": \"${TS}\","
  echo "  \"api_url\": \"${API_URL}\","
  echo "  \"execution_id\": \"${EXECUTION_ID}\","
  echo "  \"run_id\": \"${RUN_ID}\","
  echo "  \"workflow\": \"${WORKFLOW}\","
  echo "  \"artifacts\": []"
  echo "}"
} >"$manifest"

if [[ -n "$EXECUTION_ID" ]]; then
  api_get "/api/v1/executions/${EXECUTION_ID}?includeData=true" \
    "${BUNDLE_DIR}/execution-${EXECUTION_ID}.json" || true
  if [[ -z "$RUN_ID" && -f "${BUNDLE_DIR}/execution-${EXECUTION_ID}.json" ]]; then
    RUN_ID="$(python3 - <<'PY' "${BUNDLE_DIR}/execution-${EXECUTION_ID}.json"
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
if not p.exists():
    sys.exit(0)
try:
    d = json.loads(p.read_text())
except Exception:
    sys.exit(0)
# run_id often appears in Set run context node output
data = d.get("data") or {}
run_data = (data.get("resultData") or {}).get("runData") or {}
for node_items in run_data.values():
    for run in node_items:
        for item in (run.get("data") or {}).get("main") or []:
            for row in item:
                j = row.get("json") or {}
                if j.get("run_id"):
                    print(j["run_id"])
                    raise SystemExit
except Exception:
    pass
PY
)"
  fi
  DEST="${BUNDLE_DIR}/execution-${EXECUTION_ID}"
  mkdir -p "$DEST"
  [[ -f "${BUNDLE_DIR}/execution-${EXECUTION_ID}.json" ]] && \
    mv "${BUNDLE_DIR}/execution-${EXECUTION_ID}.json" "${DEST}/n8n-execution.json"
fi

if [[ -n "$WORKFLOW" ]]; then
  api_get "/api/v1/executions?limit=${LIMIT}" "${BUNDLE_DIR}/executions-recent.json" || true
fi

if [[ -n "$RUN_ID" && -d "${ROOT}/data/runs/${RUN_ID}" ]]; then
  mkdir -p "${BUNDLE_DIR}/run-${RUN_ID}"
  cp -a "${ROOT}/data/runs/${RUN_ID}/." "${BUNDLE_DIR}/run-${RUN_ID}/"
  if [[ -f "${BUNDLE_DIR}/run-${RUN_ID}/hermes_assessment.json" ]]; then
    python3 - <<'PY' "${BUNDLE_DIR}/run-${RUN_ID}/hermes_assessment.json" \
      "${BUNDLE_DIR}/run-${RUN_ID}/hermes_prereview.stdout.json"
import json, sys
from pathlib import Path
assessment = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
Path(sys.argv[2]).write_text(
    json.dumps(assessment, ensure_ascii=False) + "\n",
    encoding="utf-8",
)
PY
  fi
fi

# Compact summary for MCP context window
python3 - <<'PY' "$BUNDLE_DIR" "$EXECUTION_ID" "$RUN_ID"
import json, sys
from pathlib import Path

bundle = Path(sys.argv[1])
exec_id, run_id = sys.argv[2], sys.argv[3]
summary = {
    "execution_id": exec_id or None,
    "run_id": run_id or None,
    "n8n_execution": None,
    "hermes_assessment": None,
    "run_files": [],
    "notes": [],
}

exec_path = bundle / f"execution-{exec_id}" / "n8n-execution.json" if exec_id else None
if exec_path and exec_path.exists():
    ex = json.loads(exec_path.read_text(encoding="utf-8"))
    rd = (ex.get("data") or {}).get("resultData") or {}
    summary["n8n_execution"] = {
        "id": ex.get("id"),
        "status": ex.get("status"),
        "startedAt": ex.get("startedAt"),
        "stoppedAt": ex.get("stoppedAt"),
        "lastNodeExecuted": rd.get("lastNodeExecuted"),
        "error": rd.get("error"),
        "nodes_executed": sorted((rd.get("runData") or {}).keys()),
    }

run_dir = bundle / f"run-{run_id}" if run_id else None
if run_dir and run_dir.is_dir():
    summary["run_files"] = sorted(p.name for p in run_dir.iterdir() if p.is_file())
    ha = run_dir / "hermes_assessment.json"
    if ha.exists():
        summary["hermes_assessment"] = json.loads(ha.read_text(encoding="utf-8"))

if exec_id and not (exec_path and exec_path.exists()):
    summary["notes"].append(
        "n8n API unreachable from this environment; bundle includes run artifacts only."
    )

(bundle / "summary.json").write_text(
    json.dumps(summary, ensure_ascii=False, indent=2) + "\n",
    encoding="utf-8",
)
print(bundle / "summary.json")
PY

chmod +x "${ROOT}/scripts/capture_n8n_logs.sh" 2>/dev/null || true
echo "Bundle: ${BUNDLE_DIR}"
echo "Summary: ${BUNDLE_DIR}/summary.json"
ls -la "${BUNDLE_DIR}"
