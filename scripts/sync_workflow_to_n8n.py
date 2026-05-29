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


def main() -> int:
    wf_path = ROOT / "workflows" / "auto-media-happy-path.json"
    if len(sys.argv) > 1:
        wf_path = Path(sys.argv[1])
    if not wf_path.is_file():
        print(f"workflow not found: {wf_path}", file=sys.stderr)
        return 2

    env = load_env(ROOT / ".env")
    base = env.get("N8N_API_URL", "http://localhost:5678").rstrip("/")
    key = env.get("N8N_API_KEY", "")
    if not key:
        print("N8N_API_KEY missing in .env", file=sys.stderr)
        return 2

    wf = json.loads(wf_path.read_text(encoding="utf-8"))
    wf_id = wf.get("id") or wf.get("name")
    if not wf_id:
        print("workflow id missing", file=sys.stderr)
        return 2

    # n8n API accepts subset of fields on update
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
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            out = json.loads(resp.read().decode())
            print(f"OK updated workflow {out.get('id')} ({out.get('name')})")
            return 0
    except urllib.error.HTTPError as e:
        err = e.read().decode(errors="replace")
        print(f"HTTP {e.code}: {err}", file=sys.stderr)
        return 1
    except OSError as e:
        print(f"connect failed: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
