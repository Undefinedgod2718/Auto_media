#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a

RUN_ID=""
PHASE="pre_hitl"
VIOLATIONS_FILE=""
GATE_FAIL="0"
CHAT_ID="${TELEGRAM_CHAT_ID:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-id) RUN_ID="$2"; shift 2 ;;
    --phase) PHASE="$2"; shift 2 ;;
    --violations-json) VIOLATIONS_FILE="$(mktemp)"; echo "$2" >"$VIOLATIONS_FILE"; shift 2 ;;
    --violations-file) VIOLATIONS_FILE="$2"; shift 2 ;;
    --chat-id) CHAT_ID="$2"; shift 2 ;;
    --gate-fail) GATE_FAIL="1"; shift ;;
    *) json_err "unknown arg: $1" ;;
  esac
done
[[ -n "$RUN_ID" ]] || json_err "usage: notify_platform_limit.sh --run-id ID [--violations-json '[]']"

export AUTO_MEDIA_ROOT="$ROOT"
export DATA_ROOT="${DATA_ROOT:-$ROOT/data}"
export N8N_GATEWAY_URL="${N8N_GATEWAY_URL:-http://gateway:8787}"
export GATEWAY_INTERNAL_SECRET="${GATEWAY_INTERNAL_SECRET:-}"
export TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
export TELEGRAM_CHAT_ID="$CHAT_ID"

PYTHONPATH="$ROOT/scripts/lib" python3 - "$RUN_ID" "$PHASE" "$GATE_FAIL" "${VIOLATIONS_FILE:-}" <<'PY'
import json
import os
import sys
import urllib.parse
import urllib.request
from pathlib import Path

sys.path.insert(0, os.path.join(os.environ["AUTO_MEDIA_ROOT"], "scripts", "lib"))
from platform_limits import format_telegram_message

run_id, phase, gate_fail = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
vfile = sys.argv[4] if len(sys.argv) > 4 else ""

violations: list = []
if vfile and Path(vfile).is_file():
    violations = json.loads(Path(vfile).read_text(encoding="utf-8"))

if gate_fail:
    data_root = Path(os.environ.get("DATA_ROOT", "data"))
    run_dir = data_root / "runs" / run_id
    for name, plat in [
        ("publish_ig.json", "instagram"),
        ("publish_threads.json", "threads"),
        ("publish_facebook.json", "facebook"),
    ]:
        p = run_dir / name
        if not p.is_file():
            violations.append({
                "platform": plat,
                "code": "missing_publish_result",
                "message_zh": f"缺少 {name}（發佈腳本未寫入結果，finalize 無法彙總）",
            })
            continue
        d = json.loads(p.read_text(encoding="utf-8"))
        if not d.get("skipped") and not d.get("ok"):
            violations.append({
                "platform": plat,
                "code": "publish_failed",
                "message_zh": f"{plat} 發佈失敗: {d.get('error') or 'unknown'}",
            })
    phase = "pre_publish"

text = format_telegram_message(run_id, phase, violations)
chat_id = os.environ.get("TELEGRAM_CHAT_ID", "")
gateway = os.environ.get("N8N_GATEWAY_URL", "http://gateway:8787").rstrip("/")
secret = os.environ.get("GATEWAY_INTERNAL_SECRET", "")

def post_gateway() -> bool:
    body = json.dumps({"chat_id": chat_id, "text": text}, ensure_ascii=False).encode()
    req = urllib.request.Request(
        f"{gateway}/internal/notify",
        data=body,
        headers={"Content-Type": "application/json", **({"X-Gateway-Secret": secret} if secret else {})},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return 200 <= resp.status < 300
    except Exception:
        return False

def post_telegram() -> bool:
    token = os.environ.get("TELEGRAM_BOT_TOKEN", "")
    if not token or not chat_id:
        return False
    data = urllib.parse.urlencode({"chat_id": chat_id, "text": text}).encode()
    req = urllib.request.Request(
        f"https://api.telegram.org/bot{token}/sendMessage",
        data=data,
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=15):
            return True
    except Exception:
        return False

if not post_gateway() and not post_telegram():
    print(json.dumps({"ok": False, "error": "notify failed"}, ensure_ascii=False), file=sys.stderr)
    sys.exit(1)
print(json.dumps({"ok": True, "notified": True}, ensure_ascii=False))
PY
