#!/usr/bin/env bash
# Verify Meta / Threads access tokens before publish (OAuth error 190 = expired).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a

STRICT="${VERIFY_META_STRICT:-1}"
errors=0

check_token() {
  local label="$1"
  local token="$2"
  local url="$3"
  if [[ -z "$token" ]]; then
    echo "FAIL: ${label} not set in .env" >&2
    return 1
  fi
  local body http
  body="$(curl -fsS "$url" 2>&1)" && http=200 || http=$?
  if echo "$body" | grep -q '"error"'; then
    local msg
    msg="$(echo "$body" | python3 -c "import sys,json; d=json.load(sys.stdin); print((d.get('error') or {}).get('message','unknown'))" 2>/dev/null || echo "$body")"
    echo "FAIL: ${label}: ${msg}" >&2
    if echo "$msg" | grep -qi 'expired\|Session has expired\|code.: 190'; then
      echo "  → Refresh token: https://developers.facebook.com/tools/explorer/" >&2
      echo "  → Update .env then: docker compose up -d n8n  (or restart n8n)" >&2
    fi
    return 1
  fi
  echo "ok ${label}"
  return 0
}

if [[ -n "${THREADS_ACCESS_TOKEN:-}" && -n "${THREADS_USER_ID:-}" ]]; then
  check_token "THREADS_ACCESS_TOKEN" "$THREADS_ACCESS_TOKEN" \
    "https://graph.threads.net/v1.0/${THREADS_USER_ID}?fields=id,username&access_token=${THREADS_ACCESS_TOKEN}" \
    || errors=$((errors + 1))
else
  echo "skip THREADS (THREADS_USER_ID or THREADS_ACCESS_TOKEN unset)" >&2
fi

if [[ -n "${META_PAGE_ACCESS_TOKEN:-}" && -n "${META_PAGE_ID:-}" ]]; then
  ver="${META_GRAPH_API_VERSION:-v21.0}"
  check_token "META_PAGE_ACCESS_TOKEN" "$META_PAGE_ACCESS_TOKEN" \
    "https://graph.facebook.com/${ver}/${META_PAGE_ID}?fields=id,name&access_token=${META_PAGE_ACCESS_TOKEN}" \
    || errors=$((errors + 1))
else
  echo "skip META_PAGE (META_PAGE_ID or META_PAGE_ACCESS_TOKEN unset)" >&2
fi

if [[ -n "${IG_USER_ID:-}" && -n "${META_PAGE_ACCESS_TOKEN:-}" ]]; then
  ver="${META_GRAPH_API_VERSION:-v21.0}"
  check_token "IG_USER_ID" "$META_PAGE_ACCESS_TOKEN" \
    "https://graph.facebook.com/${ver}/${IG_USER_ID}?fields=id,username&access_token=${META_PAGE_ACCESS_TOKEN}" \
    || errors=$((errors + 1))
  if [[ -n "${META_PAGE_ID:-}" ]]; then
    linked="$(curl -fsS "https://graph.facebook.com/${ver}/${META_PAGE_ID}?fields=instagram_business_account&access_token=${META_PAGE_ACCESS_TOKEN}" 2>/dev/null \
      | python3 -c "import sys,json; d=json.load(sys.stdin); print((d.get('instagram_business_account') or {}).get('id',''))" 2>/dev/null || true)"
    if [[ -n "$linked" && "$linked" != "$IG_USER_ID" ]]; then
      echo "WARN: IG_USER_ID ($IG_USER_ID) != Page linked account ($linked)" >&2
    fi
  fi
else
  echo "skip IG (IG_USER_ID or META_PAGE_ACCESS_TOKEN unset)" >&2
fi

# n8n reads THREADS_* at container start — warn if running inside dev but compose not restarted.
if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -q 'n8n'; then
  n8n_tok="$(docker exec auto_media-n8n-1 printenv THREADS_ACCESS_TOKEN 2>/dev/null || true)"
  if [[ -n "${THREADS_ACCESS_TOKEN:-}" && -n "$n8n_tok" && "$THREADS_ACCESS_TOKEN" != "$n8n_tok" ]]; then
    echo "WARN: .env THREADS_ACCESS_TOKEN differs from auto_media-n8n-1 — run: docker compose up -d n8n" >&2
    errors=$((errors + 1))
  fi
fi

if [[ "$errors" -gt 0 ]]; then
  python3 -c 'import json; print(json.dumps({"ok":false,"error":"meta token validation failed","count":'"$errors"'}))'
  [[ "$STRICT" == "1" ]] && exit 1
  exit 0
fi
python3 -c 'print("{\"ok\":true,\"path\":\"verify_meta_tokens\"}")'
