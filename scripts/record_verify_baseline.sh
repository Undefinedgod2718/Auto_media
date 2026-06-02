#!/usr/bin/env bash
# Record verify baseline/follow-up to data/logs/verify_exec85_followup.json
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/n8n_api_url.sh"

PHASE="${1:-baseline}"
RUN_ID="${2:-20260601-092711-9d5f53c2}"
OUT="${DATA_ROOT}/logs/verify_exec85_followup.json"
mkdir -p "$(dirname "$OUT")"

export N8N_API_URL="$(n8n_api_url_resolve)"
claude_out="$(bash "${REPO_ROOT}/scripts/verify_n8n_claude_engine.sh" 2>&1 || true)"
parity_out="$(bash "${REPO_ROOT}/scripts/verify_workflow_live_parity.sh" 2>&1 || true)"
gw_out="$(bash "${REPO_ROOT}/scripts/verify_gateway_exclusive_preview.sh" 2>&1 || true)"
mount_out=""
if [[ -n "${RUN_ID}" ]] && command -v docker >/dev/null 2>&1; then
  mount_out="$(bash "${REPO_ROOT}/scripts/verify_runs_mount_parity.sh" "${RUN_ID}" 2>&1 || true)"
fi

claude_engine_ok="unknown"
if echo "$claude_out" | grep -q '"claude_engine_ok":true'; then
  claude_engine_ok="true"
elif echo "$claude_out" | grep -q '"claude_engine_ok":false'; then
  claude_engine_ok="false"
fi

provider_used=""
if [[ -f "${DATA_ROOT}/logs/engine_failover.jsonl" ]]; then
  provider_used="$(grep "\"run_id\": \"${RUN_ID}\"" "${DATA_ROOT}/logs/engine_failover.jsonl" 2>/dev/null | tail -3 | tr '\n' ';' || true)"
fi
if [[ -z "$provider_used" ]] && command -v docker >/dev/null 2>&1; then
  provider_used="$(sudo docker exec auto_media-n8n-1 sh -c "grep '${RUN_ID}' /data/logs/engine_failover.jsonl 2>/dev/null | tail -3" 2>/dev/null | tr '\n' ';' || true)"
fi

host_files=""
if [[ -d "${DATA_ROOT}/runs/${RUN_ID}" ]]; then
  host_files="$(ls -1 "${DATA_ROOT}/runs/${RUN_ID}" 2>/dev/null | tr '\n' ',' | sed 's/,$//')"
fi
container_files=""
if command -v docker >/dev/null 2>&1; then
  container_files="$(sudo docker exec auto_media-n8n-1 ls -1 "/data/runs/${RUN_ID}" 2>/dev/null | tr '\n' ',' | sed 's/,$//' || true)"
fi

post_polluted=""
if [[ -f "${DATA_ROOT}/runs/${RUN_ID}/post.md" ]]; then
  if head -3 "${DATA_ROOT}/runs/${RUN_ID}/post.md" | grep -qi 'I have completed the copywriting'; then
    post_polluted="true"
  else
    post_polluted="false"
  fi
fi

python3 - "$OUT" "$PHASE" "$RUN_ID" "$claude_out" "$parity_out" "$gw_out" "$mount_out" "$host_files" "$container_files" "$post_polluted" "$claude_engine_ok" "$provider_used" <<'PY'
import json, sys
from datetime import datetime, timezone
out, phase, run_id = sys.argv[1:4]
claude, parity, gw, mount, host_f, cont_f, polluted, claude_ok, providers = sys.argv[4:14]
row = {
    "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "phase": phase,
    "run_id": run_id,
    "claude_engine_ok": claude_ok,
    "claude_check_detail": claude.strip()[-400:],
    "parity_check": "pass" if "ok live" in parity or "ok repo" in parity else "fail",
    "parity_detail": parity.strip()[-500:],
    "gateway_exclusive": "pass" if '"ok":true' in gw else "fail",
    "mount_parity": "pass" if '"ok": true' in mount or '"ok":true' in mount else ("skip" if not mount.strip() else "fail"),
    "mount_detail": mount.strip()[-400:],
    "host_run_files": host_f,
    "container_run_files": cont_f,
    "post_md_polluted": polluted or "unknown",
    "engine_failover_tail": providers[:800],
}
path = out
try:
    data = json.loads(open(path, encoding="utf-8").read()) if open(path).read() else []
except (FileNotFoundError, json.JSONDecodeError):
    data = []
if not isinstance(data, list):
    data = [data]
data.append(row)
open(path, "w", encoding="utf-8").write(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
print(json.dumps(row, ensure_ascii=False))
PY
