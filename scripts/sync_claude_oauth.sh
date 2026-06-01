#!/usr/bin/env bash
# Copy Claude Code OAuth into data/secrets/claude for n8n (CLAUDE_CONFIG_DIR=/data/secrets/claude).
set -euo pipefail

REPO_ROOT="${AUTO_MEDIA_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SRC="${1:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}"
DEST="${REPO_ROOT}/data/secrets/claude"

if [[ ! -d "$SRC" ]]; then
  echo '{"ok":false,"error":"source missing: '"$SRC"' — run: claude (login)"}' >&2
  exit 1
fi

if [[ ! -f "${SRC}/.credentials.json" ]]; then
  echo '{"ok":false,"error":"no .credentials.json in '"$SRC"' — run: claude then /login"}' >&2
  exit 1
fi

mkdir -p "$DEST"
for f in .credentials.json settings.json; do
  [[ -f "${SRC}/${f}" ]] && install -m 600 "${SRC}/${f}" "${DEST}/${f}"
done

if [[ ! -f "${DEST}/.credentials.json" ]]; then
  echo '{"ok":false,"error":"sync failed"}' >&2
  exit 1
fi

echo '{"ok":true,"dest":"'"$DEST"'","hint":"docker compose restart n8n"}'
