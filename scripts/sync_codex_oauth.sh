#!/usr/bin/env bash
# Copy Codex CLI OAuth into data/secrets/codex for n8n (mount → /home/node/.codex).
set -euo pipefail

REPO_ROOT="${AUTO_MEDIA_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SRC="${1:-${CODEX_HOME:-$HOME/.codex}}"
DEST="${REPO_ROOT}/data/secrets/codex"

if [[ ! -d "$SRC" ]]; then
  echo '{"ok":false,"error":"source missing: '"$SRC"' — run codex login first"}' >&2
  exit 1
fi

if [[ ! -f "${SRC}/auth.json" ]]; then
  echo '{"ok":false,"error":"no auth.json in '"$SRC"' — run: codex login"}' >&2
  exit 1
fi

mkdir -p "$DEST"
for f in auth.json config.toml installation_id; do
  [[ -f "${SRC}/${f}" ]] && install -m 600 "${SRC}/${f}" "${DEST}/${f}"
done

if [[ ! -f "${DEST}/auth.json" ]]; then
  echo '{"ok":false,"error":"sync failed: auth.json not in dest"}' >&2
  exit 1
fi

echo '{"ok":true,"dest":"'"$DEST"'","hint":"./scripts/inject_n8n_secrets.sh (Docker Desktop may not show bind-mount files in n8n until inject)"}'
