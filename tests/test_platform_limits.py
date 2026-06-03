#!/usr/bin/env python3
"""Tests for platform_limits and publish_quota."""
from __future__ import annotations

import json
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "lib"))

import platform_limits as pl  # noqa: E402
import publish_quota as pq  # noqa: E402


def test_count_hashtags():
    assert pl.count_hashtags("#a #b #c") == 3
    assert pl.count_hashtags("no tags") == 0


def test_threads_post_char_limit():
    run = Path(tempfile.mkdtemp())
    post = run / "post.md"
    long_post = "x" * 501
    post.write_text(
        "## Part 1\n### 貼文 1\n" + long_post + "\n"
        "### 貼文 2\nok\n### 貼文 3\nok\n### 貼文 4\nok\n### 貼文 5\nok\n"
        "## Part 2\n總頁數：8\n### Instagram Caption\n#tag\n",
        encoding="utf-8",
    )
    v = pl.validate_content(run, "pre_hitl", pl.load_limits(ROOT / "data/config/platform_limits.json"))
    assert any(x.code == "chars_per_post" for x in v)


def test_ig_caption_and_hashtag():
    run = Path(tempfile.mkdtemp())
    tags = " ".join(f"#t{i}" for i in range(31))
    (run / "post.md").write_text(
        f"## Part 1\n### 貼文 1\nshort\n### 貼文 2\na\n### 貼文 3\na\n### 貼文 4\na\n### 貼文 5\na\n"
        f"## Part 2\n總頁數：2\n### Instagram Caption\n{'y'*2201}\n{tags}\n",
        encoding="utf-8",
    )
    v = pl.validate_content(run, "pre_hitl")
    codes = {x.code for x in v}
    assert "caption_max_chars" in codes
    assert "hashtag_max" in codes


def test_quota_ig_24h():
    ledger = Path(tempfile.mkdtemp()) / "ledger.jsonl"
    now = datetime.now(timezone.utc)
    for i in range(25):
        ts = (now - timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
        ledger.write_text(
            (ledger.read_text(encoding="utf-8") if ledger.exists() else "")
            + json.dumps({"ts": ts, "run_id": f"r{i}", "platform": "instagram", "units": 1, "kind": "carousel"})
            + "\n",
            encoding="utf-8",
        )
    assert pq.count_units(ledger, "instagram", 24) == 25
    lim = pl.load_limits(ROOT / "data/config/platform_limits.json")
    v = pl.validate_quota("pre_publish", lim, ledger, ig_enabled=True, threads_enabled=False)
    assert any(x.code == "posts_per_24h" for x in v)


def test_format_telegram_message():
    msg = pl.format_telegram_message(
        "run-1",
        "pre_hitl",
        [{"message_zh": "Threads 第 1 則超過 500 字元"}],
    )
    assert "run-1" in msg
    assert "500" in msg
