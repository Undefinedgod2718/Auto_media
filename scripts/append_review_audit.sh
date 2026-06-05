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

# Decode base64 scalar args. Workflow commands pass user/AI-controlled values
# base64-wrapped so no shell metacharacter ever reaches the command string.
b64dec() {
  python3 -c "import base64,sys; sys.stdout.write(base64.b64decode(sys.argv[1]).decode('utf-8'))" "$1" 2>/dev/null || true
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-id) RUN_ID="$2"; shift 2 ;;
    --actor) ACTOR="$2"; shift 2 ;;
    --decision) DECISION="$2"; shift 2 ;;
    --decision-b64) DECISION="$(b64dec "$2")"; shift 2 ;;
    --review-round) REVIEW_ROUND="$2"; shift 2 ;;
    --review-round-b64) REVIEW_ROUND="$(b64dec "$2")"; shift 2 ;;
    --risk-level) RISK_LEVEL="$2"; shift 2 ;;
    --risk-level-b64) RISK_LEVEL="$(b64dec "$2")"; shift 2 ;;
    --reasons-json) REASONS="$2"; shift 2 ;;
    --suggestions-json) SUGGESTIONS="$2"; shift 2 ;;
    --reasons-b64) REASONS="$(b64dec "$2")"; [[ -n "$REASONS" ]] || REASONS="[]"; shift 2 ;;
    --suggestions-b64) SUGGESTIONS="$(b64dec "$2")"; [[ -n "$SUGGESTIONS" ]] || SUGGESTIONS="[]"; shift 2 ;;
    --rerun-scope) RERUN_SCOPE="$2"; shift 2 ;;
    --rerun-scope-b64) RERUN_SCOPE="$(b64dec "$2")"; shift 2 ;;
    --high-risk-approved) HIGH_RISK_APPROVED="$2"; shift 2 ;;
    --stop-reason) STOP_REASON="$2"; shift 2 ;;
    *) json_err "unknown arg: $1" ;;
  esac
done

# REVIEW_ROUND must stay numeric (decoded value is consumed as int downstream).
[[ "$REVIEW_ROUND" =~ ^[0-9]+$ ]] || REVIEW_ROUND="0"

[[ -n "$RUN_ID" && -n "$ACTOR" ]] || json_err "usage: append_review_audit.sh --run-id ID --actor hermes|human|system [options]"
RUN_DIR="$(ensure_run_dir "$RUN_ID")"
AUDIT_FILE="${RUN_DIR}/review_audit.jsonl"
POST_FILE="${RUN_DIR}/post.md"
ART_SVG_FILE="${RUN_DIR}/art.svg"
POST_PNG_FILE="${RUN_DIR}/post.png"
POST_JPG_FILE="${RUN_DIR}/post.jpg"
POST_JPEG_FILE="${RUN_DIR}/post.jpeg"
ASSESS_FILE="${RUN_DIR}/hermes_assessment.json"

# B-prime: Gateway runs Hermes on host; n8n skips Parse Hermes assessment node.
if [[ -z "$RISK_LEVEL" && -f "$ASSESS_FILE" ]]; then
  _assess="$(python3 - "$ASSESS_FILE" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
try:
    a = json.loads(p.read_text(encoding="utf-8"))
except Exception:
    print("|||")
    raise SystemExit(0)
reasons = a.get("reasons") or []
suggestions = a.get("suggestions") or []
if not isinstance(reasons, list):
    reasons = [str(reasons)]
if not isinstance(suggestions, list):
    suggestions = [str(suggestions)]
print("|".join([
    str(a.get("risk_level") or ""),
    json.dumps(reasons, ensure_ascii=False),
    json.dumps(suggestions, ensure_ascii=False),
]))
PY
)"
  if [[ -n "$_assess" && "$_assess" != "|||" ]]; then
    IFS='|' read -r _risk _reasons _suggestions <<< "$_assess"
    [[ -z "$RISK_LEVEL" && -n "$_risk" ]] && RISK_LEVEL="$_risk"
    [[ "$REASONS" == "[]" && -n "$_reasons" ]] && REASONS="$_reasons"
    [[ "$SUGGESTIONS" == "[]" && -n "$_suggestions" ]] && SUGGESTIONS="$_suggestions"
  fi
fi

if [[ "$HIGH_RISK_APPROVED" == "false" && "$DECISION" == "approve" && "$RISK_LEVEL" == "high" ]]; then
  HIGH_RISK_APPROVED="true"
fi

python3 - "$AUDIT_FILE" "$POST_FILE" "$ART_SVG_FILE" "$POST_PNG_FILE" "$POST_JPG_FILE" "$POST_JPEG_FILE" "$RUN_ID" "$ACTOR" "$DECISION" "$REVIEW_ROUND" "$RISK_LEVEL" "$REASONS" "$SUGGESTIONS" "$RERUN_SCOPE" "$HIGH_RISK_APPROVED" "$STOP_REASON" <<'PYCODE'
import hashlib
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

(audit_file, post_file, art_svg_file, post_png_file, post_jpg_file, post_jpeg_file, run_id, actor, decision, review_round, risk_level, reasons_json, suggestions_json, rerun_scope, high_risk_approved, stop_reason) = sys.argv[1:]

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
    "content_hash_after": {
        "post_md": h(post_file),
        "art_svg": h(art_svg_file),
        "post_png": h(post_png_file),
        "post_jpg": h(post_jpg_file),
        "post_jpeg": h(post_jpeg_file),
    },
    "high_risk_approved": str(high_risk_approved).lower() == "true",
    "stop_reason": stop_reason,
    "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}
with open(audit_file, "a", encoding="utf-8") as f:
    f.write(json.dumps(entry, ensure_ascii=False) + "\n")
print(json.dumps({"ok": True, "path": audit_file}, ensure_ascii=False))
PYCODE
