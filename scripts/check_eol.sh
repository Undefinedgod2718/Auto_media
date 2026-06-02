#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STRICT="${CHECK_EOL_STRICT:-0}"
python3 - "$ROOT" "$STRICT" <<'PY'
import sys
from pathlib import Path

root = Path(sys.argv[1])
strict = sys.argv[2] == "1"
exts = {".sh", ".py", ".md", ".json", ".yaml", ".yml"}
bad = []
for base in (root / "scripts", root / "config"):
    if not base.is_dir():
        continue
    for p in base.rglob("*"):
        if not p.is_file() or p.suffix.lower() not in exts:
            continue
        try:
            b = p.read_bytes()
        except OSError:
            continue
        if b"\r\n" in b:
            bad.append(p)
if bad:
    for p in bad:
        print(f"CRLF detected: {p.relative_to(root)}", file=sys.stderr)
    if strict:
        raise SystemExit(1)
    print(f"eol: warn ({len(bad)} files with CRLF)", file=sys.stderr)
    raise SystemExit(0)
print("eol: ok")
PY
