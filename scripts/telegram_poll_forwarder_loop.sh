#!/usr/bin/env bash
# Daemon loop: poll Telegram and forward to gateway/n8n.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INTERVAL="${TELEGRAM_POLL_INTERVAL:-2}"
echo "telegram poll forwarder loop (interval=${INTERVAL}s)" >&2
while true; do
  bash "${ROOT}/scripts/telegram_poll_forwarder.sh" 2>&1 || true
  sleep "$INTERVAL"
done
