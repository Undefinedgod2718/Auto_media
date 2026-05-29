#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
export AUTO_MEDIA_ROOT="$ROOT"
export DATA_ROOT="${DATA_ROOT:-$ROOT/data}"
exec python3 "$ROOT/scripts/hermes_telegram_gateway.py"
