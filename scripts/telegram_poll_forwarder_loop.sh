#!/usr/bin/env bash
# Daemon loop: poll Telegram and forward to gateway/n8n.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Long-poll (timeout=25 in telegram_poll_forwarder.sh) already blocks waiting for
# updates, so this inter-tick sleep is a small backoff, not the poll cadence.
INTERVAL="${TELEGRAM_POLL_INTERVAL:-1}"
echo "telegram poll forwarder loop (long-poll; backoff=${INTERVAL}s)" >&2
while true; do
  bash "${ROOT}/scripts/telegram_poll_forwarder.sh" 2>&1 || true
  sleep "$INTERVAL"
done
