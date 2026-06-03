#!/usr/bin/env bash
# Verify Meta / Threads access tokens before publish (OAuth error 190 = expired).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/load_env.sh
source "${ROOT}/scripts/lib/load_env.sh"
load_repo_env "$ROOT"
source "${ROOT}/scripts/lib/meta_token_util.sh"

STRICT="${VERIFY_META_STRICT:-1}"
errors=0
ran=0

if [[ -n "${META_PAGE_ACCESS_TOKEN:-}" ]] && ! is_page_access_token "${META_PAGE_ACCESS_TOKEN}"; then
  echo "FAIL: META_PAGE_ACCESS_TOKEN looks like Threads token (THAA...). IG/FB need Page token (EAA...)." >&2
  echo "  → Graph API Explorer: select your Facebook Page → Generate Access Token" >&2
  echo "  → Save EAA... to META_PAGE_ACCESS_TOKEN at http://127.0.0.1:8790/settings" >&2
  errors=$((errors + 1))
fi

check_token() {
  local label="$1"
  local token="$2"
  local url="$3"
  if [[ -z "$token" ]]; then
    echo "FAIL: ${label} not set in .env" >&2
    return 1
  fi
  local body ec
  body="$(curl -sS --max-time 20 "$url" 2>&1)" || ec=$?
  ec="${ec:-0}"
  if [[ "$ec" -ne 0 ]]; then
    echo "FAIL: ${label}: curl failed (${ec}): ${body}" >&2
    return 1
  fi

  local parse status msg
  parse="$(python3 -c '
import json, sys
raw = sys.stdin.read()
try:
    d = json.loads(raw)
except json.JSONDecodeError:
    print("PARSE_FAIL")
    raise SystemExit(0)
err = d.get("error")
if err:
    print("ERR")
    print((err.get("message") or "unknown").replace("\n", " "))
else:
    print("OK")
' <<<"$body")"
  status="$(printf '%s\n' "$parse" | sed -n '1p')"
  msg="$(printf '%s\n' "$parse" | sed -n '2p')"

  if [[ "$status" == "PARSE_FAIL" ]]; then
    echo "FAIL: ${label}: non-JSON response: ${body}" >&2
    return 1
  fi
  if [[ "$status" == "ERR" ]]; then
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
  ran=$((ran + 1))
  check_token "THREADS_ACCESS_TOKEN" "$THREADS_ACCESS_TOKEN" \
    "https://graph.threads.net/v1.0/${THREADS_USER_ID}?fields=id,username&access_token=${THREADS_ACCESS_TOKEN}" \
    || errors=$((errors + 1))
else
  echo "skip THREADS (THREADS_USER_ID or THREADS_ACCESS_TOKEN unset)" >&2
fi

check_page_publish_scopes() {
  local token="$1"
  local app_id="${META_APP_ID:-}"
  local app_secret="${META_APP_SECRET:-}"
  if [[ -z "$app_id" || -z "$app_secret" ]]; then
    echo "HINT: FB publish needs Page token scopes pages_manage_posts + pages_read_engagement" >&2
    echo "  → Graph API Explorer: select Page → generate EAA token with those permissions" >&2
    echo "  → Optional: set META_APP_ID + META_APP_SECRET for automatic scope check" >&2
    return 0
  fi
  local ver="${META_GRAPH_API_VERSION:-v21.0}"
  local body
  body="$(curl -sS --max-time 20 -G "https://graph.facebook.com/${ver}/debug_token" \
    --data-urlencode "input_token=${token}" \
    --data-urlencode "access_token=${app_id}|${app_secret}" 2>&1)" || true
  local missing
  missing="$(python3 -c '
import json, sys
raw = sys.stdin.read()
need = {"pages_manage_posts", "pages_read_engagement"}
try:
    d = json.loads(raw)
except json.JSONDecodeError:
    print("DEBUG_FAIL")
    raise SystemExit(0)
err = d.get("error")
if err:
    print("DEBUG_ERR")
    print((err.get("message") or "debug_token failed").replace("\n", " "))
    raise SystemExit(0)
data = d.get("data") or {}
raw_scopes = data.get("scopes") or []
scopes = set()
for s in raw_scopes:
    if isinstance(s, str):
        scopes.add(s)
    elif isinstance(s, dict):
        scopes.add(s.get("permission") or s.get("scope") or "")
for g in data.get("granular_scopes") or []:
    if isinstance(g, dict):
        scopes.add(g.get("scope", ""))
scopes.discard("")
missing = sorted(need - scopes)
if missing:
    print("MISSING")
    print(",".join(missing))
else:
    print("OK")
' <<<"$body")"
  local st msg
  st="$(printf '%s\n' "$missing" | sed -n '1p')"
  msg="$(printf '%s\n' "$missing" | sed -n '2p')"
  case "$st" in
    OK) echo "ok META_PAGE publish scopes (pages_manage_posts, pages_read_engagement)" ;;
    MISSING)
      echo "FAIL: META_PAGE_ACCESS_TOKEN missing scopes: ${msg}" >&2
      echo "  → Re-generate Page token in Graph API Explorer with required permissions" >&2
      return 1
      ;;
    DEBUG_ERR|DEBUG_FAIL)
      echo "WARN: could not verify Page publish scopes (${msg:-parse error})" >&2
      echo "HINT: FB feed/photo needs pages_manage_posts + pages_read_engagement" >&2
      return 0
      ;;
  esac
}

