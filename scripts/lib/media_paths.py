#!/usr/bin/env python3
"""Resolve DATA_ROOT / config paths (repo checkout vs n8n /data layout)."""
from __future__ import annotations

import os
from pathlib import Path


def data_root() -> Path:
    env = os.environ.get("DATA_ROOT", "").strip()
    if env:
        return Path(env)
    root = Path(__file__).resolve().parents[2]
    if (root / "config" / "platform_limits.json").is_file():
        return root
    if (root / "data" / "config" / "platform_limits.json").is_file():
        return root / "data"
    if Path("/data/config").is_dir():
        return Path("/data")
    return root / "data"


def config_path(name: str) -> Path:
    return data_root() / "config" / name
