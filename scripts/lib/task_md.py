#!/usr/bin/env python3
"""Build and write TASK.md — single source of TASK logic (replaces write_task.sh).

topic and other free-text fields never reach a shell here: this module writes
the file directly via Python I/O, so callers (Gateway, /internal/write-task)
pass values as plain arguments, not interpolated command strings.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path

import run_state

RUN_ID_RE = re.compile(r"^[A-Za-z0-9_-]+$")


def _data_root() -> Path:
    return Path(os.environ.get("DATA_ROOT", "/data"))


def ensure_run_dir(run_id: str) -> Path:
    """Validate run_id as a bare directory name and create data/runs/<run_id>.

    Mirrors ensure_run_dir in scripts/lib/common.sh: run_id is a directory
    name, never a path or template, so reject anything outside [A-Za-z0-9_-]+.
    """
    if not RUN_ID_RE.match(run_id):
        raise ValueError(f"invalid run_id (expected [A-Za-z0-9_-]+): {run_id!r}")
    run_dir = _data_root() / "runs" / run_id
    run_dir.mkdir(parents=True, exist_ok=True)
    return run_dir


def _resolve_carousel(
    publish_targets: str,
    generate_carousel: str,
    carousel_total: str,
) -> tuple[str, str]:
    """Default carousel policy from publish_targets (mirrors write_task.sh)."""
    if not generate_carousel and publish_targets:
        if "instagram" in publish_targets.lower():
            generate_carousel = "true"
            if not carousel_total:
                carousel_total = "0"
        else:
            generate_carousel = "false"
            carousel_total = "0"
    if not carousel_total and generate_carousel == "false":
        carousel_total = "0"
    return generate_carousel, carousel_total


def build_task_md(
    *,
    topic: str,
    audience: str = "general",
    action: str = "generate_copy",
    carousel_total: str = "",
    page_type: str = "",
    publish_targets: str = "",
    publish_mode_threads: str = "carousel",
    generate_carousel: str = "",
) -> str:
    """Return TASK.md content. Field order matches the original write_task.sh."""
    generate_carousel, carousel_total = _resolve_carousel(
        publish_targets, generate_carousel, carousel_total
    )
    lines = [
        "# TASK",
        f"topic: {topic}",
        f"audience: {audience}",
        f"action: {action}",
    ]
    if carousel_total:
        lines.append(f"carousel_total: {carousel_total}")
    if page_type:
        lines.append(f"page_type: {page_type}")
    if publish_targets:
        lines.append(f"publish_targets: {publish_targets}")
    if publish_mode_threads:
        lines.append(f"publish_mode_threads: {publish_mode_threads}")
    if generate_carousel:
        lines.append(f"generate_carousel: {generate_carousel}")
    return "\n".join(lines) + "\n"


def write_task_md(
    run_id: str,
    *,
    topic: str,
    audience: str = "general",
    action: str = "generate_copy",
    carousel_total: str = "",
    page_type: str = "",
    publish_targets: str = "",
    publish_mode_threads: str = "carousel",
    generate_carousel: str = "",
) -> Path:
    """Write TASK.md for run_id and mark run_state task_written. Returns path."""
    if not topic:
        raise ValueError("topic is required")
    run_dir = ensure_run_dir(run_id)
    content = build_task_md(
        topic=topic,
        audience=audience,
        action=action,
        carousel_total=carousel_total,
        page_type=page_type,
        publish_targets=publish_targets,
        publish_mode_threads=publish_mode_threads,
        generate_carousel=generate_carousel,
    )
    task_file = run_dir / "TASK.md"
    task_file.write_text(content, encoding="utf-8")

    # Mirror run_state_ensure + run_state_mark_stage from write_task.sh.
    run_state.save_state(run_dir, run_state.load_state(run_dir, run_id))
    try:
        run_state.save_state(
            run_dir, run_state.mark_stage(run_dir, run_id, "task_written")
        )
    except ValueError:
        # write_task.sh ignored mark failures ("|| true"); keep that behavior.
        pass
    return task_file


def main(argv: list[str] | None = None) -> int:
    """CLI shim (replaces scripts/write_task.sh). Args are argv, never a shell."""
    ap = argparse.ArgumentParser(description="Write TASK.md for a run")
    ap.add_argument("--run-id", required=True)
    ap.add_argument("--topic", required=True)
    ap.add_argument("--audience", default="general")
    ap.add_argument("--action", default="generate_copy")
    ap.add_argument("--carousel-total", default="")
    ap.add_argument("--page-type", default="")
    ap.add_argument("--publish-targets", default="")
    ap.add_argument("--publish-mode-threads", default="carousel")
    ap.add_argument("--generate-carousel", default="")
    args = ap.parse_args(argv)
    try:
        path = write_task_md(
            args.run_id,
            topic=args.topic,
            audience=args.audience,
            action=args.action,
            carousel_total=args.carousel_total,
            page_type=args.page_type,
            publish_targets=args.publish_targets,
            publish_mode_threads=args.publish_mode_threads,
            generate_carousel=args.generate_carousel,
        )
    except ValueError as e:
        print(json.dumps({"ok": False, "error": str(e)}, ensure_ascii=False), file=sys.stderr)
        return 1
    print(json.dumps({"ok": True, "path": str(path)}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
