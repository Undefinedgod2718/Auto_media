#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

RUN_ID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-id) RUN_ID="$2"; shift 2 ;;
    *) json_err "unknown arg: $1" ;;
  esac
done

[[ -n "$RUN_ID" ]] || json_err "usage: hermes_prereview.sh --run-id ID"
RUN_DIR="$(ensure_run_dir "$RUN_ID")"
TASK_FILE="${RUN_DIR}/TASK.md"
POST_FILE="${RUN_DIR}/post.md"
SVG_FILE="${RUN_DIR}/art.svg"
PNG_FILE="${RUN_DIR}/post.png"
OUT_FILE="${RUN_DIR}/hermes_assessment.json"

[[ -f "$TASK_FILE" && -f "$POST_FILE" && -f "$SVG_FILE" && -f "$PNG_FILE" ]] || json_err "missing required artifacts"

python3 - "$RUN_ID" "$TASK_FILE" "$POST_FILE" "$SVG_FILE" "$PNG_FILE" "$OUT_FILE" <<'PYCODE'
import hashlib
import json
import re
import sys
from pathlib import Path

run_id, task_file, post_file, svg_file, png_file, out_file = sys.argv[1:]

def h(path: str) -> str:
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

task = Path(task_file).read_text(encoding="utf-8", errors="ignore")
post = Path(post_file).read_text(encoding="utf-8", errors="ignore")
svg = Path(svg_file).read_text(encoding="utf-8", errors="ignore")

reasons = []
suggestions = []
risk = "low"
copy_state = "pass"
image_state = "pass"
rerun = "copy_only"
verdict = "pass"

if len(post.strip()) < 60:
    copy_state = "fail"
    verdict = "revise"
    reasons.append("文案過短，資訊不足")
    suggestions.append("補充價值主張與 CTA")
    risk = "medium"

if "http://" in post or "https://" in post:
    copy_state = "warn"
    reasons.append("文案包含外部連結，建議確認合規")

if not re.search(r"<svg[\s\S]*</svg>", svg, flags=re.IGNORECASE):
    image_state = "fail"
    verdict = "reject"
    reasons.append("SVG 結構不完整")
    suggestions.append("重新生成視覺素材")
    risk = "high"
    rerun = "full"

if "禁用詞" in task or "敏感" in task:
    risk = "high"
    if verdict == "pass":
        verdict = "revise"
    reasons.append("任務含敏感提示，需人審")

if not reasons:
    reasons.append("符合基本生成規則")
if not suggestions:
    suggestions.append("可維持現稿，人工覆核後發佈")

assessment = {
    "run_id": run_id,
    "review_round": 0,
    "verdict_hint": verdict,
    "skill_compliance": {"copy": copy_state, "image": image_state},
    "reasons": reasons,
    "suggestions": suggestions,
    "risk_level": risk,
    "rerun_scope_hint": rerun,
    "artifact_hashes": {
        "task_md": h(task_file),
        "post_md": h(post_file),
        "art_svg": h(svg_file),
        "post_png": h(png_file),
    },
}
Path(out_file).write_text(json.dumps(assessment, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(json.dumps(assessment, ensure_ascii=False))
PYCODE
