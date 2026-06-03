#!/usr/bin/env bash
# Executive installer: preflight → env → stack → verify (CLI, telegram, meta) → HITL.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export AUTO_MEDIA_ROOT="$ROOT"
export DATA_ROOT="${DATA_ROOT:-$ROOT/data}"

INSTALL_STATE="$DATA_ROOT/state/install.json"
SCHEMA_VERSION=1
MAX_RETRY="${WIZARD_VERIFY_RETRIES:-3}"
DASHBOARD_PORT="${AUTO_MEDIA_DASHBOARD_PORT:-8790}"
DRY_RUN="${WIZARD_DRY_RUN:-0}"

for _arg in "$@"; do
  case "$_arg" in
    --dry-run | -n) DRY_RUN=1 ;;
  esac
done

log() { echo "[wizard] $*" >&2; }

is_dry() { [[ "$DRY_RUN" == "1" ]]; }

DOCKER=(docker)
if command -v docker >/dev/null 2>&1; then
  :
elif sudo -n docker ps >/dev/null 2>&1; then
  DOCKER=(sudo docker)
fi

dry_run_list_missing() {
  local groups="$1"
  PYTHONPATH="$ROOT/scripts/lib" python3 "$ROOT/scripts/lib/wizard_prompt.py" \
    --env "$ROOT/.env" \
    $(for g in $groups; do echo --group "$g"; done) \
    --list-missing
}

load_install_state() {
  WIZARD_PREV_SCHEMA=0
  WIZARD_STACK_BUILT=0
  WIZARD_PREV_GIT_SHA=""
  if [[ ! -f "$INSTALL_STATE" ]]; then
    return 0
  fi
  eval "$(
    INSTALL_STATE="$INSTALL_STATE" python3 - <<'PY'
import json, os, shlex
from pathlib import Path
p = Path(os.environ["INSTALL_STATE"])
d = {}
if p.is_file():
    try:
        d = json.loads(p.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        pass
print(f"WIZARD_PREV_SCHEMA={int(d.get('schema_version', 0))}")
print(f"WIZARD_STACK_BUILT={1 if d.get('stack_built') else 0}")
print(f"WIZARD_PREV_GIT_SHA={shlex.quote(str(d.get('git_sha') or ''))}")
PY
  )"
}

run_migrations() {
  if [[ "$WIZARD_PREV_SCHEMA" -lt 1 ]]; then
    log "migration_0_to_1: align install state (no data migration required)"
  fi
}

warn_git_sha_drift() {
  local head=""
  head="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo "")"
  if [[ -n "$WIZARD_PREV_GIT_SHA" && -n "$head" && "$WIZARD_PREV_GIT_SHA" != "$head" ]]; then
    log "warn: git ${WIZARD_PREV_GIT_SHA} -> ${head}; recommend: WIZARD_FORCE_REBUILD=1 bash scripts/setup_wizard.sh"
    log "  or: docker compose build n8n gateway && bash scripts/post_docker_rebuild.sh"
  fi
}

