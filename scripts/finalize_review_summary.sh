#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

RUN_ID=""
PUBLISH_STATUS=""
PUBLISH_TARGETS=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-id) RUN_ID="$2"; shift 2 ;;
    --publish-status) PUBLISH_STATUS="$2"; shift 2 ;;
    --publish-targets) PUBLISH_TARGETS="$2"; shift 2 ;;
    *) json_err "unknown arg: $1" ;;
  esac
done

[[ -n "$RUN_ID" ]] || json_err "usage: finalize_review_summary.sh --run-id ID [--publish-status success|fail] [--publish-targets text]"
RUN_DIR="$(ensure_run_dir "$RUN_ID")"
AUDIT_FILE="${RUN_DIR}/review_audit.jsonl"
SUMMARY_FILE="${RUN_DIR}/review_summary.json"

python3 - "$RUN_ID" "$AUDIT_FILE" "$SUMMARY_FILE" "$PUBLISH_STATUS" "$PUBLISH_TARGETS" <<'PYCODE'
import json
import sys
from pathlib import Path

run_id, audit_file, summary_file, status, targets = sys.argv[1:]
entries = []
if Path(audit_file).exists():
    for line in Path(audit_file).read_text(encoding="utf-8").splitlines():
        if line.strip():
            entries.append(json.loads(line))

summary = {
    "run_id": run_id,
    "total_entries": len(entries),
    "last_decision": entries[-1].get("decision") if entries else None,
    "high_risk_approved": any(e.get("high_risk_approved") for e in entries),
    "publish_status": status or None,
    "publish_targets": targets or None,
    "artifacts": {
        "task_md": f"/data/runs/{run_id}/TASK.md",
        "post_md": f"/data/runs/{run_id}/post.md",
        "art_svg": f"/data/runs/{run_id}/art.svg",
        "post_png": f"/data/runs/{run_id}/post.png",
        "post_jpg": f"/data/runs/{run_id}/post.jpg",
        "post_jpeg": f"/data/runs/{run_id}/post.jpeg",
        "carousel_dir": f"/data/runs/{run_id}/carousel",
    },
}
Path(summary_file).write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(json.dumps({"ok": True, "path": summary_file}, ensure_ascii=False))
PYCODE
