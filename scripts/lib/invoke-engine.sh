#!/usr/bin/env bash
# File-based open-design invocation: read SKILL tree + TASK.md, write artifacts to disk.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/read-platform.sh"

RUN_ID=""
ENGINE=""
MOCK="${AUTO_MEDIA_MOCK:-0}"

usage() {
  echo "Usage: invoke-engine.sh --run-id ID --engine copywriter|svg_artist [--out-file PATH]" >&2
  exit 1
}

IMAGE_OUT_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-id) RUN_ID="$2"; shift 2 ;;
    --engine) ENGINE="$2"; shift 2 ;;
    --out-file) IMAGE_OUT_FILE="$2"; shift 2 ;;
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
    python3 - "$OUT_FILE" <<'PY'
import sys
from pathlib import Path
png = bytes([
  0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A,0x00,0x00,0x00,0x0D,0x49,0x48,0x44,0x52,
  0x00,0x00,0x04,0x38,0x00,0x00,0x04,0x38,0x08,0x02,0x00,0x00,0x00,0x6F,0x1A,0x0D,
  0x24,0x00,0x00,0x00,0x0C,0x49,0x44,0x41,0x54,0x08,0xD7,0x63,0xF8,0xCF,0xC0,0x00,
  0x00,0x03,0x01,0x01,0x00,0x18,0xDD,0x8D,0xB4,0x00,0x00,0x00,0x00,0x49,0x45,0x4E,0x44,
  0xAE,0x42,0x60,0x82,
])
Path(sys.argv[1]).write_bytes(png)
PY
  fi
}

RUN_DIR="$(ensure_run_dir "$RUN_ID")"
TASK_FILE="${RUN_DIR}/TASK.md"
[[ -f "$TASK_FILE" ]] || json_err "missing TASK.md at $TASK_FILE"

if [[ "$MOCK" == "1" ]]; then
  case "$ENGINE" in
    copywriter) OUT_FILE="${RUN_DIR}/post.md"; mock_generate; json_ok "$OUT_FILE" ;;
    svg_artist) OUT_FILE="${RUN_DIR}/post.png"; mock_generate; json_ok "$OUT_FILE" ;;
    *) json_err "unknown engine: $ENGINE" ;;
  esac
  # Mock mode should short-circuit the real provider path.
  exit 0
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
    if [[ -n "$IMAGE_OUT_FILE" ]]; then
      OUT_FILE="$IMAGE_OUT_FILE"
    else
      OUT_FILE="${RUN_DIR}/post.png"
    fi
    ;;
esac

# Recoverable provider failure: log to stderr and signal the failover loop.
# NEVER json_err (exit) inside a provider — that aborts the whole chain.
_pfail() {
  echo "provider-fail: $*" >&2
  return 1
}

# Reject CLI meta chatter in post.md; strip English preamble when zh body exists.
finalize_copywriter_output() {
  local f="$1"
  [[ -s "$f" ]] || return 1
  python3 - "$f" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8", errors="replace")

META = [
    r"I have completed the (?:task|copywriting)",
    r"Successfully generated",
    r"(?:written|saved)(?:\s+the\s+social\s+media\s+post)?\s+to\s+[`']?/data/runs/.*/post\.md",
    r"Research\s*&\s*Synthesis",
    r"\*\*Implementation:\*\*",
    r"The post is now ready for use",
]


def zh(s: str) -> int:
    return len(re.findall(r"[\u4e00-\u9fff]", s))


def has_meta(s: str) -> bool:
    return any(re.search(p, s, re.I) for p in META)


def normalize(t: str) -> str:
    if zh(t) < 20 or not has_meta(t):
        return t.strip()
    for i, line in enumerate(t.splitlines()):
        if zh(line) >= 4:
            body = "\n".join(t.splitlines()[i:]).strip()
            if zh(body) >= 20:
                return body
    return t.strip()


def valid(t: str) -> bool:
    return zh(t) >= 20 and not has_meta(t)


out = normalize(text)
if not valid(out):
    sys.exit(1)
if out != text.strip():
    path.write_text(out + ("\n" if out and not out.endswith("\n") else ""), encoding="utf-8")
sys.exit(0)
PY
}

