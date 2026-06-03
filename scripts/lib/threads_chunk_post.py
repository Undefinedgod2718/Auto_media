#!/usr/bin/env python3
"""Normalize post.md and split into Threads-safe text chunks."""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

META_PATTERNS = [
    r"I have completed the (?:task|copywriting)",
    r"Successfully generated",
    r"(?:written|saved)(?:\s+the\s+social\s+media\s+post)?\s+to\s+[`']?/data/runs/.*/post\.md",
    r"Research\s*&\s*Synthesis",
    r"\*\*Implementation:\*\*",
    r"The post is now ready for use",
]


def has_meta(text: str) -> bool:
    return any(re.search(p, text, re.I) for p in META_PATTERNS)


def strip_meta(text: str) -> str:
    if not has_meta(text):
        return text.strip()
    for i, line in enumerate(text.splitlines()):
        if len(re.findall(r"[\u4e00-\u9fff]", line)) >= 4:
            body = "\n".join(text.splitlines()[i:]).strip()
            if len(re.findall(r"[\u4e00-\u9fff]", body)) >= 20:
                return body
    return text.strip()


def extract_part1(md: str) -> str:
    s = strip_meta(md.strip())
    if re.search(r"##\s*Part\s*2", s, re.I):
        s = re.split(r"\n##\s*Part\s*2", s, maxsplit=1, flags=re.I)[0].strip()
    return s


def split_by_post(part1: str) -> list[str]:
    chunks: list[str] = []
    if re.search(r"###\s*貼文\s*\d+", part1, re.I):
        parts = re.findall(
            r"(###\s*貼文\s*\d+[^\n]*\n[\s\S]*?)(?=\n###\s*貼文\s*\d+|$)",
            part1,
            flags=re.I,
        )
        if parts:
            return [p.strip() for p in parts if p.strip()]
    if re.search(r"##\s*第\s*\d+\s*則", part1):
        parts = re.findall(
            r"(##\s*第\s*\d+\s*則[^\n]*\n[\s\S]*?)(?=\n##\s*第\s*\d+\s*則|$)",
            part1,
        )
        if parts:
            return [p.strip() for p in parts if p.strip()]
    return []


def clamp_post(text: str, max_chars: int) -> str:
    text = text.strip()
    if len(text) <= max_chars:
        return text
    cut = text[: max_chars - 1]
    nl = cut.rfind("\n")
    if nl > max_chars * 0.5:
        cut = cut[:nl]
    else:
        cut = cut.rstrip()
    return cut.rstrip() + "…"


def chunk_text(text: str, max_chars: int) -> list[str]:
    text = text.strip()
    if not text:
        return []
    if len(text) <= max_chars:
        return [text]

    chunks: list[str] = []
    rest = text
    while rest:
        if len(rest) <= max_chars:
            chunks.append(rest.strip())
            break
        window = rest[: max_chars + 1]
        cut = window.rfind("\n\n")
        if cut < max_chars // 3:
            for sep in ("\n", "。", "！", "？", ". ", " "):
                cut = window.rfind(sep, 0, max_chars + 1)
                if cut >= max_chars // 3:
                    break
        if cut < max_chars // 3:
            cut = max_chars
        piece = rest[:cut].strip()
        if not piece:
            piece = rest[:max_chars].strip()
            cut = max_chars
        chunks.append(piece)
        rest = rest[cut:].lstrip()
    return [c for c in chunks if c]


def build_chunks(md: str, mode: str, max_chars: int) -> tuple[list[str], str]:
    part1 = extract_part1(md)
    if mode == "by_post":
        posts = split_by_post(part1)
        if posts:
            return [clamp_post(p, max_chars) for p in posts], "by_post"
    posts = split_by_post(part1)
    normalized = "\n\n".join(posts) if posts else part1
    return chunk_text(normalized, max_chars), "by_chars"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("post_md", type=Path)
    ap.add_argument("--max-chars", type=int, default=450)
    ap.add_argument("--mode", choices=("by_post", "by_chars"), default="by_post")
    args = ap.parse_args()
    raw = args.post_md.read_text(encoding="utf-8", errors="replace")
    chunks, mode_used = build_chunks(raw, args.mode, args.max_chars)
    out = {
        "chunks": chunks,
        "chunk_count": len(chunks),
        "mode": mode_used,
        "max_chars": args.max_chars,
    }
    print(json.dumps(out, ensure_ascii=False))
    return 0 if chunks else 1


if __name__ == "__main__":
    sys.exit(main())
