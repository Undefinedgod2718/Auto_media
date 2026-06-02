#!/usr/bin/env python3
"""Rolling publish quota ledger (append-only JSONL)."""
from __future__ import annotations

import json
import os
from datetime import datetime, timedelta, timezone
from pathlib import Path

DATA_ROOT = Path(os.environ.get("DATA_ROOT", Path(__file__).resolve().parents[2] / "data"))
DEFAULT_LEDGER = DATA_ROOT / "hitl" / "publish_quota.jsonl"

PLANNED_UNITS = {
    "instagram": 1,
    "threads": 5,
    "facebook": 1,
}


def planned_units(platform: str) -> int:
    return PLANNED_UNITS.get(platform, 0)


def _parse_ts(ts: str) -> datetime:
    try:
        dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except ValueError:
        return datetime.now(timezone.utc)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt


def _read_entries(ledger_path: Path) -> list[dict]:
    if not ledger_path.is_file():
        return []
    out: list[dict] = []
    for line in ledger_path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            out.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return out


def count_units(ledger_path: Path, platform: str, hours: float) -> int:
    cutoff = datetime.now(timezone.utc) - timedelta(hours=hours)
    total = 0
    for row in _read_entries(ledger_path):
        if row.get("platform") != platform:
            continue
        if _parse_ts(str(row.get("ts", ""))) < cutoff:
            continue
        total += int(row.get("units", 1))
    return total


def append_entry(
    ledger_path: Path,
    *,
    run_id: str,
    platform: str,
    units: int,
    kind: str,
) -> None:
    ledger_path.parent.mkdir(parents=True, exist_ok=True)
    row = {
        "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "run_id": run_id,
        "platform": platform,
        "units": units,
        "kind": kind,
    }
    with ledger_path.open("a", encoding="utf-8") as f:
        f.write(json.dumps(row, ensure_ascii=False) + "\n")


def record_from_run(run_dir: Path, ledger_path: Path | None = None) -> dict:
    path = ledger_path or DEFAULT_LEDGER
    run_id = run_dir.name
    recorded: list[str] = []

    ig_file = run_dir / "publish_ig.json"
    if ig_file.is_file():
        d = json.loads(ig_file.read_text(encoding="utf-8"))
        if d.get("ok") and not d.get("skipped"):
            append_entry(path, run_id=run_id, platform="instagram", units=1, kind="carousel")
            recorded.append("instagram")

    th_file = run_dir / "publish_threads.json"
    if th_file.is_file():
        d = json.loads(th_file.read_text(encoding="utf-8"))
        if d.get("ok") and not d.get("skipped"):
            units = int(d.get("chunk_count") or PLANNED_UNITS["threads"])
            append_entry(path, run_id=run_id, platform="threads", units=units, kind="chain")
            recorded.append("threads")

    fb_file = run_dir / "publish_facebook.json"
    if fb_file.is_file():
        d = json.loads(fb_file.read_text(encoding="utf-8"))
        if d.get("ok") and not d.get("skipped"):
            append_entry(path, run_id=run_id, platform="facebook", units=1, kind="photo")
            recorded.append("facebook")

    return {"ok": True, "recorded": recorded}
