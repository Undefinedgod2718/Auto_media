#!/usr/bin/env bash
# Exit 0 if platform is in TASK publish_targets (or publish_targets unset → allow).
set -euo pipefail
RUN_DIR="${1:?run_dir}"
PLATFORM="${2:?platform}" # instagram | threads | facebook

TASK="${RUN_DIR}/TASK.md"
if [[ ! -f "$TASK" ]]; then
  exit 0
fi
if ! grep -qi '^publish_targets:' "$TASK"; then
  exit 0
fi
if grep -i '^publish_targets:' "$TASK" | grep -qi "$PLATFORM"; then
  exit 0
fi
exit 1
