#!/usr/bin/env python3
from __future__ import annotations

import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "lib"))

from ig_caption import extract_caption  # noqa: E402


def test_extract_caption_fallback_single_block_strips_heading():
    run = Path(tempfile.mkdtemp())
    post = run / "post.md"
    post.write_text(
        "# 標題\n\n這是一段沒有 Instagram Caption 區塊的單段文案。\n#hashtag\n",
        encoding="utf-8",
    )
    got = extract_caption(post)
    assert "標題" in got
    assert got.startswith("標題")
    assert "#hashtag" in got
    assert not got.startswith("#")


def test_extract_caption_prefers_section_when_present():
    run = Path(tempfile.mkdtemp())
    post = run / "post.md"
    post.write_text(
        "## Part 1\n### 貼文 1\nthreads\n\n## Part 2\n### Instagram Caption\n專用 caption\n",
        encoding="utf-8",
    )
    got = extract_caption(post)
    # Caption section is preferred as base, then short-caption fallback may append
    # Part 1 bullets to reach MIN_CAPTION.
    assert got.startswith("專用 caption")
    assert "threads" in got
