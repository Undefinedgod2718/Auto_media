#!/usr/bin/env python3
"""Minimal Auto Media MCP stdio server for external LLM tooling."""
from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any

ROOT = Path(os.environ.get("AUTO_MEDIA_ROOT", Path(__file__).resolve().parents[1]))
DATA_ROOT = Path(os.environ.get("DATA_ROOT", ROOT / "data"))
WRITE_ENABLED = os.environ.get("AUTO_MEDIA_MCP_WRITE", "0") == "1"


def _send(msg: dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(msg, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def _ok(req_id: Any, result: dict[str, Any]) -> None:
    _send({"jsonrpc": "2.0", "id": req_id, "result": result})


def _err(req_id: Any, code: int, message: str) -> None:
    _send({"jsonrpc": "2.0", "id": req_id, "error": {"code": code, "message": message}})


def _run(cmd: list[str]) -> tuple[int, str, str]:
    p = subprocess.run(cmd, cwd=str(ROOT), text=True, capture_output=True)
    return p.returncode, p.stdout.strip(), p.stderr.strip()


def _tool_defs() -> list[dict[str, Any]]:
    return [
        {
            "name": "run_get_status",
            "description": "Read run state.json summary",
            "inputSchema": {
                "type": "object",
                "required": ["run_id"],
                "properties": {"run_id": {"type": "string"}},
            },
        },
        {
            "name": "run_require_stage",
            "description": "Check run stage_seq >= min_seq",
            "inputSchema": {
                "type": "object",
                "required": ["run_id", "min_seq"],
                "properties": {"run_id": {"type": "string"}, "min_seq": {"type": "integer"}},
            },
        },
        {
            "name": "run_mark_stage",
            "description": "Mark run stage (write-enabled only)",
            "inputSchema": {
                "type": "object",
                "required": ["run_id", "stage"],
                "properties": {"run_id": {"type": "string"}, "stage": {"type": "string"}},
            },
        },
        {
            "name": "doctor",
            "description": "Run env-check and summarize toolchain status",
            "inputSchema": {"type": "object", "properties": {}},
        },
    ]


def _call_tool(name: str, args: dict[str, Any]) -> dict[str, Any]:
    run_id = str(args.get("run_id", ""))
    if name == "run_get_status":
        if not run_id:
            return {"isError": True, "content": [{"type": "text", "text": "missing run_id"}]}
        run_dir = DATA_ROOT / "runs" / run_id
        rc, out, err = _run(
            [
                "python3",
                str(ROOT / "scripts/lib/run_state.py"),
                "--run-dir",
                str(run_dir),
                "--run-id",
                run_id,
                "status",
            ]
        )
        txt = out if rc == 0 else err
        return {"content": [{"type": "text", "text": txt}], "isError": rc != 0}
    if name == "run_require_stage":
        if not run_id:
            return {"isError": True, "content": [{"type": "text", "text": "missing run_id"}]}
        min_seq = int(args.get("min_seq", 0))
        run_dir = DATA_ROOT / "runs" / run_id
        rc, out, err = _run(
            [
                "python3",
                str(ROOT / "scripts/lib/run_state.py"),
                "--run-dir",
                str(run_dir),
                "--run-id",
                run_id,
                "require",
                "--min-seq",
                str(min_seq),
            ]
        )
        txt = out if rc == 0 else err
        return {"content": [{"type": "text", "text": txt}], "isError": rc != 0}
    if name == "run_mark_stage":
        if not WRITE_ENABLED:
            return {"isError": True, "content": [{"type": "text", "text": "write tools disabled (set AUTO_MEDIA_MCP_WRITE=1)"}]}
        run_dir = DATA_ROOT / "runs" / run_id
        stage = str(args.get("stage", ""))
        rc, out, err = _run(
            [
                "python3",
                str(ROOT / "scripts/lib/run_state.py"),
                "--run-dir",
                str(run_dir),
                "--run-id",
                run_id,
                "mark",
                "--stage",
                stage,
            ]
        )
        txt = out if rc == 0 else err
        return {"content": [{"type": "text", "text": txt}], "isError": rc != 0}
    if name == "doctor":
        rc, out, err = _run(["bash", "scripts/env-check.sh"])
        txt = out if out else err
        return {"content": [{"type": "text", "text": txt}], "isError": rc != 0}
    return {"isError": True, "content": [{"type": "text", "text": f"unknown tool: {name}"}]}


def main() -> int:
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError:
            continue
        req_id = req.get("id")
        method = req.get("method", "")
        params = req.get("params") or {}

        if method == "initialize":
            _ok(req_id, {"protocolVersion": "2024-11-05", "serverInfo": {"name": "automedia-mcp", "version": "0.1.0"}, "capabilities": {"tools": {}}})
            continue
        if method == "notifications/initialized":
            continue
        if method == "tools/list":
            _ok(req_id, {"tools": _tool_defs()})
            continue
        if method == "tools/call":
            name = params.get("name", "")
            arguments = params.get("arguments") or {}
            _ok(req_id, _call_tool(name, arguments))
            continue
        if method == "ping":
            _ok(req_id, {})
            continue
        _err(req_id, -32601, f"method not found: {method}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
