#!/usr/bin/env bash
# Re-write .env lines that need quoting ($ in Meta/Threads tokens, etc.).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$ROOT" python3 - <<'PY'
import os
from pathlib import Path
import sys

root = Path(os.environ["ROOT"])
sys.path.insert(0, str(root / "scripts" / "lib"))
from env_store import ASSIGN_RE, _format_env_line, parse_env

path = root / ".env"
lines, values = parse_env(path)
idx = {m.group(1): i for i, line in enumerate(lines) if (m := ASSIGN_RE.match(line))}
changed = []
for key, val in values.items():
    if key not in idx or not val:
        continue
    new_line = _format_env_line(key, val)
    if lines[idx[key]] != new_line:
        lines[idx[key]] = new_line
        changed.append(key)
if not changed:
    print("no requote needed")
    raise SystemExit(0)
content = "\n".join(lines).rstrip("\n") + "\n"
tmp = path.with_suffix(path.suffix + ".tmp")
tmp.write_text(content, encoding="utf-8")
tmp.replace(path)
print("requoted:", ", ".join(changed))
PY