# Skill files required for the current engine (provider-independent).
required_skill_files() {
  if [[ "$ENGINE" == "copywriter" ]]; then
    echo "SKILL.md BRAND.md TEMPLATE.md"
  else
    echo "SKILL.md VISUAL_BASE.md PAGE_TYPES.md PALETTE.md RULES.md BRAND.md"
  fi
}

# Engine-aware prompt: copy → post.md, svg_artist → post.png/jpg (raster only).
build_prompt() {
  if [[ -n "${CAROUSEL_PAGE_PROMPT:-}" ]]; then
    printf '%s' "${CAROUSEL_PAGE_PROMPT} Write the image ONLY to ${OUT_FILE} using your file/image tool. Valid PNG or JPEG, max 8MB, 1080x1080. No SVG. No stdout chatter."
    return
  fi
  if [[ "$ENGINE" == "copywriter" ]]; then
    printf '%s' "Read system instructions from ${SKILL_DIR}/SKILL.md. Apply brand voice from ${SKILL_DIR}/BRAND.md. Read task from ${TASK_FILE}. Format output per ${SKILL_DIR}/TEMPLATE.md. Write final output ONLY to ${OUT_FILE}. Do not print conversational text to stdout."
  else
    printf '%s' "Read ${SKILL_DIR}/SKILL.md, ${SKILL_DIR}/VISUAL_BASE.md, ${SKILL_DIR}/PAGE_TYPES.md, ${SKILL_DIR}/BRAND.md, ${SKILL_DIR}/RULES.md and task ${TASK_FILE}. For single-image tasks use page type A Cover unless TASK specifies page_type. Create a 1080x1080 editorial slide. Write a valid PNG or JPEG ONLY to ${OUT_FILE} using your file/image tool. Max 8MB. No SVG/XML/Markdown in the output file. No stdout chatter."
  fi
}

# Gemini CLI workspace is cwd + --include-directories; use run-relative paths for /data/runs files.
build_gemini_prompt() {
  local out_path="$OUT_FILE" task_path="$TASK_FILE"
  if [[ "$OUT_FILE" == "${RUN_DIR}/"* ]]; then
    out_path="${OUT_FILE#"${RUN_DIR}/"}"
  fi
  if [[ "$TASK_FILE" == "${RUN_DIR}/"* ]]; then
    task_path="${TASK_FILE#"${RUN_DIR}/"}"
  fi
  if [[ -n "${CAROUSEL_PAGE_PROMPT:-}" ]]; then
    printf '%s' "${CAROUSEL_PAGE_PROMPT} Write the image ONLY to ${out_path} using your write_file tool. Valid PNG or JPEG, max 8MB, 1080x1080. No SVG. No stdout chatter."
    return
  fi
  if [[ "$ENGINE" == "copywriter" ]]; then
    printf '%s' "Read ${SKILL_DIR}/SKILL.md, ${SKILL_DIR}/BRAND.md, ${SKILL_DIR}/TEMPLATE.md. Read task from ${task_path}. Write final Traditional Chinese (zh-TW) output ONLY to ${out_path} using write_file. Do not use activate_skill. No stdout chatter."
  else
    printf '%s' "Read ${SKILL_DIR}/SKILL.md, ${SKILL_DIR}/PALETTE.md, ${SKILL_DIR}/RULES.md and task ${task_path}. Create a 1080x1080 PNG or JPEG. Write ONLY to ${out_path} using write_file. Max 8MB. No SVG."
  fi
}

run_gemini_prompt() {
  local prompt="$1"
  local _gemini_err
  _gemini_err="$(mktemp)"
  if ! (
    cd "$RUN_DIR" || exit 1
    "$BINARY" -y --skip-trust \
      --include-directories "$RUN_DIR" \
      --include-directories "$SKILL_DIR" \
      --include-directories "${DATA_ROOT}/runs" \
      --include-directories "${DATA_ROOT}/config" \
      -p "$prompt" </dev/null >/dev/null 2>"$_gemini_err"
  ); then
    local _tail
    _tail="$(tail -8 "$_gemini_err" 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g')"
    rm -f "$_gemini_err"
    _pfail "gemini CLI failed${_tail:+: ${_tail}}"
    return 1
  fi
  rm -f "$_gemini_err"
  return 0
}

