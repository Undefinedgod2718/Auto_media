#!/usr/bin/env bash
# Integration test: dashboard /settings Save + Test APIs (localhost).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${AUTO_MEDIA_DASHBOARD_HOST:-127.0.0.1}"
PORT="${AUTO_MEDIA_DASHBOARD_PORT:-8790}"
BASE="http://${HOST}:${PORT}"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "OK: $*"; }

curl_json() {
  local method="$1" path="$2" body="${3:-}"
  local tmp hdr
  tmp="$(mktemp)"
  hdr="$(mktemp)"
  if [[ -n "$body" ]]; then
    curl -sS -D "$hdr" -o "$tmp" -X "$method" "${BASE}${path}" \
      -H "Content-Type: application/json" \
      -H "X-CSRF-Token: ${CSRF:-}" \
      -d "$body" || return 1
  else
    curl -sS -D "$hdr" -o "$tmp" -X "$method" "${BASE}${path}" \
      -H "X-CSRF-Token: ${CSRF:-}" || return 1
  fi
  HTTP_CODE="$(awk '/^HTTP/{code=$2} END{print code+0}' "$hdr")"
  RESP="$(cat "$tmp")"
  rm -f "$tmp" "$hdr"
}

echo "== settings dashboard test @ ${BASE} =="

curl -fsS "${BASE}/healthz" >/dev/null || fail "dashboard not up — run: bash scripts/open_user_ui.sh"

curl_json GET /api/csrf
[[ "$HTTP_CODE" == "200" ]] || fail "csrf http=$HTTP_CODE"
CSRF="$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['csrf'])" "$RESP")"
[[ -n "$CSRF" ]] || fail "empty csrf"
ok "csrf"

curl_json GET /api/settings/status
[[ "$HTTP_CODE" == "200" ]] || fail "status http=$HTTP_CODE"
ENV_PATH="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('env_path',''))" "$RESP")"
[[ "$ENV_PATH" == "${ROOT}/.env" ]] || fail "env_path mismatch: got=$ENV_PATH want=${ROOT}/.env"
ok "status env_path=${ENV_PATH}"

# empty save -> 400 (browser shows "Nothing to save" before POST; API still guarded)
curl_json POST /api/settings/update '{"updates":{}}'
[[ "$HTTP_CODE" == "400" ]] || fail "empty save expected 400 got $HTTP_CODE"
ok "empty save rejected"

# stale csrf -> 403
CSRF_BAK="$CSRF"
CSRF="stale-token-on-purpose"
curl_json POST /api/settings/update '{"updates":{"META_PAGE_ID":"1179641631893779"}}'
[[ "$HTTP_CODE" == "403" ]] || fail "stale csrf expected 403 got $HTTP_CODE"
CSRF="$CSRF_BAK"
ok "stale csrf rejected"

# save round-trip (restore prior value after)
PREV="$(grep -E '^META_PAGE_ACCESS_TOKEN=' "${ROOT}/.env" | head -1 | cut -d= -f2- || true)"
MARK="EAA_dashboard_test_$(date +%s)"
curl_json POST /api/settings/update "{\"updates\":{\"META_PAGE_ACCESS_TOKEN\":\"${MARK}\"}}"
[[ "$HTTP_CODE" == "200" ]] || fail "save http=$HTTP_CODE body=$RESP"
python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert d.get('ok'), d; assert 'META_PAGE_ACCESS_TOKEN' in d.get('changed',[]), d" "$RESP"
grep -q "^META_PAGE_ACCESS_TOKEN=${MARK}$" "${ROOT}/.env" || fail ".env not updated"
ok "save writes .env"
if [[ -n "$PREV" ]]; then
  curl_json POST /api/settings/update "{\"updates\":{\"META_PAGE_ACCESS_TOKEN\":\"${PREV}\"}}"
  [[ "$HTTP_CODE" == "200" ]] || fail "restore token http=$HTTP_CODE"
  ok "restored META_PAGE_ACCESS_TOKEN"
fi

curl_json GET /api/settings/status
META_SET="$(python3 -c "import json,sys; d=json.loads(sys.argv[1]);
rows={x['name']:x for x in d['fields']};
print('1' if rows['META_PAGE_ACCESS_TOKEN']['is_set'] else '0')" "$RESP")"
[[ "$META_SET" == "1" ]] || fail "status still unset after save"
ok "status is_set after save"

# meta test (may fail on bad/expired token — report only)
curl_json POST /api/settings/test '{"group":"meta","overrides":{}}'
[[ "$HTTP_CODE" == "200" ]] || fail "meta test http=$HTTP_CODE"
python3 -c "import json,sys; d=json.loads(sys.argv[1]);
assert 'checks' in d, d;
c=d['checks'][0];
print('meta_test_ok=' + str(c.get('ok')));
print('meta_test_msg=' + str(c.get('message',''))[:120])" "$RESP"
ok "meta test endpoint"

# HTML csrf matches API (simulates page load)
HTML="$(curl -fsS "${BASE}/settings")"
HTML_CSRF="$(python3 -c "import sys,re; h=open('/dev/stdin').read(); m=re.search(r'var csrfToken = \"([^\"]+)\"', h); print(m.group(1) if m else '')" <<<"$HTML")"
[[ "$HTML_CSRF" == "$CSRF" ]] || fail "HTML csrf != API csrf (hard-refresh /settings after restart)"
ok "HTML csrf matches API"

echo "== all settings dashboard checks passed =="
