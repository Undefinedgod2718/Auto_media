#!/usr/bin/env python3
from __future__ import annotations

import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "lib"))

from validate_post_md import validate_structure  # noqa: E402


def test_threads_only_omits_part2():
    run = Path(tempfile.mkdtemp())
    (run / "TASK.md").write_text(
        "topic: test\npublish_targets: threads\ngenerate_carousel: false\n",
        encoding="utf-8",
    )
    (run / "post.md").write_text(
        "## 策略摘要\n\n| 則 | 前 26 字 |\n|----|----------|\n| 1 | hook |\n\n"
        "## Part 1 — Threads\n\n### 貼文 1\n\nbody\n",
        encoding="utf-8",
    )
    r = validate_structure(run / "post.md", run)
    assert r["ok"] is True
    assert r["publish_targets"] == ["threads"]


def test_instagram_requires_part2():
    run = Path(tempfile.mkdtemp())
    (run / "TASK.md").write_text("topic: test\npublish_targets: instagram\n", encoding="utf-8")
    (run / "post.md").write_text("## Part 1\n### 貼文 1\nx\n", encoding="utf-8")
    r = validate_structure(run / "post.md", run)
    assert r["ok"] is False
    assert "missing Part 2" in r["errors"][0]
