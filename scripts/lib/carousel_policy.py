#!/usr/bin/env python3
"""Carousel generation policy from TASK.md publish_targets."""
from __future__ import annotations

import re
from pathlib import Path


def publish_targets(task_md: Path) -> set[str]:
    if not task_md.is_file():
        return set()
    for line in task_md.read_text(encoding="utf-8").splitlines():
        if line.strip().lower().startswith("publish_targets:"):
            raw = line.split(":", 1)[1].strip()
            return {p.strip().lower() for p in raw.split(",") if p.strip()}
    return set()


def _task_flag(task_md: Path, key: str) -> str | None:
    if not task_md.is_file():
        return None
    prefix = f"{key}:"
    for line in task_md.read_text(encoding="utf-8").splitlines():
        if line.strip().lower().startswith(prefix):
            return line.split(":", 1)[1].strip().lower()
    return None


def needs_instagram_carousel(targets: set[str]) -> bool:
    return "instagram" in targets


def should_generate_carousel(task_md: Path) -> bool:
    """True only when IG carousel images should be produced."""
    targets = publish_targets(task_md)
    if not needs_instagram_carousel(targets):
        return False
    explicit = _task_flag(task_md, "generate_carousel")
    if explicit in ("false", "no", "0"):
        return False
    if explicit in ("true", "yes", "1"):
        return True
    total_s = _task_flag(task_md, "carousel_total")
    if total_s is not None:
        try:
            return int(total_s) > 0
        except ValueError:
            pass
    return True


def effective_carousel_total(
    post_md: Path,
    task_md: Path,
    default: int = 0,
) -> int:
    """Resolve slide count; 0 when IG not in targets."""
    targets = publish_targets(task_md)
    if not needs_instagram_carousel(targets):
        return 0
    if not should_generate_carousel(task_md):
        return 0

    text = post_md.read_text(encoding="utf-8") if post_md.is_file() else ""
    m = re.search(r"總頁數[：:]\s*(\d+)", text)
    n = int(m.group(1)) if m else default
    if not m:
        rows = re.findall(r"^\|\s*\d+\s*\|", text, flags=re.MULTILINE)
        if rows:
            n = len(rows)

    from parse_carousel_total import ceiling, load_limits

    lo, hi = ceiling(targets, load_limits())
    return max(lo, min(hi, n))
