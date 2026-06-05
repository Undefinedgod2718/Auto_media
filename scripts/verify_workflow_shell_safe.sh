#!/usr/bin/env bash
# Fail if any n8n executeCommand command contains an unsafe {{ }} interpolation.
#
# Shell-injection lockdown (Option B): the ONLY interpolations allowed inside an
# executeCommand `command` are
#   1. the validated run_id from "Set run context"
#        {{ $('Set run context').item.json.run_id }}
#   2. base64-wrapped values (base64 alphabet is shell-safe in double quotes)
#        {{ Buffer.from(...).toString('base64') }}
# Anything else (topic, $json.body, callback, AI scalars, …) must NOT reach a
# command string. Usage: verify_workflow_shell_safe.sh [workflow.json ...]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ $# -gt 0 ]]; then
  FILES=("$@")
else
  FILES=("$ROOT"/workflows/*.json)
fi

python3 - "${FILES[@]}" <<'PY'
import json
import re
import sys

# Allowed {{ ... }} forms (whole-expression match between {{ and }}).
ALLOWED = [
    re.compile(r"^\$\(\s*'Set run context'\s*\)\.item\.json\.run_id$"),
    re.compile(r"^Buffer\.from\(.*\)\.toString\(\s*'base64'\s*\)$"),
]
INTERP = re.compile(r"\{\{\s*(.*?)\s*\}\}", re.S)

violations = []
for path in sys.argv[1:]:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    for node in data.get("nodes", []):
        if node.get("type") != "n8n-nodes-base.executeCommand":
            continue
        cmd = node.get("parameters", {}).get("command", "")
        for m in INTERP.finditer(cmd):
            expr = m.group(1)
            if not any(p.match(expr) for p in ALLOWED):
                violations.append((path, node.get("name", "?"), expr))

if violations:
    print("UNSAFE interpolation in executeCommand command(s):", file=sys.stderr)
    for path, name, expr in violations:
        fn = path.replace("\\", "/").rsplit("/", 1)[-1]
        print(f"  {fn} :: {name} :: {{{{ {expr} }}}}", file=sys.stderr)
    sys.exit(1)

print("OK: no unsafe interpolation in executeCommand commands")
PY
