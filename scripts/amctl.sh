#!/usr/bin/env bash
# Platform control plane CLI (UTF-8). Run on Linux host or Git Bash.
set -euo pipefail

export LANG="${LANG:-C.UTF-8}"
export LC_ALL="${LC_ALL:-C.UTF-8}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export AUTO_MEDIA_ROOT="$REPO_ROOT"
PLATFORM_YAML="${REPO_ROOT}/config/platform.yaml"
VENV="${REPO_ROOT}/.venv"

uv_run_apply() {
  if command -v uv >/dev/null 2>&1; then
    (cd "$REPO_ROOT" && uv run auto-media-apply)
  elif [[ -x "${VENV}/bin/python" ]]; then
    "${VENV}/bin/python" -m auto_media_tools.apply
  elif command -v python3 >/dev/null 2>&1; then
    (cd "$REPO_ROOT" && PYTHONPATH="$REPO_ROOT" python3 -m auto_media_tools.apply)
  else
    echo "error: need uv or python3 for amctl apply" >&2
    exit 1
  fi
}

cmd_apply() {
  uv_run_apply
  bash "${REPO_ROOT}/scripts/fix-data-perms.sh"
  if python3 - "$PLATFORM_YAML" <<'PY' 2>/dev/null | grep -q true; then
import sys, yaml
from pathlib import Path
p = Path(sys.argv[1])
data = yaml.safe_load(p.read_text(encoding="utf-8")) or {}
print((data.get("features") or {}).get("hermes_gateway") is True)
PY
    if [[ -x "${REPO_ROOT}/scripts/enforce_telegram_gateway.sh" ]] && [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]]; then
      bash "${REPO_ROOT}/scripts/enforce_telegram_gateway.sh" || echo "warn: enforce_telegram_gateway failed (non-fatal)" >&2
    fi
  fi
  echo "apply: ok"
}

cmd_status() {
  echo "=== Auto Media status ==="
  echo "repo: $REPO_ROOT"
  echo "encoding: LANG=$LANG"
  if [[ -f "${REPO_ROOT}/data/config/platform.runtime.json" ]]; then
    command -v jq >/dev/null 2>&1 && jq '{ui, engines: {copy: .engines.copy, svg: .engines.svg}, publish}' \
      "${REPO_ROOT}/data/config/platform.runtime.json"
  else
    echo "runtime: (missing — run amctl apply)"
  fi
  echo "--- docker ---"
  if command -v docker >/dev/null 2>&1; then
    docker compose -f "${REPO_ROOT}/docker-compose.yml" ps 2>/dev/null || true
  fi
  echo "--- tools ---"
  bash "${REPO_ROOT}/scripts/env-check.sh" || true
}

set_yaml_ui() {
  local ui="$1"
  python3 - "$PLATFORM_YAML" "$ui" <<'PY'
import sys
from pathlib import Path
import yaml
path, ui = Path(sys.argv[1]), sys.argv[2]
data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
data.setdefault("ui", {})["active"] = ui
path.write_text(yaml.dump(data, allow_unicode=True, sort_keys=False), encoding="utf-8")
PY
}

cmd_ui() {
  local target="${1:-}"
  case "$target" in
    n8n) set_yaml_ui n8n; cmd_apply ;;
    hermes) set_yaml_ui hermes; cmd_apply; echo "Start: hermes (in Linux host, workdir=$REPO_ROOT)" ;;
    dual) set_yaml_ui dual; cmd_apply ;;
    *) echo "usage: amctl ui n8n|hermes|dual"; exit 1 ;;
  esac
  if [[ "$target" == "n8n" ]]; then
    echo "Open: http://localhost:${N8N_PORT:-5678}"
  fi
}

cmd_skill_list() {
  find "${REPO_ROOT}/config/skills" -mindepth 1 -maxdepth 1 -type d ! -name '_template' -printf '%f\n' 2>/dev/null \
    || ls -1 "${REPO_ROOT}/config/skills" | grep -v '^_template$'
}

validate_skill_dir() {
  local name="$1"
  local dir="${REPO_ROOT}/config/skills/${name}"
  [[ -d "$dir" ]] || { echo "missing skill: $name"; return 1; }
  local ok=0
  if [[ -f "$dir/SKILL.md" ]]; then ok=1; fi
  if [[ "$name" == *copywriter* ]]; then
    [[ -f "$dir/BRAND.md" && -f "$dir/TEMPLATE.md" ]] || { echo "$name: need BRAND.md TEMPLATE.md"; return 1; }
  fi
  if [[ "$name" == *svg* ]]; then
    [[ -f "$dir/PALETTE.md" && -f "$dir/RULES.md" ]] || { echo "$name: need PALETTE.md RULES.md"; return 1; }
  fi
  [[ $ok -eq 1 ]] || { echo "$name: missing SKILL.md"; return 1; }
  echo "skill ok: $name"
}

