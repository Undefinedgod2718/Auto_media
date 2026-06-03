#!/usr/bin/env bash
# Copy Gemini CLI OAuth cache into data/secrets/gemini for n8n (mount → /home/node/.gemini).
set -euo pipefail

REPO_ROOT="${AUTO_MEDIA_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SRC="${1:-${GEMINI_CONFIG_DIR:-$HOME/.gemini}}"
DEST="${REPO_ROOT}/data/secrets/gemini"

if [[ ! -d "$SRC" ]]; then
  echo '{"ok":false,"error":"source missing: '"$SRC"' — run gemini login first"}' >&2
  exit 1
fi

if [[ ! -f "${SRC}/oauth_creds.json" && ! -f "${SRC}/google_accounts.json" ]]; then
  echo '{"ok":false,"error":"no OAuth in '"$SRC"' — run: gemini"}' >&2
  exit 1
fi

mkdir -p "$DEST"
# OAuth + settings only; skip volatile tmp/history
for f in oauth_creds.json google_accounts.json settings.json installation_id projects.json trustedFolders.json; do
  [[ -f "${SRC}/${f}" ]] && install -m 600 "${SRC}/${f}" "${DEST}/${f}"
done
[[ -f "${SRC}/.env" ]] && install -m 600 "${SRC}/.env" "${DEST}/.env"

if [[ ! -f "${DEST}/oauth_creds.json" ]]; then
  echo '{"ok":false,"error":"sync failed: oauth_creds.json not in dest"}' >&2
  exit 1
fi

echo '{"ok":true,"dest":"'"$DEST"'","hint":"./scripts/inject_n8n_secrets.sh (Docker Desktop may not show bind-mount files in n8n until inject)"}'
