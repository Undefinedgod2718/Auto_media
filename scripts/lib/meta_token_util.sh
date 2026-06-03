#!/usr/bin/env bash
# Classify Meta Graph token errors for publish scripts (skip vs hard fail).
is_meta_token_skip_msg() {
  local msg="${1,,}"
  [[ -n "$msg" ]] || return 1
  case "$msg" in
    *"session has expired"*) return 0 ;;
    *"error validating access token"*) return 0 ;;
    *"cannot parse access token"*) return 0 ;;
    *"invalid oauth access token"*) return 0 ;;
    *"code 190"*) return 0 ;;
    *"oauthexception"*) return 0 ;;
  esac
  return 1
}

# Page publish permission (#200) — skip so n8n node exits 0; see publish_facebook.json reason.
is_meta_publish_permission_skip_msg() {
  local msg="${1,,}"
  [[ -n "$msg" ]] || return 1
  case "$msg" in
    *pages_manage_posts*) return 0 ;;
    *pages_read_engagement*) return 0 ;;
    *"sufficient administrative permission"*) return 0 ;;
  esac
  return 1
}

# Instagram / Facebook Graph page publish requires a Page access token (usually EAA...).
is_page_access_token() {
  local tok="$1"
  [[ -n "$tok" && "$tok" == EAA* ]]
}