resolve_post_image() {
  local dir="$1"
  if [[ -s "${dir}/post.png" ]]; then
    OUT_FILE="${dir}/post.png"
    return 0
  fi
  if [[ -s "${dir}/post.jpg" ]]; then
    OUT_FILE="${dir}/post.jpg"
    return 0
  fi
  if [[ -s "${dir}/post.jpeg" ]]; then
    OUT_FILE="${dir}/post.jpeg"
    return 0
  fi
  return 1
}

# Carousel pages pass --out-file carousel/NN.png; success only when that path exists (not post.png alone).
svg_output_ready() {
  if [[ -n "$IMAGE_OUT_FILE" ]]; then
    mkdir -p "$(dirname "$IMAGE_OUT_FILE")"
    if [[ -s "$IMAGE_OUT_FILE" ]] && image_is_valid "$IMAGE_OUT_FILE"; then
      OUT_FILE="$IMAGE_OUT_FILE"
      return 0
    fi
    if resolve_post_image "$RUN_DIR"; then
      cp -f "$OUT_FILE" "$IMAGE_OUT_FILE" || return 1
      OUT_FILE="$IMAGE_OUT_FILE"
      [[ -s "$OUT_FILE" ]] && image_is_valid "$OUT_FILE"
      return $?
    fi
    return 1
  fi
  if [[ -s "$OUT_FILE" ]] && image_is_valid "$OUT_FILE"; then
    return 0
  fi
  if resolve_post_image "$RUN_DIR"; then
    [[ -s "$OUT_FILE" ]] && image_is_valid "$OUT_FILE"
    return $?
  fi
  return 1
}

image_is_valid() {
  local f="$1"
  [[ -s "$f" ]] || return 1
  python3 - "$f" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1])
data = p.read_bytes()
if len(data) > 8 * 1024 * 1024:
    sys.exit(1)
if data[:8] == b"\x89PNG\r\n\x1a\n" or data[:3] == b"\xff\xd8\xff":
    sys.exit(0)
sys.exit(1)
PY
}

claude_dir_has_auth() {
  local d="$1"
  [[ -d "$d" ]] || return 1
  [[ -f "${d}/.credentials.json" ]] && return 0
  return 1
}

claude_has_auth() {
  [[ -n "${ANTHROPIC_API_KEY:-}" ]] && return 0
  [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]] && return 0
  local d
  for d in \
    "${CLAUDE_CONFIG_DIR:-}" \
    "${DATA_ROOT}/secrets/claude" \
    "${REPO_ROOT}/data/secrets/claude" \
    "${HOME:-}/.claude"; do
    [[ -n "$d" ]] && claude_dir_has_auth "$d" && return 0
  done
  return 1
}

claude_auth_hint() {
  if claude_dir_has_auth "${HOME:-}/.claude" \
    && ! claude_dir_has_auth "${DATA_ROOT}/secrets/claude" \
    && ! claude_dir_has_auth "${REPO_ROOT}/data/secrets/claude"; then
    echo "OAuth is in ~/.claude but not data/secrets/claude — run: ./scripts/sync_claude_oauth.sh && docker compose restart n8n"
  else
    echo "run 'claude' /login, or set ANTHROPIC_API_KEY / CLAUDE_CODE_OAUTH_TOKEN, then sync_claude_oauth.sh"
  fi
}

claude_prepare_env() {
  local secrets=""
  for secrets in \
    "${CLAUDE_CONFIG_DIR:-}" \
    "${DATA_ROOT}/secrets/claude" \
    "${REPO_ROOT}/data/secrets/claude"; do
    if [[ -n "$secrets" ]] && claude_dir_has_auth "$secrets"; then
      export CLAUDE_CONFIG_DIR="$secrets"
      return 0
    fi
  done
  if claude_dir_has_auth "${HOME:-}/.claude"; then
    export CLAUDE_CONFIG_DIR="${HOME}/.claude"
    return 0
  fi
  export CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-${DATA_ROOT}/secrets/claude}"
}

