#!/usr/bin/env bash
set -euo pipefail
# Match n8n entrypoint: shared bind mounts must be writable by uid 1000 (node).
mkdir -p /data/runs /data/logs /data/hitl
chown -R 1000:1000 /data/runs /data/logs /data/hitl 2>/dev/null || true
exec runuser -u automedia -- "$@"
