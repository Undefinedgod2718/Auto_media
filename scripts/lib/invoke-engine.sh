#!/usr/bin/env bash
# File-based open-design invocation: read SKILL tree + TASK.md, write artifacts to disk.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/read-platform.sh"

RUN_ID=""
ENGINE=""
MOCK="${AUTO_MEDIA_MOCK:-0}"

usage() {
  echo "Usage: invoke-engine.sh --run-id ID --engine copywriter|svg_artist" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-id) RUN_ID="$2"; shift 2 ;;
    --engine) ENGINE="$2"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -n "$RUN_ID" && -n "$ENGINE" ]] || usage

mock_generate() {
  local topic
  topic="$(grep -E '^topic:' "$TASK_FILE" | head -1 | cut -d: -f2- | sed 's/^[[:space:]]*//' || true)"
  if [[ "$ENGINE" == "copywriter" ]]; then
    cat >"$OUT_FILE" <<EOF
# ${topic:-Untitled}

_Mock output (AUTO_MEDIA_MOCK=1). Replace with Claude CLI in production._

- Audience: $(grep -E '^audience:' "$TASK_FILE" | cut -d: -f2- | sed 's/^[[:space:]]*//' || echo n/a)
- Generated at: $(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
  else
    cat >"$OUT_FILE" <<'SVGEOF'
<svg xmlns="http://www.w3.org/2000/svg" width="1080" height="1080" viewBox="0 0 1080 1080">
  <rect width="1080" height="1080" fill="#0f172a"/>
  <text x="540" y="540" text-anchor="middle" fill="#f8fafc" font-family="sans-serif" font-size="48">Auto Media Mock SVG</text>
</svg>
SVGEOF
  fi
}

RUN_DIR="$(ensure_run_dir "$RUN_ID")"
TASK_FILE="${RUN_DIR}/TASK.md"
[[ -f "$TASK_FILE" ]] || json_err "missing TASK.md at $TASK_FILE"

if [[ "$MOCK" == "1" ]]; then
  case "$ENGINE" in
    copywriter) OUT_FILE="${RUN_DIR}/post.md"; mock_generate; json_ok "$OUT_FILE" ;;
    svg_artist) OUT_FILE="${RUN_DIR}/art.svg"; mock_generate; json_ok "$OUT_FILE" ;;
    *) json_err "unknown engine: $ENGINE" ;;
  esac
fi

[[ -f "$RUNTIME_JSON" ]] || json_err "missing runtime: $RUNTIME_JSON"

map_engine_key() {
  case "$ENGINE" in
    copywriter) echo "copy" ;;
    svg_artist) echo "svg" ;;
    *) json_err "unknown engine: $ENGINE" ;;
  esac
}

ENGINE_KEY="$(map_engine_key)"
STATUS="$(engine_status "$ENGINE_KEY")"
if [[ "$MOCK" != "1" && "$STATUS" != "active" ]]; then
  json_err "engine ${ENGINE_KEY} status is ${STATUS:-unknown} (set active in platform.yaml or AUTO_MEDIA_MOCK=1)"
fi

SKILL_DIR="$(engine_skill_path "$ENGINE_KEY")"
if [[ ! -d "$SKILL_DIR" ]]; then
  MOUNT="$(engine_skill_mount "$ENGINE_KEY")"
  ALT="${REPO_ROOT}/config/skills/${MOUNT}"
  [[ -d "$ALT" ]] && SKILL_DIR="$ALT"
fi
PROVIDER="$(engine_provider "$ENGINE_KEY")"
BINARY="$(engine_binary "$ENGINE_KEY")"

case "$ENGINE" in
  copywriter)
    OUT_FILE="${RUN_DIR}/post.md"
    ;;
  svg_artist)
    OUT_FILE="${RUN_DIR}/art.svg"
    ;;
esac

invoke_claude_cli() {
  [[ -d "$SKILL_DIR" ]] || json_err "skill dir missing: $SKILL_DIR"
  for f in SKILL.md BRAND.md TEMPLATE.md; do
    [[ -f "${SKILL_DIR}/${f}" ]] || json_err "missing ${SKILL_DIR}/${f}"
  done
  command -v "$BINARY" >/dev/null 2>&1 || json_err "binary not found: $BINARY"

  local prompt
  prompt="Read system instructions from ${SKILL_DIR}/SKILL.md. Apply brand voice from ${SKILL_DIR}/BRAND.md. Read task from ${TASK_FILE}. Format output per ${SKILL_DIR}/TEMPLATE.md. Write final output ONLY to ${OUT_FILE}. Do not print conversational text to stdout."

  "$BINARY" -y -p "$prompt" </dev/null >/dev/null 2>&1 || json_err "claude CLI failed"
  [[ -f "$OUT_FILE" ]] || json_err "output not created: $OUT_FILE"
}

