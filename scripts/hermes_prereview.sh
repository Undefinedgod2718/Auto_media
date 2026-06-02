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
PNG_FILE=""
for f in post.png post.jpg post.jpeg; do
  [[ -f "${RUN_DIR}/${f}" ]] && PNG_FILE="${RUN_DIR}/${f}" && break
done
if [[ -z "$PNG_FILE" && -d "${RUN_DIR}/carousel" ]]; then
  for f in "${RUN_DIR}"/carousel/*.png "${RUN_DIR}"/carousel/*.jpg; do
    [[ -f "$f" ]] && PNG_FILE="$f" && break
  done
fi
OUT_FILE="${RUN_DIR}/hermes_assessment.json"

[[ -f "$TASK_FILE" && -f "$POST_FILE" ]] || json_err "missing required artifacts (need TASK.md, post.md)"

IMAGE_REQUIRED=1
if PYTHONPATH="${REPO_ROOT}/scripts/lib" python3 -c "
from pathlib import Path
from carousel_policy import should_generate_carousel
print('1' if should_generate_carousel(Path('${TASK_FILE}')) else '0')
" 2>/dev/null | grep -qx '0'; then
  IMAGE_REQUIRED=0
fi

if [[ "$IMAGE_REQUIRED" -eq 1 && -z "$PNG_FILE" ]]; then
  json_err "missing required artifacts (need post.png or carousel image for IG carousel)"
fi

python3 - "$RUN_ID" "$TASK_FILE" "$POST_FILE" "$SVG_FILE" "${PNG_FILE:-}" "$OUT_FILE" "$IMAGE_REQUIRED" <<'PYCODE'
import hashlib
import json
import re
import sys
from pathlib import Path

run_id, task_file, post_file, svg_file, png_file, out_file, image_required_s = sys.argv[1:]
image_required = image_required_s == "1"

def h(path: str) -> str:
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

task = Path(task_file).read_text(encoding="utf-8", errors="ignore")
post = Path(post_file).read_text(encoding="utf-8", errors="ignore")
svg = Path(svg_file).read_text(encoding="utf-8", errors="ignore") if Path(svg_file).is_file() else ""

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

png_path = Path(png_file) if png_file else None
if not image_required:
    image_state = "skip"
elif not png_path or not png_path.is_file() or png_path.stat().st_size < 100:
    image_state = "fail"
    verdict = "reject"
    reasons.append("圖片缺失或過小")
    suggestions.append("重新生成視覺素材")
    risk = "high"
    rerun = "full"
elif svg and not re.search(r"<svg[\s\S]*</svg>", svg, flags=re.IGNORECASE):
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
        **({"post_png": h(png_file)} if png_file and Path(png_file).is_file() else {}),
        **({"art_svg": h(svg_file)} if Path(svg_file).is_file() else {}),
    },
}
Path(out_file).write_text(json.dumps(assessment, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(json.dumps(assessment, ensure_ascii=False))
PYCODE