write_install_state() {
  mkdir -p "$(dirname "$INSTALL_STATE")"
  python3 - <<PY
import json, os, time
from pathlib import Path
p = Path(os.environ["INSTALL_STATE"])
prev = {}
if p.is_file():
    try:
        prev = json.loads(p.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        pass
now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
data = {
    "schema_version": int(os.environ["SCHEMA_VERSION"]),
    "installed_at": prev.get("installed_at") or now,
    "last_run_at": now,
    "git_sha": os.environ.get("GIT_SHA", ""),
    "stack_built": True,
}
p.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
print(json.dumps({"ok": True, "path": str(p)}))
PY
}

seed_env() {
  if [[ ! -f "$ROOT/.env" && -f "$ROOT/.env.example" ]]; then
    cp "$ROOT/.env.example" "$ROOT/.env"
    log "created .env from .env.example"
  fi
}

maybe_uv_sync() {
  if command -v uv >/dev/null 2>&1; then
    log "uv sync (dashboard / amctl deps)"
    (cd "$ROOT" && uv sync)
  else
    log "warn: uv not found — install uv or ensure .venv has PyYAML for :8790"
  fi
}

prompt_env_groups() {
  local groups="$1"
  PYTHONPATH="$ROOT/scripts/lib" python3 "$ROOT/scripts/lib/wizard_prompt.py" \
    --env "$ROOT/.env" \
    $(for g in $groups; do echo --group "$g"; done) \
    --apply
}

prompt_env_fields() {
  local fields=()
  for f in "$@"; do fields+=(--field "$f"); done
  PYTHONPATH="$ROOT/scripts/lib" python3 "$ROOT/scripts/lib/wizard_prompt.py" \
    --env "$ROOT/.env" "${fields[@]}" --apply
}

# Args: optional "force-recreate" to refresh n8n/gateway containers.
compose_up_services() {
  local force="${1:-}"
  if ! command -v docker >/dev/null 2>&1 && [[ "${#DOCKER[@]}" -eq 1 ]]; then
    log "docker missing — skip compose"
    return 1
  fi
  bash "$ROOT/scripts/stop_old_dashboard.sh" 2>/dev/null || true
  local up_args=(up -d --remove-orphans)
  if [[ "$force" == "force-recreate" ]]; then
    up_args+=(--force-recreate)
  fi
  "${DOCKER[@]}" compose -f "$ROOT/docker-compose.yml" "${up_args[@]}" n8n gateway
}

compose_up() {
  if ! command -v docker >/dev/null 2>&1 && [[ "${#DOCKER[@]}" -eq 1 ]]; then
    log "docker missing — skip compose"
    return 1
  fi
  "${DOCKER[@]}" compose -f "$ROOT/docker-compose.yml" build n8n gateway
  compose_up_services
}

recreate_stack() {
  compose_up_services force-recreate
}

host_has_oauth_secrets() {
  [[ -f "$ROOT/data/secrets/claude/.credentials.json" ]] \
    || [[ -f "$ROOT/data/secrets/gemini/oauth_creds.json" ]] \
    || [[ -s "$ROOT/data/secrets/gemini/google_accounts.json" ]] \
    || [[ -f "$ROOT/data/secrets/codex/auth.json" ]]
}

oauth_refresh_n8n_if_needed() {
  if ! command -v docker >/dev/null 2>&1 && [[ "${#DOCKER[@]}" -eq 1 ]]; then
    return 0
  fi
  if ! "${DOCKER[@]}" compose -f "$ROOT/docker-compose.yml" ps -q n8n 2>/dev/null | grep -q .; then
    return 0
  fi
  if ! host_has_oauth_secrets; then
    log "OAuth dirs empty — skip inject/restart n8n"
    return 0
  fi
  log "inject_n8n_secrets + restart n8n (host OAuth present)"
  bash "$ROOT/scripts/inject_n8n_secrets.sh"
  "${DOCKER[@]}" compose -f "$ROOT/docker-compose.yml" restart n8n
  # shellcheck source=scripts/lib/n8n_api_url.sh
  source "$ROOT/scripts/lib/n8n_api_url.sh"
  # shellcheck source=scripts/lib/n8n_wait.sh
  source "$ROOT/scripts/lib/n8n_wait.sh"
  if resolved="$(wait_n8n_healthz)"; then
    BASE="${resolved%%|*}"
    curl -fsS "${BASE%/}/healthz" >/dev/null
    log "n8n healthz OK at $BASE"
  else
    log "warn: n8n not reachable after restart (may still be starting)"
  fi
}

sync_oauth_all() {
  for s in sync_claude_oauth.sh sync_codex_oauth.sh sync_gemini_oauth.sh; do
    if [[ -x "$ROOT/scripts/$s" ]]; then
      bash "$ROOT/scripts/$s" 2>/dev/null || log "warn: $s failed (may need interactive login)"
    fi
  done
  if [[ -x "$ROOT/scripts/ensure_n8n_oauth.sh" ]]; then
    bash "$ROOT/scripts/ensure_n8n_oauth.sh" || true
  fi
  oauth_refresh_n8n_if_needed
}

verify_cli_loop() {
  local n=0
  while [[ "$n" -lt "$MAX_RETRY" ]]; do
    if VERIFY_CLI_STRICT=1 bash "$ROOT/scripts/verify_n8n_cli_auth.sh"; then
      return 0
    fi
    n=$((n + 1))
    log "CLI auth failed (attempt $n/$MAX_RETRY)"
    echo "Run: claude /login, codex login, gemini login; then sync_*_oauth.sh" >&2
    read -r -p "Retry OAuth sync now? [Y/n] " ans || true
    if [[ "${ans:-Y}" =~ ^[Nn] ]]; then
      return 1
    fi
    sync_oauth_all
    recreate_stack
  done
  return 1
}

verify_telegram_loop() {
  local n=0
  while [[ "$n" -lt "$MAX_RETRY" ]]; do
    if VERIFY_TELEGRAM_STRICT=1 bash "$ROOT/scripts/verify_telegram.sh"; then
      return 0
    fi
    n=$((n + 1))
    log "Telegram verify failed (attempt $n/$MAX_RETRY)"
    prompt_env_fields TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID TELEGRAM_WEBHOOK_SECRET
    recreate_stack
  done
  return 1
}

verify_meta_loop() {
  local n=0
  while [[ "$n" -lt "$MAX_RETRY" ]]; do
    if bash "$ROOT/scripts/verify_meta_tokens.sh"; then
      return 0
    fi
    n=$((n + 1))
    log "Meta verify failed (attempt $n/$MAX_RETRY)"
    prompt_env_fields META_PAGE_ID META_PAGE_ACCESS_TOKEN IG_USER_ID THREADS_USER_ID THREADS_ACCESS_TOKEN
    recreate_stack
  done
  return 1
}

hitl_ingress() {
  # shellcheck source=scripts/lib/load_env.sh
  source "${ROOT}/scripts/lib/load_env.sh"
  load_repo_env "$ROOT"
  bash "$ROOT/scripts/setup_production_hitl.sh" || true
  if [[ -z "${WEBHOOK_URL:-}" ]]; then
    if command -v docker >/dev/null 2>&1 || [[ "${#DOCKER[@]}" -gt 1 ]]; then
      "${DOCKER[@]}" compose -f "$ROOT/docker-compose.yml" --profile forwarder up -d forwarder 2>/dev/null \
        || bash "$ROOT/scripts/forwarder_ctl.sh" start || true
    else
      bash "$ROOT/scripts/forwarder_ctl.sh" start || true
    fi
  fi
}

ensure_compose_stack() {
  if ! command -v docker >/dev/null 2>&1 && [[ "${#DOCKER[@]}" -eq 1 ]]; then
    log "docker missing — skip compose"
    return 1
  fi
  if [[ "${WIZARD_FORCE_REBUILD:-0}" != "1" && "$WIZARD_STACK_BUILT" == "1" ]]; then
    if "${DOCKER[@]}" compose -f "$ROOT/docker-compose.yml" ps -q n8n 2>/dev/null | grep -q .; then
      log "idempotent: stack_built — skip image build, ensure n8n+gateway up"
      compose_up_services
      return 0
    fi
  fi
  compose_up
}

wizard_post_install_finalize() {
  if [[ "${WIZARD_FORCE_REBUILD:-0}" == "1" ]]; then
    log "WIZARD_FORCE_REBUILD: post_docker_rebuild (full)"
    bash "$ROOT/scripts/post_docker_rebuild.sh"
    return 0
  fi
  bash "$ROOT/scripts/wizard_finalize.sh"
  if ! bash "$ROOT/scripts/check_dashboard.sh" >/dev/null 2>&1; then
    log "hint: start console with: bash scripts/open_user_ui.sh"
  fi
}

align_strict_stage() {
  if grep -q '^AUTO_MEDIA_STRICT_STAGE=' "$ROOT/.env" 2>/dev/null; then
    sed -i 's/^AUTO_MEDIA_STRICT_STAGE=.*/AUTO_MEDIA_STRICT_STAGE=0/' "$ROOT/.env" || true
  fi
}

dry_run_verify() {
  local failures=0
  log "dry-run: verify CLI (warn-only)"
  VERIFY_CLI_STRICT=0 bash "$ROOT/scripts/verify_n8n_cli_auth.sh" || failures=$((failures + 1))
  log "dry-run: verify Telegram (warn-only)"
  VERIFY_TELEGRAM_STRICT=0 bash "$ROOT/scripts/verify_telegram.sh" || failures=$((failures + 1))
  log "dry-run: verify Meta (report only)"
  bash "$ROOT/scripts/verify_meta_tokens.sh" || log "warn: meta verify failed (dry-run continues)"
  return "$failures"
}

main() {
  if is_dry; then
    log "=== Auto Media setup wizard (DRY RUN) ==="
    log "no .env writes, no compose, no OAuth sync, no HITL, no install.json update"
  else
    log "=== Auto Media setup wizard ==="
  fi

  load_install_state
  if [[ -f "$INSTALL_STATE" ]]; then
    log "existing install state: $INSTALL_STATE (schema=$WIZARD_PREV_SCHEMA, idempotent re-run)"
  fi
  run_migrations
  warn_git_sha_drift

  log "preflight"
  bash "$ROOT/scripts/env-check.sh" || {
    log "env-check failed — fix dependencies first"
    exit 1
  }

  if is_dry; then
    [[ -f "$ROOT/.env" ]] || seed_env
    log "dry-run: missing env keys (n8n, telegram, gateway)"
    dry_run_list_missing "n8n telegram gateway" || true
    log "dry-run: missing env keys (llm, meta, threads)"
    dry_run_list_missing "llm meta threads" || true
    log "dry-run: would run amctl apply + compose + OAuth (skipped)"
    dry_run_verify || {
      log "dry-run: one or more verify scripts reported failure (see JSON above)"
      exit 1
    }
    log "dry-run: would run doctor (running warn-only checks now)"
    bash "$ROOT/scripts/amctl.sh" doctor || log "warn: doctor reported issues"
    echo ""
    echo "=== Dry run complete (no changes made) ==="
    echo "Run without --dry-run when ready: bash scripts/setup_wizard.sh"
    echo "User console (after real install): http://127.0.0.1:${DASHBOARD_PORT}/user"
    return 0
  fi

  maybe_uv_sync
  seed_env
  align_strict_stage

  log "interactive env (n8n, telegram, gateway)"
  prompt_env_groups n8n telegram gateway || true

  log "apply platform config"
  bash "$ROOT/scripts/amctl.sh" apply
  bash "$ROOT/scripts/fix-data-perms.sh"

  log "docker stack"
  ensure_compose_stack || log "compose up skipped/failed"

  log "optional LLM / Meta / Threads keys in .env"
  prompt_env_groups llm meta threads || true

  log "OAuth sync"
  sync_oauth_all

  log "verify CLI (claude, codex, gemini)"
  verify_cli_loop || {
    log "CLI verification incomplete — fix OAuth and re-run wizard"
    exit 1
  }

  log "verify Telegram"
  verify_telegram_loop || {
    log "Telegram verification failed"
    exit 1
  }

  log "verify Meta/Threads"
  verify_meta_loop || log "warn: meta verification failed (non-fatal for local dev)"

  log "HITL ingress"
  hitl_ingress

  log "finalize (no duplicate apply)"
  wizard_post_install_finalize

  log "doctor"
  bash "$ROOT/scripts/amctl.sh" doctor || log "warn: doctor reported issues"

  export SCHEMA_VERSION="$SCHEMA_VERSION"
  export INSTALL_STATE="$INSTALL_STATE"
  export GIT_SHA="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo "")"
  write_install_state

  echo ""
  echo "=== Setup complete ==="
  echo "Start UI:      bash scripts/open_user_ui.sh"
  echo "(run the line above before opening URLs in the browser)"
  echo "User console:  http://127.0.0.1:${DASHBOARD_PORT}/user"
  echo "Settings:      http://127.0.0.1:${DASHBOARD_PORT}/settings"
  echo "Skills:        http://127.0.0.1:${DASHBOARD_PORT}/skills"
  echo "Engines:       http://127.0.0.1:${DASHBOARD_PORT}/engines"
  echo "Gateway vars:  see .env.example (GATEWAY_URL, GATEWAY_N8N_API_URL)"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
# Usage: bash scripts/setup_wizard.sh [--dry-run|-n]
# Force image rebuild: WIZARD_FORCE_REBUILD=1 bash scripts/setup_wizard.sh