invoke_claude_cli() {
  [[ -d "$SKILL_DIR" ]] || { _pfail "claude: skill dir missing: $SKILL_DIR"; return 1; }
  local f
  for f in $(required_skill_files); do
    [[ -f "${SKILL_DIR}/${f}" ]] || { _pfail "claude: missing ${SKILL_DIR}/${f}"; return 1; }
  done
  command -v "$BINARY" >/dev/null 2>&1 || { _pfail "claude: binary not found: $BINARY"; return 1; }
  claude_has_auth || { _pfail "claude_cli not authenticated: $(claude_auth_hint)"; return 1; }
  claude_prepare_env

  local prompt
  prompt="$(build_prompt)"

  local _claude_err
  _claude_err="$(mktemp)"
  if ! "$BINARY" -p "$prompt" --permission-mode acceptEdits </dev/null >/dev/null 2>"$_claude_err"; then
    local _tail
    _tail="$(tail -3 "$_claude_err" 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g')"
    rm -f "$_claude_err"
    _pfail "claude CLI failed${_tail:+: ${_tail}}"
    return 1
  fi
  rm -f "$_claude_err"
  if [[ "$ENGINE" == "svg_artist" ]]; then
    svg_output_ready || { _pfail "claude: image not created at ${OUT_FILE} (or post.png in $RUN_DIR)"; return 1; }
  else
    [[ -f "$OUT_FILE" ]] || { _pfail "claude: output not created: $OUT_FILE"; return 1; }
  fi
}

run_codex_exec() {
  local prompt="$1"
  local _codex_err
  _codex_err="$(mktemp)"
  # codex 0.135+ removed root-level -y; use exec in run cwd for /data/runs writes.
  if ! (cd "$RUN_DIR" &&   "$BINARY" exec --dangerously-bypass-approvals-and-sandbox "$prompt" \
    </dev/null >/dev/null 2>"$_codex_err"); then
    local _tail
    _tail="$(tail -5 "$_codex_err" 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g')"
    rm -f "$_codex_err"
    if [[ "$_tail" == *"refresh token was revoked"* || "$_tail" == *"401 Unauthorized"* ]]; then
      _pfail "codex auth expired — run: codex login && ./scripts/sync_codex_oauth.sh && ./scripts/inject_n8n_secrets.sh"
      return 1
    fi
    _pfail "codex CLI failed${_tail:+: ${_tail}}"
    return 1
  fi
  rm -f "$_codex_err"
  return 0
}

invoke_codex_cli() {
  [[ -d "$SKILL_DIR" ]] || { _pfail "codex: skill dir missing: $SKILL_DIR"; return 1; }
  local f
  for f in $(required_skill_files); do
    [[ -f "${SKILL_DIR}/${f}" ]] || { _pfail "codex: missing ${SKILL_DIR}/${f}"; return 1; }
  done
  command -v "$BINARY" >/dev/null 2>&1 || { _pfail "codex: binary not found: $BINARY"; return 1; }

  local prompt
  prompt="$(build_prompt)"
  run_codex_exec "$prompt" || return 1
  if [[ "$ENGINE" == "svg_artist" ]]; then
    svg_output_ready || { _pfail "codex: image not created at ${OUT_FILE} (or post.png in $RUN_DIR)"; return 1; }
  else
    [[ -f "$OUT_FILE" ]] || { _pfail "codex: output not created: $OUT_FILE"; return 1; }
  fi
}

