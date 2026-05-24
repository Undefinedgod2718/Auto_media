#!/usr/bin/env bash
# Environment diagnostic: Docker, Claude Code, Codex, uv, encoding.
set -uo pipefail

export LANG="${LANG:-C.UTF-8}"
export LC_ALL="${LC_ALL:-C.UTF-8}"

REPO_ROOT="${AUTO_MEDIA_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PASS=0
WARN=0
FAIL=0

check() {
  local level="$1" name="$2" detail="$3"
  case "$level" in
    pass) PASS=$((PASS + 1)); printf '[PASS] %s: %s\n' "$name" "$detail" ;;
    warn) WARN=$((WARN + 1)); printf '[WARN] %s: %s\n' "$name" "$detail" ;;
    fail) FAIL=$((FAIL + 1)); printf '[FAIL] %s: %s\n' "$name" "$detail" ;;
  esac
}

echo "=== Auto Media env-check ==="
echo "repo: $REPO_ROOT"
echo "locale: LANG=$LANG LC_ALL=$LC_ALL"

if command -v docker >/dev/null 2>&1; then
  check pass docker "$(docker --version 2>&1 | head -1)"
  if docker compose version >/dev/null 2>&1; then
    check pass docker-compose "$(docker compose version 2>&1 | head -1)"
  else
    check fail docker-compose "docker compose not available"
  fi
else
  check fail docker "docker not in PATH"
fi

if command -v uv >/dev/null 2>&1; then
  check pass uv "$(uv --version 2>&1)"
elif [[ -x "${REPO_ROOT}/.venv/bin/python" ]]; then
  check warn uv "uv missing; using existing .venv"
else
  check warn uv "install: curl -LsSf https://astral.sh/uv/install.sh | sh"
fi

if command -v python3 >/dev/null 2>&1; then
  enc="$(python3 -c 'import sys; print(sys.getdefaultencoding())' 2>/dev/null || echo unknown)"
  check pass python3 "$(python3 --version 2>&1) default_encoding=$enc"
else
  check fail python3 "python3 required for amctl apply"
fi

if command -v jq >/dev/null 2>&1; then
  check pass jq "$(jq --version 2>&1)"
else
  check warn jq "jq recommended on host; present in n8n image"
fi

if command -v claude >/dev/null 2>&1; then
  check pass claude-code "$(claude --version 2>&1 | head -1 || echo ok)"
elif [[ -d "${REPO_ROOT}/data/secrets/claude" ]]; then
  check warn claude-code "not in PATH; mount secrets and use container image"
else
  check warn claude-code "not found — set AUTO_MEDIA_MOCK=1 or build n8n image"
fi

if command -v codex >/dev/null 2>&1; then
  check pass codex "$(codex --version 2>&1 | head -1 || echo ok)"
else
  check warn codex "not in PATH — SVG may use mock until Codex installed in image"
fi

if command -v gemini >/dev/null 2>&1; then
  check pass gemini "$(gemini --version 2>&1 | head -1 || echo ok)"
else
  check warn gemini "not in PATH — optional; amctl engine copy|svg gemini_cli needs gemini"
fi

if command -v rsvg-convert >/dev/null 2>&1; then
  check pass rsvg "$(rsvg-convert --version 2>&1 | head -1)"
else
  check warn rsvg "host rsvg missing; available inside n8n container"
fi

if command -v hermes >/dev/null 2>&1; then
  check pass hermes "$(hermes --version 2>&1 | head -1 || echo installed)"
else
  check warn hermes "optional on host for Plan B — install via Hermes agent script on Linux"
fi

if [[ -f "${REPO_ROOT}/config/platform.yaml" ]]; then
  check pass platform-yaml "found"
else
  check fail platform-yaml "missing config/platform.yaml"
fi

if [[ -f "${REPO_ROOT}/data/config/platform.runtime.json" ]]; then
  check pass runtime-json "found (run amctl apply after edits)"
else
  check warn runtime-json "missing — run: ./scripts/amctl.sh apply"
fi

echo "--- summary: pass=$PASS warn=$WARN fail=$FAIL ---"
[[ $FAIL -eq 0 ]]
