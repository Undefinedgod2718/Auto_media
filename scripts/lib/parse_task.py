#!/usr/bin/env python3
"""Parse TASK.md fields for workflow scripts."""
from __future__ import annotations

import re
from pathlib import Path


def parse_task(task_path: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    if not task_path.is_file():
        return out
    for line in task_path.read_text(encoding="utf-8").splitlines():
        m = re.match(r"^([a-z_]+):\s*(.*)$", line.strip(), re.I)
        if m:
            out[m.group(1).lower()] = m.group(2).strip()
    return out


def publish_targets(task_path: Path) -> set[str]:
    raw = parse_task(task_path).get("publish_targets", "")
    if not raw:
        return {"threads"}
    return {p.strip().lower() for p in raw.split(",") if p.strip()}


def has_target(task_path: Path, name: str) -> bool:
    return name.lower() in publish_targets(task_path)