normalize_svg_output() {
  local path="$1"
  [[ -f "$path" ]] || return 0
  python3 - "$path" <<'PY'
import re
import sys
from pathlib import Path

SVG_HEADER = (
    '<svg xmlns="http://www.w3.org/2000/svg" '
    'width="1080" height="1080" viewBox="0 0 1080 1080">'
)


def is_svg_line(line: str) -> bool:
    s = line.strip()
    if not s:
        return False
    if s.startswith("<!--"):
        return True
    if re.match(r"</?[\w!?]", s):
        return True
    if re.match(r'^[a-z][a-z0-9:-]*="', s, flags=re.IGNORECASE):
        return True
    return False


def fix_orphan_attrs(line: str) -> str:
    s = line.lstrip()
    if re.match(r"^cy=", s) or (re.search(r'\br="', s) and not s.startswith("<")):
        if not s.startswith("<"):
            s = "<circle cx=\"540\" " + s
        if not s.rstrip().endswith("/>") and not s.rstrip().endswith(">"):
            s = s.rstrip() + "/>"
    return s


def wrap_fragment(body: str) -> str:
    lines = [ln for ln in body.splitlines() if ln.strip().lower() != "</svg>"]
    inner = "\n".join(fix_orphan_attrs(ln) for ln in lines)
    return f"{SVG_HEADER}\n{inner}\n</svg>\n"


def extract_svg(text: str) -> str:
    text = text.strip()
    if not text:
        return ""

    m = re.search(r"<svg[\s\S]*?</svg>", text, flags=re.IGNORECASE)
    if m:
        return m.group(0).strip() + "\n"

    m = re.search(r"```(?:svg|xml)?\s*([\s\S]*?)```", text, flags=re.IGNORECASE)
    if m and m.group(1).strip():
        return extract_svg(m.group(1))

    end = text.lower().rfind("</svg>")
    if end >= 0:
        chunk = text[: end + len("</svg>")]
        lines = chunk.splitlines()
        start = next((i for i, ln in enumerate(lines) if is_svg_line(ln)), None)
        if start is not None:
            body = "\n".join(lines[start:])
            if re.search(r"<svg\b", body, flags=re.IGNORECASE):
                return body.strip() + "\n"
            return wrap_fragment(body)

    svg_lines = [ln for ln in text.splitlines() if is_svg_line(ln)]
    if svg_lines:
        body = "\n".join(fix_orphan_attrs(ln) for ln in svg_lines)
        if re.search(r"<svg\b", body, flags=re.IGNORECASE):
            return body.strip() + "\n"
        return wrap_fragment(body)

    text = re.sub(r"^```(?:svg|xml)?\s*", "", text, flags=re.IGNORECASE)
    text = re.sub(r"\s*```$", "", text, flags=re.IGNORECASE)
    return text.strip() + ("\n" if text.strip() else "")


p = Path(sys.argv[1])
out = extract_svg(p.read_text(encoding="utf-8", errors="ignore"))
if out:
    p.write_text(out, encoding="utf-8")
PY
}

svg_is_valid() {
  local path="$1"
  [[ -s "$path" ]] || return 1
  normalize_svg_output "$path"
  command -v xmllint >/dev/null 2>&1 || return 0
  xmllint --noout "$path" 2>/dev/null
}

gemini_dir_has_auth() {
  local d="$1"
  [[ -d "$d" ]] || return 1
  [[ -f "${d}/.env" ]] && grep -qE '^GEMINI_API_KEY=' "${d}/.env" 2>/dev/null && return 0
  [[ -f "${d}/oauth_creds.json" ]] && return 0
  [[ -s "${d}/google_accounts.json" ]] && return 0
  return 1
}

gemini_has_auth() {
  [[ -n "${GEMINI_API_KEY:-}" ]] && return 0
  local d
  for d in \
    "${HOME:-}/.gemini" \
    "${DATA_ROOT}/secrets/gemini" \
    "${REPO_ROOT}/data/secrets/gemini" \
    "${GEMINI_CONFIG_DIR:-}"; do
    [[ -n "$d" ]] && gemini_dir_has_auth "$d" && return 0
  done
  return 1
}

gemini_auth_hint() {
  if gemini_dir_has_auth "${HOME:-}/.gemini" \
    && ! gemini_dir_has_auth "${DATA_ROOT}/secrets/gemini" \
    && ! gemini_dir_has_auth "${REPO_ROOT}/data/secrets/gemini"; then
    echo "OAuth is in ~/.gemini but not data/secrets/gemini — run: ./scripts/sync_gemini_oauth.sh && docker compose restart n8n"
  else
    echo "set GEMINI_API_KEY in .env, or run 'gemini' login then ./scripts/sync_gemini_oauth.sh"
  fi
}

