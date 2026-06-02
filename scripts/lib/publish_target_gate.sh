#!/usr/bin/env bash
# Exit codes:
# 0: allowed (in publish_targets / unset / no TASK)
# 1: denied (platform not in publish_targets)
# 2: gate error (bad args / unreadable TASK)
set -euo pipefail
RUN_DIR="${1:-}"
PLATFORM="${2:-}" # instagram | threads | facebook
if [[ -z "$RUN_DIR" || -z "$PLATFORM" ]]; then
  exit 2
fi

TASK="${RUN_DIR}/TASK.md"
if [[ ! -f "$TASK" ]]; then
  exit 0
fi
if [[ ! -r "$TASK" ]]; then
  exit 2
fi
if ! grep -qi '^publish_targets:' "$TASK"; then
  exit 0
fi
if grep -i '^publish_targets:' "$TASK" | grep -qi "$PLATFORM"; then
  exit 0
fi
exit 1