cmd_skill() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    list) cmd_skill_list ;;
    validate)
      local name="${1:-}"
      if [[ -n "$name" ]]; then validate_skill_dir "$name"; else
        for d in "${REPO_ROOT}/config/skills"/*; do
          [[ -d "$d" ]] || continue
          base="$(basename "$d")"
          [[ "$base" == "_template" ]] && continue
          validate_skill_dir "$base"
        done
      fi
      ;;
    use)
      local role="${1:-}" name="${2:-}"
      [[ -n "$role" && -n "$name" ]] || { echo "usage: amctl skill use copy|svg NAME"; exit 1; }
      python3 - "$PLATFORM_YAML" "$role" "$name" <<'PY'
import sys
from pathlib import Path
import yaml
path, role, name = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
eng = data.setdefault("engines", {})
key = "copy" if role == "copy" else "svg"
eng.setdefault(key, {})["skill_mount"] = name
path.write_text(yaml.dump(data, allow_unicode=True, sort_keys=False), encoding="utf-8")
PY
      cmd_apply
      ;;
    *) echo "usage: amctl skill list|validate [name]|use copy|svg NAME"; exit 1 ;;
  esac
}

cmd_publish() {
  local mode="${1:-}"
  [[ -n "$mode" ]] || { echo "usage: amctl publish api|dom|auto"; exit 1; }
  python3 - "$PLATFORM_YAML" "$mode" <<'PY'
import sys
from pathlib import Path
import yaml
path, mode = Path(sys.argv[1]), sys.argv[2]
data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
data.setdefault("publish", {})["mode"] = mode
path.write_text(yaml.dump(data, allow_unicode=True, sort_keys=False), encoding="utf-8")
PY
  cmd_apply
}

cmd_supervisor() {
  echo "=== Hermes / Plan B supervisor ==="
  bash "${REPO_ROOT}/scripts/check_api_dead.sh" && rc=0 || rc=$?
  if [[ "${rc:-0}" -eq 2 ]]; then
    echo "Signal present. Run: AUTO_MEDIA_HERMES_AUTO=1 ./scripts/hermes-plan-b.sh"
    echo "Or: hermes (see docs/HERMES_SETUP.md)"
  fi
  return 0
}

cmd_engine() {
  local role="${1:-}" prov="${2:-}"
  [[ -n "$role" && -n "$prov" ]] || { echo "usage: amctl engine copy|svg PROVIDER"; exit 1; }
  if [[ "$prov" == *api* ]]; then echo "refused: metered_api not allowed"; exit 1; fi
  python3 - "$PLATFORM_YAML" "$role" "$prov" <<'PY'
import sys
from pathlib import Path
import yaml

PROVIDER_BINARIES = {
    "claude_cli": "claude",
    "codex_cli": "codex",
    "gemini_cli": "gemini",
}

path, role, prov = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
if prov not in PROVIDER_BINARIES:
    print(f"error: unknown provider {prov!r}; use: {', '.join(PROVIDER_BINARIES)}", file=sys.stderr)
    sys.exit(1)
data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
eng = data.setdefault("engines", {})
key = "copy" if role == "copy" else "svg"
slot = eng.setdefault(key, {})
slot["provider"] = prov
slot["binary"] = PROVIDER_BINARIES[prov]
slot.setdefault("billing", "subscription_cli")
path.write_text(yaml.dump(data, allow_unicode=True, sort_keys=False), encoding="utf-8")
PY
  cmd_apply
}

main() {
  local cmd="${1:-status}"; shift || true
  case "$cmd" in
    apply) cmd_apply ;;
    status) cmd_status ;;
    ui) cmd_ui "$@" ;;
    skill) cmd_skill "$@" ;;
    publish) cmd_publish "$@" ;;
    engine) cmd_engine "$@" ;;
    env|check) bash "${REPO_ROOT}/scripts/env-check.sh" ;;
    supervisor|planb) cmd_supervisor ;;
    *) echo "usage: amctl apply|status|ui|skill|publish|engine|supervisor|env"; exit 1 ;;
  esac
}

main "$@"