gemini_prepare_home() {
  local secrets=""
  for secrets in "${DATA_ROOT}/secrets/gemini" "${REPO_ROOT}/data/secrets/gemini"; do
    gemini_dir_has_auth "$secrets" && break
  done
  [[ -n "$secrets" ]] && gemini_dir_has_auth "$secrets" || return 0

  if gemini_dir_has_auth "${HOME:-}/.gemini"; then
    return 0
  fi

  local ghome="${HOME:-}/.gemini"
  mkdir -p "$ghome"
  local f
  for f in oauth_creds.json google_accounts.json settings.json installation_id projects.json trustedFolders.json .env; do
    [[ -f "${secrets}/${f}" ]] && install -m 600 "${secrets}/${f}" "${ghome}/${f}"
  done
}

invoke_gemini_cli() {
  [[ -d "$SKILL_DIR" ]] || { _pfail "gemini: skill dir missing: $SKILL_DIR"; return 1; }
  command -v "$BINARY" >/dev/null 2>&1 || { _pfail "gemini: binary not found: $BINARY"; return 1; }
  gemini_has_auth || { _pfail "gemini_cli not authenticated: $(gemini_auth_hint)"; return 1; }
  gemini_prepare_home
  export GEMINI_CLI_TRUST_WORKSPACE="${GEMINI_CLI_TRUST_WORKSPACE:-true}"

  local f prompt
  for f in $(required_skill_files); do
    [[ -f "${SKILL_DIR}/${f}" ]] || { _pfail "gemini: missing ${SKILL_DIR}/${f}"; return 1; }
  done
  prompt="$(build_gemini_prompt)"

  if [[ "$ENGINE" == "svg_artist" ]]; then
    run_gemini_prompt "$prompt" || return 1
    if ! svg_output_ready; then
      local repair_prompt
      repair_prompt="Rewrite $(basename "$OUT_FILE") as a valid 1080x1080 PNG or JPEG only (max 8MB). No SVG. Use write_file."
      run_gemini_prompt "$repair_prompt" || true
    fi
    svg_output_ready || { _pfail "gemini: invalid image at ${OUT_FILE} (need PNG/JPEG <=8MB)"; return 1; }
    return 0
  fi

  run_gemini_prompt "$prompt" || return 1
  if [[ ! -s "$OUT_FILE" ]]; then
    run_gemini_prompt "$prompt" || { _pfail "gemini CLI failed (no output file)"; return 1; }
  fi
  [[ -f "$OUT_FILE" ]] || { _pfail "gemini: output not created: $OUT_FILE"; return 1; }
  if finalize_copywriter_output "$OUT_FILE"; then
    return 0
  fi
  local repair_prompt
  repair_prompt="Rewrite post.md ONLY as the final Traditional Chinese (zh-TW) social post per ${SKILL_DIR}/TEMPLATE.md and TASK.md. No English status report. No mention of files or verification steps. Overwrite post.md completely using write_file."
  run_gemini_prompt "$repair_prompt" || { _pfail "gemini: post.md quality check failed; repair failed"; return 1; }
  finalize_copywriter_output "$OUT_FILE" || { _pfail "gemini: post.md failed quality check after repair"; return 1; }
}

FAILOVER_LOG="${DATA_ROOT}/logs/engine_failover.jsonl"
mkdir -p "$(dirname "$FAILOVER_LOG")"

DEFAULT_COPY_FALLBACK="claude_cli gemini_cli codex_cli"
DEFAULT_SVG_FALLBACK="gemini_cli claude_cli"

log_failover() {
  local provider="$1" attempt="$2" ok="$3" err="${4:-}"
  python3 - "$FAILOVER_LOG" "$RUN_ID" "$ENGINE" "$provider" "$attempt" "$ok" "$err" <<'PY'
import json, sys
from datetime import datetime, timezone
path, run_id, engine, provider, attempt, ok, err = sys.argv[1:8]
row = {
    "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "log": "engine_failover",
    "run_id": run_id,
    "engine": engine,
    "provider": provider,
    "attempt": int(attempt),
    "ok": ok == "true",
    "error": err,
}
with open(path, "a", encoding="utf-8") as f:
    f.write(json.dumps(row, ensure_ascii=False) + "\n")
PY
}

