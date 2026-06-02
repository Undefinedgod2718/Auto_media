#!/usr/bin/env python3
"""Validate post.md structure — ceiling-only; targets from TASK.md."""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

REQUIRED_POSTS = 0  # AI decides count; min 1 if threads target


def _before_part2(text: str) -> str:
    m2 = re.search(r"\n##\s*Part\s*2\b", text, re.I)
    return text[: m2.start()].strip() if m2 else text.strip()


def extract_part1(text: str) -> str:
    prefix = _before_part2(text)
    m = re.search(r"##\s*策略摘要", prefix)
    if m:
        return prefix[m.start() :].strip()
    m = re.search(r"##\s*Part\s*1", prefix, re.I)
    if m:
        return prefix[m.start() :].strip()
    return prefix


def count_posts(part1: str) -> int:
    posts = re.findall(r"###\s*貼文\s*\d+", part1, re.I)
    if posts:
        return len(posts)
    return len(re.findall(r"##\s*第\s*\d+\s*則", part1))


def validate_structure(post_md: Path, run_dir: Path | None = None) -> dict:
    errors: list[str] = []
    warnings: list[str] = []
    text = post_md.read_text(encoding="utf-8", errors="replace") if post_md.is_file() else ""
    if not text.strip():
        errors.append("post.md is empty")
        return {"ok": False, "errors": errors, "warnings": warnings}

    run_dir = run_dir or post_md.parent
    targets: set[str] = set()
    try:
        import parse_task as pt

        targets = pt.publish_targets(run_dir / "TASK.md")
    except ImportError:
        targets = {"instagram", "threads", "facebook"}

    part1 = extract_part1(text)
    n_posts = count_posts(part1)

    if "threads" in targets and n_posts < 1:
        errors.append("Threads 目標需至少 1 則貼文（### 貼文 N）")

    # Part 2/3 are IG-only per copywriter TEMPLATE.md; threads-only must omit them.
    if "instagram" in targets:
        if not re.search(r"##\s*Part\s*2", text, re.I):
            errors.append("missing Part 2 (carousel planning)")
        if not re.search(r"總頁數", text):
            errors.append("missing 總頁數 in planning")
        if not re.search(r"Instagram\s*Caption", text, re.I):
            errors.append("missing Instagram Caption section")

    return {
        "ok": len(errors) == 0,
        "errors": errors,
        "warnings": warnings,
        "part1_chars": len(part1),
        "total_chars": len(text),
        "post_count": n_posts,
        "publish_targets": sorted(targets),
    }


def validate(post_md: Path, run_dir: Path | None = None) -> dict:
    struct = validate_structure(post_md, run_dir)
    if not struct["ok"]:
        return struct

    run_dir = run_dir or post_md.parent
    try:
        import platform_limits as pl

        targets = set(struct.get("publish_targets") or [])
        content = pl.validate_content(
            run_dir,
            "pre_hitl",
            targets=targets,
        )
        if content:
            struct["ok"] = False
            struct["errors"] = [v.message_zh for v in content]
            struct["violations"] = [v.to_dict() for v in content]
    except ImportError:
        pass
    except (FileNotFoundError, json.JSONDecodeError) as e:
        struct["ok"] = False
        struct["errors"] = [f"platform limits config: {e}"]
    return struct


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("post_md", type=Path)
    ap.add_argument("--run-dir", type=Path, default=None)
    args = ap.parse_args()
    run_dir = args.run_dir or args.post_md.parent
    result = validate(args.post_md, run_dir)
    print(json.dumps(result, ensure_ascii=False))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