if [[ -n "${META_PAGE_ACCESS_TOKEN:-}" && -n "${META_PAGE_ID:-}" ]] && is_page_access_token "${META_PAGE_ACCESS_TOKEN}"; then
  ran=$((ran + 1))
  ver="${META_GRAPH_API_VERSION:-v21.0}"
  check_token "META_PAGE_ACCESS_TOKEN" "$META_PAGE_ACCESS_TOKEN" \
    "https://graph.facebook.com/${ver}/${META_PAGE_ID}?fields=id,name&access_token=${META_PAGE_ACCESS_TOKEN}" \
    || errors=$((errors + 1))
  check_page_publish_scopes "${META_PAGE_ACCESS_TOKEN}" || errors=$((errors + 1))
elif [[ -n "${META_PAGE_ACCESS_TOKEN:-}" || -n "${META_PAGE_ID:-}" ]]; then
  echo "skip META_PAGE (wrong token type or missing PAGE_ID)" >&2
else
  echo "skip META_PAGE (META_PAGE_ID or META_PAGE_ACCESS_TOKEN unset)" >&2
fi

if [[ -n "${IG_USER_ID:-}" && -n "${META_PAGE_ACCESS_TOKEN:-}" ]] && is_page_access_token "${META_PAGE_ACCESS_TOKEN}"; then
  ran=$((ran + 1))
  ver="${META_GRAPH_API_VERSION:-v21.0}"
  check_token "IG_USER_ID" "$META_PAGE_ACCESS_TOKEN" \
    "https://graph.facebook.com/${ver}/${IG_USER_ID}?fields=id,username&access_token=${META_PAGE_ACCESS_TOKEN}" \
    || errors=$((errors + 1))
  if [[ -n "${META_PAGE_ID:-}" ]]; then
    linked="$(curl -fsS --max-time 20 "https://graph.facebook.com/${ver}/${META_PAGE_ID}?fields=instagram_business_account&access_token=${META_PAGE_ACCESS_TOKEN}" 2>/dev/null \
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

if [[ "$ran" -eq 0 ]]; then
  echo "FAIL: no token checks ran — set THREADS_* and/or META_PAGE_* / IG_USER_ID in .env (use :8790/settings)" >&2
  python3 -c 'import json; print(json.dumps({"ok":False,"error":"all meta checks skipped","hint":"save tokens via http://127.0.0.1:8790/settings"}))'
  exit 1
fi

if [[ "$errors" -gt 0 ]]; then
  python3 -c 'import json; print(json.dumps({"ok":False,"error":"meta token validation failed","count":'"$errors"'}))'
  [[ "$STRICT" == "1" ]] && exit 1
  exit 0
fi
python3 -c 'print("{\"ok\":true,\"path\":\"verify_meta_tokens\"}")'
