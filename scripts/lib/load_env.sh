#!/usr/bin/env bash
# Load .env without bash expanding $ in token values.
load_repo_env() {
  local root="${1:-}"
  if [[ -z "$root" ]]; then
    echo "load_repo_env: root required" >&2
    return 1
  fi
  local env_file="${root}/.env"
  [[ -f "$env_file" ]] || return 0
  eval "$(
    ROOT="$root" python3 - <<'PY'
import os
import shlex
import sys
from pathlib import Path

root = Path(os.environ["ROOT"])
sys.path.insert(0, str(root / "scripts" / "lib"))
from env_store import parse_env

_, values = parse_env(root / ".env")
for key, val in values.items():
    print(f"export {key}={shlex.quote(val)}")
PY
  )"
}
