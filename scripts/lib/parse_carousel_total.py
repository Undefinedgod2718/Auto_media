#!/usr/bin/env python3
"""Parse carousel slide count from post.md with platform ceiling from TASK."""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from media_paths import config_path, meta_config_path

LIMITS_PATH = meta_config_path("limits.json")
LEGACY_LIMITS_PATH = config_path("platform_limits.json")

from carousel_policy import (  # noqa: E402
    effective_carousel_total,
    needs_instagram_carousel,
    publish_targets,
    should_generate_carousel,
)


def load_limits() -> dict:
    for p in (LIMITS_PATH, LEGACY_LIMITS_PATH):
        if p.is_file():
            return json.loads(p.read_text(encoding="utf-8"))
    raise FileNotFoundError(f"limits not found: {LIMITS_PATH} or {LEGACY_LIMITS_PATH}")


def ceiling(targets: set[str], lim: dict | None = None) -> tuple[int, int]:
    lim = lim or load_limits()
    if not needs_instagram_carousel(targets):
        return 0, 0
    hi = lim["instagram"]["carousel_items_max"]
    lo = lim["instagram"].get("carousel_items_min", 2)
    if "threads" in targets:
        hi = min(hi, lim["threads"]["carousel_media_max"])
    return lo, hi


def parse_total(post_md: Path, task_md: Path | None = None, default: int = 0) -> int:
    task = task_md or (post_md.parent / "TASK.md")
    return effective_carousel_total(post_md, task, default=default)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("post_md", type=Path)
    ap.add_argument("--task-md", type=Path, default=None)
    ap.add_argument("--default", type=int, default=0)
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()
    task = args.task_md
    if task is None and args.post_md.parent.joinpath("TASK.md").is_file():
        task = args.post_md.parent / "TASK.md"
    targets = publish_targets(task) if task else set()
    total = parse_total(args.post_md, task, args.default)
    if args.json:
        lo, hi = ceiling(targets)
        print(
            json.dumps(
                {
                    "total": total,
                    "min": lo if needs_instagram_carousel(targets) else 0,
                    "max": hi,
                    "targets": sorted(targets),
                    "should_generate": should_generate_carousel(task) if task else False,
                },
                ensure_ascii=False,
            )
        )
    else:
        print(total)
    return 0


if __name__ == "__main__":
    sys.exit(main())