invoke_codex_cli() {
  [[ -d "$SKILL_DIR" ]] || json_err "skill dir missing: $SKILL_DIR"
  for f in SKILL.md PALETTE.md RULES.md; do
    [[ -f "${SKILL_DIR}/${f}" ]] || json_err "missing ${SKILL_DIR}/${f}"
  done
  local _codex_ok=0
  if command -v "$BINARY" >/dev/null 2>&1; then
    local prompt
    prompt="Read ${SKILL_DIR}/SKILL.md, ${SKILL_DIR}/PALETTE.md, ${SKILL_DIR}/RULES.md and task ${TASK_FILE}. Write valid W3C SVG ONLY to ${OUT_FILE}. viewBox 0 0 1080 1080. No external URLs. No stdout chatter."
    "$BINARY" -y "$prompt" </dev/null >/dev/null 2>&1 && _codex_ok=1 || _codex_ok=0
  fi
  if [[ "$_codex_ok" == "0" || ! -f "$OUT_FILE" ]]; then
    # codex binary missing or failed — fallback to gemini_cli
    echo '{"fallback":"gemini","reason":"codex unavailable or failed"}' >&2
    BINARY="gemini"
    invoke_gemini_cli
    return
  fi
  if command -v xmllint >/dev/null 2>&1; then
    xmllint --noout "$OUT_FILE" 2>/dev/null || { BINARY="gemini"; invoke_gemini_cli; return; }
  fi
}

invoke_gemini_cli() {
  [[ -d "$SKILL_DIR" ]] || json_err "skill dir missing: $SKILL_DIR"
  command -v "$BINARY" >/dev/null 2>&1 || json_err "binary not found: $BINARY"

  local prompt
  if [[ "$ENGINE" == "copywriter" ]]; then
    for f in SKILL.md BRAND.md TEMPLATE.md; do
      [[ -f "${SKILL_DIR}/${f}" ]] || json_err "missing ${SKILL_DIR}/${f}"
    done
    prompt="Read system instructions from ${SKILL_DIR}/SKILL.md. Apply brand voice from ${SKILL_DIR}/BRAND.md. Read task from ${TASK_FILE}. Format output per ${SKILL_DIR}/TEMPLATE.md. Write final output ONLY to ${OUT_FILE}. Do not print conversational text to stdout."
  else
    for f in SKILL.md PALETTE.md RULES.md; do
      [[ -f "${SKILL_DIR}/${f}" ]] || json_err "missing ${SKILL_DIR}/${f}"
    done
    prompt="Read ${SKILL_DIR}/SKILL.md, ${SKILL_DIR}/PALETTE.md, ${SKILL_DIR}/RULES.md and task ${TASK_FILE}. Write valid W3C SVG ONLY to ${OUT_FILE}. viewBox 0 0 1080 1080. No external URLs. No stdout chatter."
  fi

  "$BINARY" -p "$prompt" -y --approval-mode auto_edit </dev/null >/dev/null 2>&1 \
    || json_err "gemini CLI failed"
  if [[ ! -f "$OUT_FILE" ]]; then
    "$BINARY" -p "$prompt" </dev/null >"$OUT_FILE" 2>/dev/null \
      || json_err "gemini CLI failed (no output file)"
  fi
  [[ -f "$OUT_FILE" ]] || json_err "output not created: $OUT_FILE"
  if [[ "$ENGINE" == "svg_artist" ]] && command -v xmllint >/dev/null 2>&1; then
    xmllint --noout "$OUT_FILE" 2>/dev/null || json_err "invalid SVG XML"
  fi
}

if [[ "$PROVIDER" == "claude_cli" ]]; then
  invoke_claude_cli
elif [[ "$PROVIDER" == "codex_cli" ]]; then
  invoke_codex_cli
elif [[ "$PROVIDER" == "gemini_cli" ]]; then
  invoke_gemini_cli
else
  json_err "unsupported provider: $PROVIDER"
fi

json_ok "$OUT_FILE"
