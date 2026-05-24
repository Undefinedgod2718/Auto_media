#!/usr/bin/env bash
set -eo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

_py_runtime() {
  local engine="${1:-}" field="${2:-}"
  python3 - "$RUNTIME_JSON" "$engine" "$field" <<'PY'
import json, sys
from pathlib import Path

path, engine, field = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
if not path.exists():
    print("")
    sys.exit(0)
data = json.loads(path.read_text(encoding="utf-8"))
if field == "signal_file":
    pub = data.get("publish") or {}
    cb = pub.get("circuit_breaker") or {}
    print(cb.get("signal_file") or pub.get("signal_file") or "/data/logs/api_dead.json")
    sys.exit(0)
eng = (data.get("engines") or {}).get(engine) or {}
print(eng.get(field, ""))
PY
}

_runtime_field() {
  local engine="$1" field="$2"
  if [[ ! -f "$RUNTIME_JSON" ]]; then
    echo ""
    return 0
  fi
  if command -v jq >/dev/null 2>&1; then
    case "$field" in
      status) jq -r ".engines.${engine}.status // \"draft\"" "$RUNTIME_JSON" ;;
      skill_path) jq -r ".engines.${engine}.skill_path // \"\"" "$RUNTIME_JSON" ;;
      skill_mount) jq -r ".engines.${engine}.skill_mount // \"\"" "$RUNTIME_JSON" ;;
      provider) jq -r ".engines.${engine}.provider // \"\"" "$RUNTIME_JSON" ;;
      binary) jq -r ".engines.${engine}.binary // \"\"" "$RUNTIME_JSON" ;;
    esac
    return
  fi
  _py_runtime "$engine" "$field"
}

engine_status() {
  local engine="$1"
  local s
  s="$(_runtime_field "$engine" status)"
  echo "${s:-draft}"
}

engine_skill_path() {
  _runtime_field "$1" skill_path
}

engine_skill_mount() {
  _runtime_field "$1" skill_mount
}

engine_provider() {
  _runtime_field "$1" provider
}

engine_binary() {
  local engine="$1"
  if [[ "$engine" == "render" ]]; then
    _runtime_field "render" binary
  else
    _runtime_field "$engine" binary
  fi
}

runtime_signal_file() {
  if command -v jq >/dev/null 2>&1 && [[ -f "$RUNTIME_JSON" ]]; then
    jq -r '.paths.signal_file // .publish.circuit_breaker.signal_file // "/data/logs/api_dead.json"' \
      "$RUNTIME_JSON"
  else
    _py_runtime "" signal_file
  fi
}
