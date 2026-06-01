#!/usr/bin/env bash
# Ground-truth inventory for B-prime v4 (run on the machine that will implement).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

OUT="${DATA_ROOT}/logs/repo_inventory.json"
mkdir -p "$(dirname "$OUT")"

git_head=""
worktree_id=""
if git -C "$REPO_ROOT" rev-parse HEAD >/dev/null 2>&1; then
  git_head="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || true)"
  worktree_id="$(git -C "$REPO_ROOT" branch --show-current 2>/dev/null || true)"
fi

invoke_engine="${REPO_ROOT}/scripts/lib/invoke-engine.sh"
invoke_lines=0
codex_sites="[]"
if [[ -f "$invoke_engine" ]]; then
  invoke_lines="$(wc -l <"$invoke_engine" | tr -d ' ')"
  codex_sites="$(python3 - "$invoke_engine" <<'PY'
import json, re, sys
path = sys.argv[1]
lines = open(path, encoding="utf-8").read().splitlines()
sites = []
depth = 0
in_fn = False
for i, line in enumerate(lines, 1):
    if line.startswith("invoke_codex_cli()") or line.strip() == "invoke_codex_cli() {":
        in_fn = True
        depth = 0
    if in_fn:
        depth += line.count("{") - line.count("}")
        if "invoke_gemini_cli" in line:
            sites.append(i)
        if depth <= 0 and i > 1 and line.strip().startswith("}"):
            in_fn = False
print(json.dumps(sites))
PY
)"
fi

mem_limit=""
if [[ -f "${REPO_ROOT}/docker-compose.yml" ]]; then
  mem_limit="$(grep -E '^\s*mem_limit:' "${REPO_ROOT}/docker-compose.yml" | head -1 | awk '{print $2}' || true)"
fi

has_run_webhook=false
has_forwarder=false
has_revise=false
has_save=false
has_trigger=false
has_prereview=false
has_gateway=false

if [[ -d "${REPO_ROOT}/workflows" ]]; then
  if grep -rq 'auto-media-run' "${REPO_ROOT}/workflows" 2>/dev/null; then
    has_run_webhook=true
  fi
  [[ -f "${REPO_ROOT}/workflows/auto-media-hitl-forwarder.json" ]] && has_forwarder=true
  if grep -rq 'Telegram request feedback\|apply_feedback\|Wait for feedback\|hermes_revision' "${REPO_ROOT}/workflows" 2>/dev/null; then
    has_revise=true
  fi
  if grep -rq 'Save wait resume URL' "${REPO_ROOT}/workflows" 2>/dev/null; then
    has_save=true
  fi
fi

[[ -f "${REPO_ROOT}/scripts/trigger_production_run.sh" ]] && has_trigger=true
[[ -f "${REPO_ROOT}/scripts/hermes_prereview.sh" ]] && has_prereview=true
[[ -f "${REPO_ROOT}/scripts/hermes_telegram_gateway.py" ]] && has_gateway=true

branch="hybrid"
if [[ "$has_forwarder" == true && "$has_revise" == true && "$has_run_webhook" == true ]]; then
  branch="X"
elif [[ "$has_forwarder" == false && "$has_revise" == false ]]; then
  branch="Y"
fi

export GIT_HEAD="$git_head" WORKTREE_ID="$worktree_id" REPO_ROOT_INVENTORY="$REPO_ROOT"
export INVOKE_LINES="$invoke_lines" CODEX_SITES="$codex_sites" MEM_LIMIT="$mem_limit" BRANCH="$branch"
export HAS_RUN="$has_run_webhook" HAS_FWD="$has_forwarder" HAS_REV="$has_revise" HAS_SAVE="$has_save"
export HAS_TRIG="$has_trigger" HAS_PRE="$has_prereview" HAS_GW="$has_gateway"

python3 - "$OUT" <<'PY'
import json, os, sys
out_path = sys.argv[1]
out = {
    "git_head": os.environ.get("GIT_HEAD", ""),
    "worktree_id": os.environ.get("WORKTREE_ID", ""),
    "repo_root": os.environ.get("REPO_ROOT_INVENTORY", ""),
    "invoke_engine_lines": int(os.environ.get("INVOKE_LINES", "0") or 0),
    "codex_gemini_fallback_sites": json.loads(os.environ.get("CODEX_SITES", "[]")),
    "mem_limit": os.environ.get("MEM_LIMIT", ""),
    "flags": {
        "has_auto_media_run_webhook": os.environ.get("HAS_RUN", "false") == "true",
        "has_hitl_forwarder": os.environ.get("HAS_FWD", "false") == "true",
        "has_revise_feedback_chain": os.environ.get("HAS_REV", "false") == "true",
        "has_save_wait_resume_node": os.environ.get("HAS_SAVE", "false") == "true",
        "has_trigger_production_run": os.environ.get("HAS_TRIG", "false") == "true",
        "has_hermes_prereview_sh": os.environ.get("HAS_PRE", "false") == "true",
        "has_hermes_gateway_py": os.environ.get("HAS_GW", "false") == "true",
    },
    "branch": os.environ.get("BRANCH", "hybrid"),
}
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(out, f, indent=2, ensure_ascii=False)
    f.write("\n")
print(json.dumps(out, indent=2, ensure_ascii=False))
PY

json_ok "$OUT"
