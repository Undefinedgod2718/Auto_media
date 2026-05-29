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
    OUT_FILE="${RUN_DIR}/art.svg"
    ;;
esac

# Recoverable provider failure: log to stderr and signal the failover loop.
# NEVER json_err (exit) inside a provider — that aborts the whole chain.
_pfail() {
  echo "provider-fail: $*" >&2
  return 1
}

# Skill files required for the current engine (provider-independent).
required_skill_files() {
  if [[ "$ENGINE" == "copywriter" ]]; then
    echo "SKILL.md BRAND.md TEMPLATE.md"
  else
    echo "SKILL.md PALETTE.md RULES.md"
  fi
}

# Engine-aware prompt shared by every provider, so each provider produces the
# right artifact (copy → post.md, svg → art.svg) instead of being aliased away.
build_prompt() {
  if [[ "$ENGINE" == "copywriter" ]]; then
    printf '%s' "Read system instructions from ${SKILL_DIR}/SKILL.md. Apply brand voice from ${SKILL_DIR}/BRAND.md. Read task from ${TASK_FILE}. Format output per ${SKILL_DIR}/TEMPLATE.md. Write final output ONLY to ${OUT_FILE}. Do not print conversational text to stdout."
  else
    printf '%s' "Read ${SKILL_DIR}/SKILL.md, ${SKILL_DIR}/PALETTE.md, ${SKILL_DIR}/RULES.md and task ${TASK_FILE}. Write a complete valid W3C SVG document ONLY to ${OUT_FILE}. First line must be <svg or <?xml. viewBox 0 0 1080 1080. No external URLs. No stdout chatter."
  fi
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
  [[ -f "$OUT_FILE" ]] || { _pfail "claude: output not created: $OUT_FILE"; return 1; }
  if [[ "$ENGINE" == "svg_artist" ]]; then
    normalize_svg_output "$OUT_FILE"
    svg_is_valid "$OUT_FILE" || { _pfail "claude: invalid svg"; return 1; }
  fi
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
  "$BINARY" -y "$prompt" </dev/null >/dev/null 2>&1 || { _pfail "codex CLI failed"; return 1; }
  [[ -f "$OUT_FILE" ]] || { _pfail "codex: output not created: $OUT_FILE"; return 1; }
  if [[ "$ENGINE" == "svg_artist" ]]; then
    normalize_svg_output "$OUT_FILE"
    svg_is_valid "$OUT_FILE" || { _pfail "codex: invalid svg"; return 1; }
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
  # n8n /data/runs/* is not an interactive trusted folder — required for headless
  export GEMINI_CLI_TRUST_WORKSPACE="${GEMINI_CLI_TRUST_WORKSPACE:-true}"

  local prompt f
  if [[ "$ENGINE" == "copywriter" ]]; then
    for f in $(required_skill_files); do
      [[ -f "${SKILL_DIR}/${f}" ]] || { _pfail "gemini: missing ${SKILL_DIR}/${f}"; return 1; }
    done
    prompt="Read system instructions from ${SKILL_DIR}/SKILL.md. Apply brand voice from ${SKILL_DIR}/BRAND.md. Read task from ${TASK_FILE}. Format output per ${SKILL_DIR}/TEMPLATE.md. Write final output ONLY to ${OUT_FILE}. Do not print conversational text to stdout."
  else
    for f in $(required_skill_files); do
      [[ -f "${SKILL_DIR}/${f}" ]] || { _pfail "gemini: missing ${SKILL_DIR}/${f}"; return 1; }
    done
    prompt="Read ${SKILL_DIR}/SKILL.md, ${SKILL_DIR}/PALETTE.md, ${SKILL_DIR}/RULES.md and task ${TASK_FILE}. Write a complete valid W3C SVG document to ${OUT_FILE} using your file tool. ${OUT_FILE} must start with <svg or <?xml on line 1. viewBox 0 0 1080 1080. No external URLs. Do not write explanatory prose into ${OUT_FILE} or stdout."
  fi

  local _gemini_err _gemini_stdout
  _gemini_err="$(mktemp)"
  if [[ "$ENGINE" == "svg_artist" ]]; then
    if ! "$BINARY" -p "$prompt" -y --skip-trust </dev/null >/dev/null 2>"$_gemini_err"; then
      local _tail
      _tail="$(tail -3 "$_gemini_err" 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g')"
      rm -f "$_gemini_err"
      _pfail "gemini CLI failed${_tail:+: ${_tail}}"
      return 1
    fi
    if ! svg_is_valid "$OUT_FILE"; then
      _gemini_stdout="$(mktemp)"
      if "$BINARY" -p "$prompt" -y --skip-trust </dev/null >"$_gemini_stdout" 2>>"$_gemini_err"; then
        cp -f "$_gemini_stdout" "$OUT_FILE"
      fi
      rm -f "$_gemini_stdout"
      if ! svg_is_valid "$OUT_FILE"; then
        local repair_prompt
        repair_prompt="Rewrite ${OUT_FILE} as valid W3C SVG only (viewBox 0 0 1080 1080). First line must be <svg or <?xml. No prose. Use your file tool."
        "$BINARY" -p "$repair_prompt" -y --skip-trust </dev/null >/dev/null 2>>"$_gemini_err" || true
        svg_is_valid "$OUT_FILE" || true
      fi
    fi
    rm -f "$_gemini_err"
    [[ -f "$OUT_FILE" ]] || { _pfail "gemini: output not created: $OUT_FILE"; return 1; }
    svg_is_valid "$OUT_FILE" || { _pfail "gemini: invalid SVG XML"; return 1; }
    return 0
  fi

  if ! "$BINARY" -p "$prompt" -y --skip-trust </dev/null >"$OUT_FILE" 2>"$_gemini_err"; then
    local _tail
    _tail="$(tail -3 "$_gemini_err" 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g')"
    rm -f "$_gemini_err"
    _pfail "gemini CLI failed${_tail:+: ${_tail}}"
    return 1
  fi
  rm -f "$_gemini_err"
  if [[ ! -s "$OUT_FILE" ]]; then
    _gemini_err="$(mktemp)"
    if ! "$BINARY" -p "$prompt" --skip-trust </dev/null >"$OUT_FILE" 2>"$_gemini_err"; then
      local _tail
      _tail="$(tail -3 "$_gemini_err" 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g')"
      rm -f "$_gemini_err"
      _pfail "gemini CLI failed (no output file)${_tail:+: ${_tail}}"
      return 1
    fi
    rm -f "$_gemini_err"
  fi
  [[ -f "$OUT_FILE" ]] || { _pfail "gemini: output not created: $OUT_FILE"; return 1; }
}

FAILOVER_LOG="${DATA_ROOT}/logs/engine_failover.jsonl"
mkdir -p "$(dirname "$FAILOVER_LOG")"

DEFAULT_COPY_FALLBACK="claude_cli gemini_cli codex_cli"
DEFAULT_SVG_FALLBACK="codex_cli gemini_cli claude_cli"

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
      OUT_FILE="${RUN_DIR}/art.svg"
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
    attempt=$((attempt + 1))
    if ! invoke_provider "$p"; then
      last_err="${p} failed"
      log_failover "$p" "$attempt" false "$last_err"
      continue
    fi
    if [[ "$ENGINE" == "copywriter" && ! -s "$OUT_FILE" ]]; then
      last_err="${p} empty output"
      log_failover "$p" "$attempt" false "$last_err"
      continue
    fi
    if [[ "$ENGINE" == "svg_artist" ]] && ! svg_is_valid "$OUT_FILE"; then
      last_err="${p} invalid svg"
      log_failover "$p" "$attempt" false "$last_err"
      continue
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
