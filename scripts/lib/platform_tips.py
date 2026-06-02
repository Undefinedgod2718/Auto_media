#!/usr/bin/env python3
"""Build Telegram tip text from platform_limits.json."""
from __future__ import annotations

import json
from pathlib import Path

from media_paths import config_path, meta_config_path

LIMITS_PATH = meta_config_path("limits.json")
LEGACY_LIMITS_PATH = config_path("platform_limits.json")


def load_limits() -> dict:
    for p in (LIMITS_PATH, LEGACY_LIMITS_PATH):
        if p.is_file():
            return json.loads(p.read_text(encoding="utf-8"))
    raise FileNotFoundError(f"limits not found: {LIMITS_PATH} or {LEGACY_LIMITS_PATH}")


def format_platform_tips() -> str:
    lim = load_limits()
    ig = lim["instagram"]
    th = lim["threads"]
    fb = lim["facebook"]
    mb = th.get("image_max_bytes", 8388608) // (1024 * 1024)
    return (
        "發文規則上限（請至少選一個平台）：\n"
        f"• Instagram：輪播 2–{ig['carousel_items_max']} 張；Caption ≤{ig['caption_max_chars']} 字；"
        f"Hashtag ≤{ig['hashtag_max']} 個\n"
        f"• Threads：單則 ≤{th['chars_per_post']} 字（建議 ~{th.get('chars_per_post_target', 450)} 斷句）；"
        f"輪播最多 {th['carousel_media_max']} 圖/影；非輪播 {th['single_post_media_max']} 圖；"
        f"JPEG/PNG ≤{mb}MB\n"
        f"• Facebook：貼文 ≤{fb['message_max_chars']} 字\n"
        "下方按鈕可多選，選好後按「開始產出」。"
    )


def parse_publish_targets(task_text: str) -> set[str]:
    for line in task_text.splitlines():
        if line.strip().lower().startswith("publish_targets:"):
            raw = line.split(":", 1)[1].strip()
            return {p.strip().lower() for p in raw.split(",") if p.strip()}
    return set()


def image_ceiling_for_targets(targets: set[str], planned: int) -> int:
    """Shared asset pool ceiling when IG + Threads both selected."""
    lim = load_limits()
    cap = planned
    if "instagram" in targets:
        cap = min(cap, lim["instagram"]["carousel_items_max"])
    if "threads" in targets:
        cap = min(cap, lim["threads"]["carousel_media_max"])
    return max(1, cap)
