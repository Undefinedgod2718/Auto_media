#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a

RUN_ID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-id) RUN_ID="$2"; shift 2 ;;
    *) json_err "unknown arg: $1" ;;
  esac
done
[[ -n "$RUN_ID" ]] || json_err "usage: validate_post_md.sh --run-id ID"

RUN_DIR="$(ensure_run_dir "$RUN_ID")"
POST="${RUN_DIR}/post.md"
[[ -f "$POST" ]] || json_err "missing post.md"

set +e
OUT="$(PYTHONPATH="$ROOT/scripts/lib" python3 "$ROOT/scripts/lib/validate_post_md.py" "$POST" --run-dir "$RUN_DIR" 2>&1)"
PY_EC=$?
set -e

# Always print JSON for n8n Execute Command (set -e must not swallow failed python exit in $()).
echo "$OUT"
if [[ "$PY_EC" -ne 0 && -z "$OUT" ]]; then
  json_err "validate_post_md.py failed (exit ${PY_EC})"
fi

if ! python3 -c 'import json,sys
try:
  sys.exit(0 if json.load(sys.stdin).get("ok") else 1)
except (json.JSONDecodeError, TypeError, AttributeError):
  sys.exit(1)
' <<<"$OUT"; then
  echo "validate_post_md: content/structure check failed" >&2
  if [[ "$OUT" == \{* ]]; then
    python3 -c 'import json,sys
d=json.load(sys.stdin)
for e in d.get("errors") or []:
    print(f"validate_post_md: {e}", file=sys.stderr)
for v in d.get("violations") or []:
    msg=v.get("message_zh") if isinstance(v,dict) else str(v)
    if msg:
        print(f"validate_post_md: {msg}", file=sys.stderr)
' <<<"$OUT" 2>/dev/null || true
  else
    echo "$OUT" >&2
    exit 1
  fi
  VIOLATIONS="$(python3 -c "import json,sys; d=json.load(sys.stdin); print(json.dumps(d.get('violations', [{'message_zh': e} for e in d.get('errors', [])]), ensure_ascii=False))" <<<"$OUT")"
  /bin/bash "$ROOT/scripts/notify_platform_limit.sh" --run-id "$RUN_ID" --phase pre_hitl \
    --violations-json "$VIOLATIONS" 2>/dev/null || true
  exit 1
fi
