#!/usr/bin/env bash
# Canonical dashboard health check (8790). Fix: bash scripts/open_user_ui.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${AUTO_MEDIA_DASHBOARD_HOST:-127.0.0.1}"
PORT="${AUTO_MEDIA_DASHBOARD_PORT:-8790}"
LEGACY_PORT=8788
DASH_PY="${ROOT}/scripts/am_dashboard.py"
FIX_HINT="bash scripts/open_user_ui.sh"

fail() {
  echo "check_dashboard: FAIL — $*" >&2
  echo "fix: ${FIX_HINT}" >&2
  exit 1
}

expected_rev() {
  python3 -c "
import re, pathlib
text = pathlib.Path('${DASH_PY}').read_text(encoding='utf-8')
m = re.search(r'^INSTANCE_REV\\s*=\\s*[\"\\']([^\"\\']+)[\"\\']', text, re.M)
if not m:
    raise SystemExit('INSTANCE_REV not found in am_dashboard.py')
print(m.group(1))
" 2>/dev/null || fail "could not read INSTANCE_REV from ${DASH_PY}"
}

if curl -fsS --max-time 2 "http://${HOST}:${LEGACY_PORT}/healthz" >/dev/null 2>&1; then
  fail "legacy :${LEGACY_PORT} still responds (use :${PORT} only)"
fi

if ! curl -fsS --max-time 5 "http://${HOST}:${PORT}/healthz" >/dev/null 2>&1; then
  fail "dashboard not up on :${PORT}"
fi

EXPECTED="$(expected_rev)"
INST="$(curl -fsS --max-time 5 "http://${HOST}:${PORT}/api/instance" 2>/dev/null)" || fail "/api/instance unreachable"

ACTUAL="$(echo "$INST" | python3 -c "
import json, sys
d = json.load(sys.stdin)
if not d.get('ok'):
    raise SystemExit('instance ok=false')
port = int(d.get('port', 0))
if port != int(sys.argv[1]):
    raise SystemExit(f'port={port} expected {sys.argv[1]}')
rev = d.get('instance_rev', '')
if rev != sys.argv[2]:
    raise SystemExit(f'instance_rev={rev!r} expected {sys.argv[2]!r}')
print(rev)
" "$PORT" "$EXPECTED")" || fail "$ACTUAL"

if ! curl -fsS --max-time 5 -o /dev/null "http://${HOST}:${PORT}/engines"; then
  fail "/engines not reachable"
fi

echo "check_dashboard: OK (port=${PORT} rev=${ACTUAL})"