read_fallback_chain() {
  local engine_key="$1"
  local defaults="$2"
  local from_runtime=""
  if [[ -f "$RUNTIME_JSON" ]] && command -v jq >/dev/null 2>&1; then
    from_runtime="$(jq -r ".engines.${engine_key}.fallback // [] | join(\" \")" "$RUNTIME_JSON" 2>/dev/null || true)"
  fi
  if [[ -n "${from_runtime// }" ]]; then
    echo "$from_runtime"
  else
    echo "$defaults"
  fi
}

invoke_provider() {
  local p="$1"
  PROVIDER="$p"
  case "$p" in
    claude_cli) BINARY="claude" ;;
    codex_cli) BINARY="codex" ;;
    gemini_cli) BINARY="gemini" ;;
    *) return 1 ;;
  esac
  case "$ENGINE" in
    copywriter)
      OUT_FILE="${RUN_DIR}/post.md"
      case "$p" in
        claude_cli) invoke_claude_cli ;;
        gemini_cli) invoke_gemini_cli ;;
        codex_cli) invoke_codex_cli ;;
        *) return 1 ;;
      esac
      ;;
    svg_artist)
      # Keep --out-file carousel/NN.png; do not reset to post.png mid-carousel.
      [[ -z "$IMAGE_OUT_FILE" ]] && OUT_FILE="${RUN_DIR}/post.png"
      case "$p" in
        codex_cli) invoke_codex_cli ;;
        gemini_cli) invoke_gemini_cli ;;
        claude_cli) invoke_claude_cli ;;
        *) return 1 ;;
      esac
      ;;
    *) return 1 ;;
  esac
}

invoke_with_failover() {
  local engine_key="$1"
  local primary="$2"
  local defaults="$3"
  local chain="${primary}"
  local extra
  extra="$(read_fallback_chain "$engine_key" "$defaults")"
  local seen="$primary"
  local p
  for p in $extra; do
    [[ " $seen " == *" $p "* ]] && continue
    chain="$chain $p"
    seen="$seen $p"
  done

  local attempt=0
  local last_err="no provider succeeded"
  for p in $chain; do
    case "$p" in
      claude_cli) command -v claude >/dev/null 2>&1 || continue ;;
      codex_cli) command -v codex >/dev/null 2>&1 || continue ;;
      gemini_cli) command -v gemini >/dev/null 2>&1 || continue ;;
    esac
    attempt=$((attempt + 1))
    if ! invoke_provider "$p"; then
      last_err="${p} failed"
      log_failover "$p" "$attempt" false "$last_err"
      continue
    fi
    if [[ "$ENGINE" == "copywriter" ]]; then
      if [[ ! -s "$OUT_FILE" ]]; then
        last_err="${p} empty output"
        log_failover "$p" "$attempt" false "$last_err"
        continue
      fi
      if ! finalize_copywriter_output "$OUT_FILE"; then
        last_err="${p} invalid post.md (meta chatter or insufficient zh-TW copy)"
        log_failover "$p" "$attempt" false "$last_err"
        continue
      fi
    fi
    if [[ "$ENGINE" == "svg_artist" ]]; then
      if ! svg_output_ready; then
        last_err="${p} missing or invalid image at ${OUT_FILE}"
        log_failover "$p" "$attempt" false "$last_err"
        continue
      fi
    fi
    log_failover "$p" "$attempt" true ""
    printf '{"ok":true,"path":"%s","provider_used":"%s"}\n' "$OUT_FILE" "$p"
    return 0
  done
  json_err "all providers failed for ${ENGINE}: ${last_err} (tried: ${chain})"
}

case "$ENGINE" in
  copywriter)
    primary="$(engine_provider copy)"
    [[ -z "$primary" ]] && primary="claude_cli"
    invoke_with_failover "copy" "$primary" "$DEFAULT_COPY_FALLBACK"
    ;;
  svg_artist)
    primary="$(engine_provider svg)"
    [[ -z "$primary" ]] && primary="codex_cli"
    invoke_with_failover "svg" "$primary" "$DEFAULT_SVG_FALLBACK"
    ;;
  *)
    json_err "unknown engine: $ENGINE"
    ;;
esac
