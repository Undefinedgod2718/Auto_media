#!/usr/bin/env bash
# Runs after Dev Container is created (UTF-8).
set -eo pipefail

export LANG="${LANG:-C.UTF-8}"
export LC_ALL="${LC_ALL:-C.UTF-8}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export AUTO_MEDIA_ROOT="$REPO_ROOT"
cd "$REPO_ROOT"

chmod +x scripts/*.sh scripts/lib/*.sh 2>/dev/null || true

if command -v uv >/dev/null 2>&1; then
  uv sync
else
  echo "warn: uv not found; skip Python sync" >&2
fi

install_codex_fallback() {
  if command -v codex >/dev/null 2>&1; then
    return 0
  fi
  if [[ "${INSTALL_CODEX:-true}" != "true" ]]; then
    return 0
  fi
  echo "codex not in PATH; trying npm fallback..." >&2
  export NVM_DIR="${NVM_DIR:-/usr/local/share/nvm}"
  # shellcheck source=/dev/null
  [[ -s "$NVM_DIR/nvm.sh" ]] && . "$NVM_DIR/nvm.sh"
  if command -v npm >/dev/null 2>&1; then
    npm install -g @openai/codex@latest
  else
    echo "warn: npm missing; skip codex fallback" >&2
    return 1
  fi
}

install_codex_fallback || true

install_gemini_fallback() {
  if command -v gemini >/dev/null 2>&1; then
    return 0
  fi
  if [[ "${INSTALL_GEMINI:-true}" != "true" ]]; then
    return 0
  fi
  echo "gemini not in PATH; trying npm install..." >&2
  export NVM_DIR="${NVM_DIR:-/usr/local/share/nvm}"
  # shellcheck source=/dev/null
  [[ -s "$NVM_DIR/nvm.sh" ]] && . "$NVM_DIR/nvm.sh"
  if command -v npm >/dev/null 2>&1; then
    npm install -g @google/gemini-cli@latest
  else
    echo "warn: npm missing; skip gemini fallback" >&2
    return 1
  fi
}

install_gemini_fallback || true

if [[ -x scripts/amctl.sh ]]; then
  if command -v claude >/dev/null 2>&1 \
    && command -v codex >/dev/null 2>&1 \
    && command -v gemini >/dev/null 2>&1; then
    ./scripts/amctl.sh apply || true
  else
    AUTO_MEDIA_ALLOW_MISSING_CLI=1 ./scripts/amctl.sh apply || true
  fi
  ./scripts/amctl.sh skill validate || true
fi

echo "Dev container ready."
echo "  1) claude          — Claude Code 登入 (ChatGPT OAuth)"
echo "  2) codex           — Codex SVG 登入 (ChatGPT OAuth)"
echo "  3) gemini          — Gemini CLI 登入 (Google 或 GEMINI_API_KEY，見 docs/GEMINI_CLI.md)"
echo "  4) amctl status    — 檢查平台狀態"
echo "  5) sudo docker compose up -d  — 啟動 n8n"
echo "  n8n 產線請見 docs/N8N_WORKFLOW_SETUP.md（網頁建立 workflow，無需匯入 JSON）"
