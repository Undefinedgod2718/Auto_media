#!/usr/bin/env bash
# Generate IG Carousel slides as PNG (carousel/01.png …) using codex_svg_artist + CLI failover.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

RUN_ID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-id) RUN_ID="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "$RUN_ID" ]] || json_err "usage: generate_carousel_images.sh --run-id ID"

RUN_DIR="$(ensure_run_dir "$RUN_ID")"
TASK_FILE="${RUN_DIR}/TASK.md"
[[ -f "$TASK_FILE" ]] || json_err "missing TASK.md"
run_state_ensure "$RUN_DIR" "$RUN_ID"
run_state_require_stage "$RUN_DIR" "$RUN_ID" 1 || json_err "run stage not ready for artist generation (need writers_done)"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if ! PYTHONPATH="$ROOT/scripts/lib" python3 -c "
from pathlib import Path
from carousel_policy import should_generate_carousel
import sys
sys.exit(0 if should_generate_carousel(Path(sys.argv[1])) else 1)
" "$TASK_FILE"; then
  python3 -c "import json; print(json.dumps({'ok':True,'skipped':True,'reason':'no instagram carousel','slides':[]},ensure_ascii=False))"
  exit 0
fi

TOPIC="$(grep -E '^topic:' "$TASK_FILE" | head -1 | cut -d: -f2- | sed 's/^[[:space:]]*//' || true)"
AUDIENCE="$(grep -E '^audience:' "$TASK_FILE" | head -1 | cut -d: -f2- | sed 's/^[[:space:]]*//' || true)"
TOTAL="$(grep -E '^carousel_total:' "$TASK_FILE" | head -1 | cut -d: -f2- | tr -d ' ' || true)"
[[ -n "$TOTAL" ]] || TOTAL="0"
if [[ "${TOTAL:-0}" -le 0 ]]; then
  python3 -c "import json; print(json.dumps({'ok':True,'skipped':True,'reason':'carousel_total is 0','slides':[]},ensure_ascii=False))"
  exit 0
fi

SKILL_DIR="/data/config/skills/codex_svg_artist"
[[ -d "$SKILL_DIR" ]] || SKILL_DIR="${ROOT}/config/skills/codex_svg_artist"

CAROUSEL_DIR="${RUN_DIR}/instagram/carousel"
mkdir -p "$CAROUSEL_DIR"
POST_MD="${RUN_DIR}/post.md"

PLAN_JSON="$(python3 "$ROOT/scripts/lib/build_carousel_prompts.py" \
  --skill-dir "$SKILL_DIR" \
  --topic "${TOPIC:-Untitled}" \
  --audience "${AUDIENCE:-general}" \
  --total "$TOTAL" \
  --post-md "$POST_MD")"

COUNT="$(echo "$PLAN_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['total'])")"
ENGINE_SH="$(dirname "${BASH_SOURCE[0]}")/lib/invoke-engine.sh"
FAILED=0
i=0
while [[ "$i" -lt "$COUNT" ]]; do
  pn="$(printf '%02d' $((i + 1)))"
  OUT="${CAROUSEL_DIR}/${pn}.png"
  PROMPT="$(echo "$PLAN_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['prompts'][$i])")"
  export CAROUSEL_PAGE_PROMPT="$PROMPT"
  if ! /bin/bash "$ENGINE_SH" --run-id "$RUN_ID" --engine svg_artist --out-file "$OUT" >/dev/null 2>>"${RUN_DIR}/carousel_gen.log"; then
    echo "warn: page ${pn} provider chain failed" >&2
    FAILED=$((FAILED + 1))
  fi
  unset CAROUSEL_PAGE_PROMPT
  i=$((i + 1))
done

# Preview / Threads first slide
if [[ -f "${CAROUSEL_DIR}/01.png" ]]; then
  cp -f "${CAROUSEL_DIR}/01.png" "${RUN_DIR}/post.png"
elif [[ -f "${CAROUSEL_DIR}/1.png" ]]; then
  cp -f "${CAROUSEL_DIR}/1.png" "${RUN_DIR}/post.png"
fi

# Compatibility: keep legacy run/carousel for older publish scripts / tooling.
mkdir -p "${RUN_DIR}/carousel"
cp -f "${CAROUSEL_DIR}/"*.png "${RUN_DIR}/carousel/" 2>/dev/null || true
cp -f "${CAROUSEL_DIR}/"*.jpg "${RUN_DIR}/carousel/" 2>/dev/null || true

CAR_LIMITS="$(python3 "$ROOT/scripts/lib/parse_carousel_total.py" "$POST_MD" --task-md "$TASK_FILE" --json 2>/dev/null || echo '{"min":1,"max":10}')"
MIN_SLIDES="$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['min'])" "$CAR_LIMITS")"
MAX_SLIDES="$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['max'])" "$CAR_LIMITS")"

SLIDE_COUNT="$(find "$CAROUSEL_DIR" -maxdepth 1 -name '*.png' -o -name '*.jpg' 2>/dev/null | wc -l | tr -d ' ')"

if [[ "$MIN_SLIDES" -gt 0 && "$SLIDE_COUNT" -lt "$MIN_SLIDES" ]]; then
  echo "error: carousel has ${SLIDE_COUNT} slides, need >= ${MIN_SLIDES} (planned ${TOTAL}, max ${MAX_SLIDES})" >&2
  echo "hint: check ${RUN_DIR}/carousel_gen.log and data/logs/engine_failover.jsonl (codex→gemini→claude)" >&2
  echo "hint: set GEMINI_API_KEY or sync OAuth: ./scripts/sync_gemini_oauth.sh && ./scripts/sync_claude_oauth.sh" >&2
  [[ -f "${RUN_DIR}/carousel_gen.log" ]] && tail -30 "${RUN_DIR}/carousel_gen.log" >&2 || true
  exit 1
fi

if [[ "$SLIDE_COUNT" -gt "$MAX_SLIDES" ]]; then
  echo "error: carousel has ${SLIDE_COUNT} slides, exceeds platform max ${MAX_SLIDES}" >&2
  exit 1
fi

if [[ "$FAILED" -gt 0 ]]; then
  echo "error: ${FAILED} carousel page(s) failed to generate" >&2
  exit 1
fi

python3 -c "
import json, sys
from pathlib import Path
run = Path(sys.argv[1])
slides = sorted(run.glob('*.png')) + sorted(run.glob('*.jpg'))
print(json.dumps({
    'ok': len(slides) >= int(sys.argv[3]) and int(sys.argv[2]) == 0,
    'path': str(run),
    'slides': [p.name for p in slides],
    'failed_pages': int(sys.argv[2]),
    'slide_count': len(slides),
}, ensure_ascii=False))
" "$CAROUSEL_DIR" "$FAILED" "$MIN_SLIDES"
run_state_mark_stage "$RUN_DIR" "$RUN_ID" "artists_done" || true
