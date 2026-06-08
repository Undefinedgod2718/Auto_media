#!/usr/bin/env bash
# Refresh the Threads long-lived access token (host job; run from a host cron).
#
# Threads tokens expire ~60 days. graph.threads.net/refresh_access_token extends
# an unexpired token that is at least 24h old to a fresh 60-day token. FB/IG do
# NOT use this — give them a non-expiring Meta System User token instead
# (see .env.example / docs).
#
# Safety: verify the NEW token works BEFORE writing it, so a bad response can
# never replace a working token (no self-inflicted outage). On any failure the
# .env is left untouched and the script exits non-zero without restarting n8n.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${ROOT}/scripts/lib/common.sh"
# shellcheck source=scripts/lib/load_env.sh
source "${ROOT}/scripts/lib/load_env.sh"

DRY_RUN=0
NO_RESTART=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --no-restart) NO_RESTART=1; shift ;;
    *) json_err "unknown arg: $1" ;;
  esac
done

load_repo_env "$ROOT"
LIB="${ROOT}/scripts/lib"
# Override only for tests/staging against a mock; defaults to the real API.
GRAPH="${THREADS_GRAPH_BASE:-https://graph.threads.net}"

if [[ -z "${THREADS_ACCESS_TOKEN:-}" || -z "${THREADS_USER_ID:-}" ]]; then
  echo "skip: THREADS_ACCESS_TOKEN or THREADS_USER_ID unset" >&2
  json_ok "skipped"
  exit 0
fi

REFRESH_URL="${GRAPH}/refresh_access_token?grant_type=th_refresh_token"

if [[ "$DRY_RUN" == "1" ]]; then
  echo "DRY RUN — would call: GET ${REFRESH_URL}&access_token=<redacted>" >&2
  echo "DRY RUN — would verify via secret_tests.test_threads, then update .env THREADS_ACCESS_TOKEN" >&2
  json_ok "dry-run"
  exit 0
fi

# argv-safe GET: token reaches curl via a --config fd (process substitution),
# never as a curl argument, so it does not appear in `ps aux`. printf is a bash
# builtin (no separate process), so the token is not in any process argv.
threads_get() {
  local url="$1" tok="$2"
  curl -sS --max-time 20 -G --config <(printf 'url = "%s"\ndata-urlencode = "access_token=%s"\n' "$url" "$tok")
}

RESP="$(threads_get "$REFRESH_URL" "$THREADS_ACCESS_TOKEN" || true)"

NEW_TOKEN="$(
  printf '%s' "$RESP" | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read() or "{}")
except json.JSONDecodeError:
    print("")
    raise SystemExit(0)
tok = d.get("access_token") or ""
print(tok if isinstance(tok, str) else "")
'
)"

if [[ -z "$NEW_TOKEN" ]]; then
  json_err "refresh failed (no access_token in response): ${RESP:0:200}"
fi

# Verify the NEW token before replacing the working one.
VERIFY="$(
  THREADS_NEW_TOKEN="$NEW_TOKEN" THREADS_UID="$THREADS_USER_ID" PYTHONPATH="$LIB" python3 -c '
import json, os, sys
import secret_tests
res = secret_tests.test_threads({
    "THREADS_ACCESS_TOKEN": os.environ["THREADS_NEW_TOKEN"],
    "THREADS_USER_ID": os.environ["THREADS_UID"],
})
print(json.dumps(res))
sys.exit(0 if res.get("ok") else 1)
' || true
)"

if ! printf '%s' "$VERIFY" | python3 -c 'import json,sys; sys.exit(0 if json.loads(sys.stdin.read() or "{}").get("ok") else 1)'; then
  json_err "new token failed verification, .env unchanged: ${VERIFY}"
fi

# Back up the old token, then write the new one atomically via env_store.
BAK="${ROOT}/data/secrets/threads_token.bak"
mkdir -p "$(dirname "$BAK")"
printf '%s\n' "$THREADS_ACCESS_TOKEN" > "$BAK"
chmod 600 "$BAK" 2>/dev/null || true

THREADS_NEW_TOKEN="$NEW_TOKEN" PYTHONPATH="$LIB" ROOT="$ROOT" python3 -c '
import os
from pathlib import Path
import env_store
env_store.update_env(Path(os.environ["ROOT"]) / ".env", {"THREADS_ACCESS_TOKEN": os.environ["THREADS_NEW_TOKEN"]})
'

# n8n reads THREADS_ACCESS_TOKEN at container start — restart to pick it up.
if [[ "$NO_RESTART" == "0" ]]; then
  if command -v docker >/dev/null 2>&1; then
    (cd "$ROOT" && docker compose up -d n8n) >&2 || echo "WARN: docker compose up -d n8n failed; restart n8n manually" >&2
  else
    echo "WARN: docker not found; restart n8n to load the new token" >&2
  fi
fi

json_ok "threads token refreshed"
