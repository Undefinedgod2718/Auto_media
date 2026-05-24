#!/usr/bin/env bash
# Hermes cron (no-agent): detect api_dead.json; optional Plan B handoff.
# Exit 0 = no signal; exit 2 = signal present (for cron alerting / wrapper scripts).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

SIGNAL="${DATA_ROOT}/logs/api_dead.json"
AUTO_RUN="${AUTO_MEDIA_HERMES_AUTO:-0}"

if [[ ! -f "$SIGNAL" ]]; then
  log_json info "api_dead absent"
  exit 0
fi

log_json warn "api_dead present: $SIGNAL"
cat "$SIGNAL"

if [[ "$AUTO_RUN" == "1" ]]; then
  exec "$(dirname "${BASH_SOURCE[0]}")/hermes-plan-b.sh"
fi

exit 2
