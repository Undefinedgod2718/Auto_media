#!/usr/bin/env python3
"""Push workflow JSON to n8n via REST API (PUT /api/v1/workflows/:id)."""
from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_WORKFLOWS = (
    ROOT / "workflows" / "auto-media-happy-path.json",
    ROOT / "workflows" / "auto-media-hitl-forwarder.json",
)


def load_env(path: Path) -> dict[str, str]:
    env: dict[str, str] = {}
    if not path.is_file():
        return env
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        env[k] = v.strip().strip('"').strip("'")
    return env


def sync_one(wf_path: Path, base: str, key: str) -> int:
    wf = json.loads(wf_path.read_text(encoding="utf-8"))
    wf_id = wf.get("id") or wf.get("name")
    if not wf_id:
        print(f"workflow id missing: {wf_path}", file=sys.stderr)
        return 2

    body = {
        "name": wf.get("name"),
        "nodes": wf.get("nodes"),
        "connections": wf.get("connections"),
        "settings": wf.get("settings") or {},
    }
    if wf.get("staticData") is not None:
        body["staticData"] = wf["staticData"]

    req = urllib.request.Request(
        f"{base}/api/v1/workflows/{wf_id}",
        data=json.dumps(body).encode("utf-8"),
        headers={
            "X-N8N-API-KEY": key,
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
        method="PUT",
    )
    publish = os.environ.get("N8N_SYNC_PUBLISH", "1") != "0"
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            out = json.loads(resp.read().decode())
            wf_id_out = out.get("id", wf_id)
            print(f"OK updated workflow {wf_id_out} ({out.get('name')}) from {wf_path.name}")
        if publish:
            pub_req = urllib.request.Request(
                f"{base}/api/v1/workflows/{wf_id}/publish",
                data=b"{}",
                headers={
                    "X-N8N-API-KEY": key,
                    "Content-Type": "application/json",
                    "Accept": "application/json",
                },
                method="POST",
            )
            try:
                with urllib.request.urlopen(pub_req, timeout=60) as pub_resp:
                    pub_resp.read()
                    print(f"OK published workflow {wf_id}")
            except urllib.error.HTTPError as pe:
                err_body = pe.read().decode(errors="replace")
                print(f"warn: publish HTTP {pe.code}: {err_body[:200]}", file=sys.stderr)
        return 0
    except urllib.error.HTTPError as e:
        err = e.read().decode(errors="replace")
        print(f"HTTP {e.code} ({wf_path.name}): {err}", file=sys.stderr)
        return 1
    except OSError as e:
        print(f"connect failed ({wf_path.name}): {e}", file=sys.stderr)
        return 1


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] in ("--all", "-a"):
        wf_paths = list(DEFAULT_WORKFLOWS)
    elif len(sys.argv) > 1:
        wf_paths = [Path(p) for p in sys.argv[1:]]
    else:
        wf_paths = list(DEFAULT_WORKFLOWS)

    env = load_env(ROOT / ".env")
    base = (
        env.get("N8N_SYNC_API_URL")
        or env.get("GATEWAY_N8N_API_URL")
        or env.get("N8N_API_URL", "http://localhost:5678")
    ).rstrip("/")
    key = env.get("N8N_API_KEY", "")
    if not key:
        print("N8N_API_KEY missing in .env", file=sys.stderr)
        return 2

    rc = 0
    for wf_path in wf_paths:
        if not wf_path.is_file():
            print(f"workflow not found: {wf_path}", file=sys.stderr)
            rc = 2
            continue
        if sync_one(wf_path, base, key) != 0:
            rc = 1
    if rc == 0:
        print(
            "Deploy order: patch_bprime_workflows.py → "
            "sync_workflow_to_n8n.py → sync_scripts_to_n8n.sh"
        )
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
