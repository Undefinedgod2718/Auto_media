#!/usr/bin/env bash
# Verify Telegram bot token, chat id, webhook secret, and gateway readiness.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/load_env.sh
source "${ROOT}/scripts/lib/load_env.sh"
load_repo_env "$ROOT"
# shellcheck source=scripts/lib/common.sh
source "${ROOT}/scripts/lib/common.sh"
# shellcheck source=scripts/lib/docker_helpers.sh
source "${ROOT}/scripts/lib/docker_helpers.sh"
# shellcheck source=scripts/lib/gateway_url.sh
source "${ROOT}/scripts/lib/gateway_url.sh"

STRICT="${VERIFY_TELEGRAM_STRICT:-1}"
N8N_CONTAINER="$(resolve_n8n_container "$ROOT")"
GATEWAY_BASE="$(gateway_url_resolve)"
export AUTO_MEDIA_ROOT="$ROOT"
export N8N_CONTAINER
export GATEWAY_BASE
export VERIFY_TELEGRAM_STRICT="$STRICT"

python3 - <<'PY'
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

root = Path(os.environ["AUTO_MEDIA_ROOT"])
sys.path.insert(0, str(root / "scripts" / "lib"))
from env_store import parse_env  # noqa: E402
from secret_tests import test_telegram  # noqa: E402

strict = os.environ.get("VERIFY_TELEGRAM_STRICT", "1") == "1"
gateway_base = os.environ.get("GATEWAY_BASE", "http://127.0.0.1:8787").rstrip("/")
container = os.environ.get("N8N_CONTAINER", "auto_media-n8n-1")

_, values = parse_env(root / ".env")

checks: list[dict] = []
checks.append(test_telegram(values))

secret = values.get("TELEGRAM_WEBHOOK_SECRET", "")
if not secret:
    checks.append({"name": "webhook_secret", "ok": False, "message": "TELEGRAM_WEBHOOK_SECRET missing"})
elif len(secret) < 1 or len(secret) > 256:
    checks.append({"name": "webhook_secret", "ok": False, "message": "secret must be 1-256 chars"})
else:
    checks.append({"name": "webhook_secret", "ok": True, "message": "length ok"})

gw_ok = False
gw_msg = ""
try:
    with urllib.request.urlopen(f"{gateway_base}/healthz", timeout=5) as resp:
        gw_ok = resp.status == 200
        gw_msg = f"http={resp.status} base={gateway_base}"
except Exception as e:  # noqa: BLE001
    gw_msg = f"{gateway_base}: {e}"
checks.append({"name": "gateway_healthz", "ok": gw_ok, "message": gw_msg or "gateway not reachable"})

if gw_ok and secret:
    try:
        req = urllib.request.Request(
            f"{gateway_base}/telegram",
            data=b"{}",
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=5) as resp:
            checks.append(
                {
                    "name": "gateway_telegram_auth",
                    "ok": False,
                    "message": f"expected 403, got {resp.status}",
                }
            )
    except urllib.error.HTTPError as e:
        checks.append(
            {
                "name": "gateway_telegram_auth",
                "ok": e.code == 403,
                "message": f"http={e.code} (403 expected without secret header)",
            }
        )
    except Exception as e:  # noqa: BLE001
        checks.append({"name": "gateway_telegram_auth", "ok": False, "message": str(e)})

n8n_ok = False
for sock in ("/var/run/docker.sock", "/var/run/docker-host.sock"):
    if not os.path.exists(sock):
        continue
    cmd = (
        ["sudo", "docker", "exec", container, "sh", "-lc", 'test -n "${TELEGRAM_BOT_TOKEN:-}"']
        if "docker-host" in sock
        else ["docker", "exec", container, "sh", "-lc", 'test -n "${TELEGRAM_BOT_TOKEN:-}"']
    )
    p = subprocess.run(cmd, capture_output=True)
    n8n_ok = p.returncode == 0
    break
checks.append(
    {
        "name": "n8n_telegram_env",
        "ok": n8n_ok,
        "message": "TELEGRAM_BOT_TOKEN in n8n" if n8n_ok else "restart n8n after .env save",
    }
)

ok = all(c.get("ok") for c in checks)
out = {"ok": ok, "path": "verify_telegram", "checks": checks, "gateway_base": gateway_base}
print(json.dumps(out, ensure_ascii=False))
sys.exit(0 if ok or not strict else 1)
PY
