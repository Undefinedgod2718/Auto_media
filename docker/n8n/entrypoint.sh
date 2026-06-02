#!/usr/bin/env bash
set -euo pipefail
mkdir -p /data/runs /data/logs /data/hitl /data/hitl/feedback /home/node/.codex
if [[ -d /data/secrets/codex ]] && [[ -n "$(ls -A /data/secrets/codex 2>/dev/null || true)" ]]; then
  cp -a /data/secrets/codex/. /home/node/.codex/ 2>/dev/null || true
fi
chown -R node:node /data/runs /data/logs /data/hitl /home/node/.codex
exec runuser -u node -- "$@"
