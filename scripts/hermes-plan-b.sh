#!/usr/bin/env bash
# Plan B entry: run when api_dead.json exists (Linux host, not inside n8n).
set -euo pipefail

export LANG="${LANG:-C.UTF-8}"
export LC_ALL="${LC_ALL:-C.UTF-8}"

REPO_ROOT="${AUTO_MEDIA_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export AUTO_MEDIA_ROOT="$REPO_ROOT"
source "${REPO_ROOT}/scripts/lib/common.sh"

SIGNAL="${DATA_ROOT}/logs/api_dead.json"
PROFILE="${DATA_ROOT}/browser_profiles/meta"

if [[ ! -f "$SIGNAL" ]]; then
  log_json info "no api_dead signal; nothing to do"
  exit 0
fi

log_json info "api_dead present; starting Plan B supervisor"
cat "$SIGNAL"

if ! command -v hermes >/dev/null 2>&1; then
  echo "error: hermes not installed — see docs/HERMES_SETUP.md" >&2
  exit 1
fi

[[ -d "$PROFILE" ]] || mkdir -p "$PROFILE"

cd "$REPO_ROOT"
# Hermes reads CONTEXT.md + skill meta-dom-publish; operator completes DOM steps.
exec hermes --workdir "$REPO_ROOT" \
  "Plan B: read ${SIGNAL} and config/hermes/skills/meta-dom-publish/SKILL.md. Publish via Playwright using profile ${PROFILE}. On success archive and clear api_dead.json."
