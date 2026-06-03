#!/usr/bin/env python3
"""Extract Instagram caption from post.md."""
from __future__ import annotations

import re
import sys
from pathlib import Path

MAX_LEN = 2200
MIN_CAPTION = 80


def extract_part1_posts(text: str) -> list[str]:
    part1 = text
    if re.search(r"##\s*Part\s*2", text, re.I):
        part1 = re.split(r"\n##\s*Part\s*2", text, maxsplit=1, flags=re.I)[0]
    posts = re.findall(
        r"###\s*貼文\s*\d+[^\n]*\n([\s\S]*?)(?=\n###\s*貼文\s*\d+|$)",
        part1,
        flags=re.I,
    )
    if posts:
        return [p.strip() for p in posts if p.strip()]
    posts = re.findall(
        r"##\s*第\s*\d+\s*則[^\n]*\n([\s\S]*?)(?=\n##\s*第\s*\d+\s*則|$)",
        part1,
    )
    return [p.strip() for p in posts if p.strip()]


def extract_caption(post_md: Path) -> str:
    text = post_md.read_text(encoding="utf-8") if post_md.is_file() else ""
    patterns = [
        r"###\s*Instagram\s*Caption[^\n]*\n+([\s\S]*?)(?=\n###\s|\n##\s|---\s*$|\Z)",
        r"##\s*Instagram\s*Caption[^\n]*\n+([\s\S]*?)(?=\n##\s|---\s*$|\Z)",
    ]
    caption = ""
    for pat in patterns:
        m = re.search(pat, text, flags=re.IGNORECASE)
        if m:
            caption = m.group(1).strip()
            break

    if len(caption) < MIN_CAPTION:
        posts = extract_part1_posts(text)
        if posts:
            summary = "\n\n".join(f"• {p[:120].strip()}…" if len(p) > 120 else f"• {p}" for p in posts[:5])
            caption = (caption + "\n\n" + summary).strip() if caption else summary

    if not caption:
        m = re.search(r"^([\s\S]*?)(?=\n##\s*Part\s*2|\n---\s*$)", text, flags=re.MULTILINE)
        if m:
            caption = m.group(1).strip()

    if not caption:
        # Fallback for single-block copy without Part 2 / section markers.
        caption = text.strip()

    # Clean markdown heading markers, but keep hashtags (#tag) intact.
    caption = re.sub(r"^\s*#{1,6}\s+", "", caption, flags=re.MULTILINE).strip()

    return caption[:MAX_LEN]


def main() -> int:
    path = Path(sys.argv[1])
    print(extract_caption(path))
    return 0


if __name__ == "__main__":
    sys.exit(main())
