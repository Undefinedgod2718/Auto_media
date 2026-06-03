#!/usr/bin/env python3
"""Interactive .env prompts for setup_wizard (safe writes via env_store)."""
from __future__ import annotations

import argparse
import getpass
import json
import os
import sys
from pathlib import Path

from env_store import FIELD_MAP, FIELD_SPECS, parse_env, update_env
from version_store import snapshot_file

ROOT = Path(__file__).resolve().parents[2]
ENV_PATH = ROOT / ".env"
DATA_ROOT = Path(os.environ.get("DATA_ROOT", str(ROOT / "data")))


def _is_missing(name: str, value: str) -> bool:
    if not value:
        return True
    low = value.lower()
    if "change-me" in low or low.startswith("your-"):
        return True
    if name == "N8N_ENCRYPTION_KEY" and len(value) < 16:
        return True
    return False


def fields_needing_input(values: dict[str, str], groups: list[str] | None = None) -> list[str]:
    out: list[str] = []
    for spec in FIELD_SPECS:
        if groups and spec.group not in groups:
            continue
        if not spec.editable:
            continue
        if _is_missing(spec.name, values.get(spec.name, "")):
            out.append(spec.name)
    return out


def prompt_updates(
    env_path: Path,
    groups: list[str] | None = None,
    only: list[str] | None = None,
) -> dict[str, str]:
    _, values = parse_env(env_path)
    names = only or fields_needing_input(values, groups)
    updates: dict[str, str] = {}
    for name in names:
        spec = FIELD_MAP.get(name)
        if not spec:
            continue
        desc = spec.description or name
        if spec.secret:
            val = getpass.getpass(f"{name} ({desc}): ").strip()
        else:
            val = input(f"{name} ({desc}): ").strip()
        if val:
            updates[name] = val
    return updates


def cli() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--env", type=Path, default=ENV_PATH)
    ap.add_argument("--group", action="append", dest="groups", help="telegram, meta, n8n, ...")
    ap.add_argument("--field", action="append", dest="fields", help="specific field names")
    ap.add_argument("--list-missing", action="store_true")
    ap.add_argument("--apply", action="store_true", help="write prompts to .env")
    args = ap.parse_args()

    _, values = parse_env(args.env)
    if args.list_missing:
        missing = fields_needing_input(values, args.groups)
        print(json.dumps({"missing": missing}, ensure_ascii=False))
        return 0

    updates = prompt_updates(args.env, args.groups, args.fields)
    if not updates:
        print(json.dumps({"ok": True, "updated": []}, ensure_ascii=False))
        return 0
    if args.apply:
        if args.env.is_file():
            snapshot_file(
                DATA_ROOT,
                ".env",
                args.env,
                actor="wizard",
                reason="wizard_prompt",
                repo=ROOT,
            )
        update_env(args.env, updates)
    print(json.dumps({"ok": True, "updated": sorted(updates.keys())}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(cli())
