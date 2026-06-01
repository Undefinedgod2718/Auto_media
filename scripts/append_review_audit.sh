#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

RUN_ID=""
ACTOR=""
DECISION=""
REVIEW_ROUND="0"
RISK_LEVEL=""
REASONS="[]"
SUGGESTIONS="[]"
RERUN_SCOPE=""
HIGH_RISK_APPROVED="false"
STOP_REASON=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-id) RUN_ID="$2"; shift 2 ;;
    --actor) ACTOR="$2"; shift 2 ;;
    --decision) DECISION="$2"; shift 2 ;;
    --review-round) REVIEW_ROUND="$2"; shift 2 ;;
    --risk-level) RISK_LEVEL="$2"; shift 2 ;;
    --reasons-json) REASONS="$2"; shift 2 ;;
    --suggestions-json) SUGGESTIONS="$2"; shift 2 ;;
    --rerun-scope) RERUN_SCOPE="$2"; shift 2 ;;
    --high-risk-approved) HIGH_RISK_APPROVED="$2"; shift 2 ;;
    --stop-reason) STOP_REASON="$2"; shift 2 ;;
    *) json_err "unknown arg: $1" ;;
  esac
done

[[ -n "$RUN_ID" && -n "$ACTOR" ]] || json_err "usage: append_review_audit.sh --run-id ID --actor hermes|human|system [options]"
RUN_DIR="$(ensure_run_dir "$RUN_ID")"
AUDIT_FILE="${RUN_DIR}/review_audit.jsonl"
POST_FILE="${RUN_DIR}/post.md"
SVG_FILE="${RUN_DIR}/art.svg"

python3 - "$AUDIT_FILE" "$POST_FILE" "$SVG_FILE" "$RUN_ID" "$ACTOR" "$DECISION" "$REVIEW_ROUND" "$RISK_LEVEL" "$REASONS" "$SUGGESTIONS" "$RERUN_SCOPE" "$HIGH_RISK_APPROVED" "$STOP_REASON" <<'PYCODE'
import hashlib
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

(audit_file, post_file, svg_file, run_id, actor, decision, review_round, risk_level, reasons_json, suggestions_json, rerun_scope, high_risk_approved, stop_reason) = sys.argv[1:]

def h(path: str) -> str:
    p = Path(path)
    return hashlib.sha256(p.read_bytes()).hexdigest() if p.exists() else ""

try:
    reasons = json.loads(reasons_json)
except Exception:
    reasons = [reasons_json] if reasons_json else []
try:
    suggestions = json.loads(suggestions_json)
except Exception:
    suggestions = [suggestions_json] if suggestions_json else []

entry = {
    "run_id": run_id,
    "review_round": int(review_round or 0),
    "actor": actor,
    "decision": decision,
    "risk_level": risk_level,
    "reasons": reasons,
    "suggestions": suggestions,
    "rerun_scope": rerun_scope,
    "content_hash_after": {"post_md": h(post_file), "art_svg": h(svg_file)},
    "high_risk_approved": str(high_risk_approved).lower() == "true",
    "stop_reason": stop_reason,
    "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}
with open(audit_file, "a", encoding="utf-8") as f:
    f.write(json.dumps(entry, ensure_ascii=False) + "\n")
print(json.dumps({"ok": True, "path": audit_file}, ensure_ascii=False))
PYCODE
