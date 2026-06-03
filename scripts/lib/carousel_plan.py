#!/usr/bin/env python3
"""Default IG carousel page types (A-F) and prompt assembly."""
from __future__ import annotations

import re
from pathlib import Path

# Default 8-page plan per PAGE_TYPES.md
DEFAULT_8 = ["A", "B", "C", "C", "D", "C", "E", "F"]

TYPE_NAMES = {
    "A": "Cover",
    "B": "Index",
    "C": "Content",
    "D": "Accent",
    "E": "Visual",
    "F": "CTA",
}


def page_plan(total: int) -> list[str]:
    if total == 8:
        return list(DEFAULT_8)
    if total <= 2:
        return ["A", "F"][:total]
    # A, B, then (total-3) x C, then F
    mid = max(0, total - 3)
    plan = ["A", "B"] + ["C"] * mid
    if total >= 5 and "D" not in plan and mid >= 2:
        plan[min(4, len(plan) - 1)] = "D"
    if total >= 7 and "E" not in plan:
        plan[-2] = "E"
    plan.append("F")
    return plan[:total]


def load_visual_base(skill_dir: Path) -> str:
    p = skill_dir / "VISUAL_BASE.md"
    text = p.read_text(encoding="utf-8")
    m = re.search(r"```\s*\n([\s\S]*?)\n```", text)
    return (m.group(1) if m else text).strip()


def load_type_template(skill_dir: Path, page_type: str) -> str:
    text = (skill_dir / "PAGE_TYPES.md").read_text(encoding="utf-8")
    key = f"【類型 {page_type}】"
    idx = text.find(key)
    if idx < 0:
        return f"【頁面類型】{TYPE_NAMES.get(page_type, page_type)}\n【視覺風格】套用基礎風格 Prompt"
    chunk = text[idx:]
    m = re.search(r"```\s*\n([\s\S]*?)\n```", chunk)
    return (m.group(1) if m else "").strip()


def build_page_prompt(
    skill_dir: Path,
    *,
    topic: str,
    audience: str,
    page_num: int,
    total: int,
    page_type: str,
) -> str:
    base = load_visual_base(skill_dir)
    tpl = load_type_template(skill_dir, page_type)
    pn = f"{page_num:02d}"
    total_s = f"{total:02d}"
    filled = (
        tpl.replace("[總頁數]", total_s)
        .replace("[頁碼]", str(page_num))
        .replace("0[頁碼]", pn)
        .replace("[填入你的帳號名稱或系列名稱]", "DOKO.")
        .replace("[帳號或系列名稱]", "DOKO.")
        .replace("[主題系列名，大寫英文]", "PARENTING & BRAIN SCIENCE")
        .replace("[填入你的主題系列名，例如「BUSINESS COMMUNICATION」]", "PARENTING & BRAIN SCIENCE")
        .replace("[6–15 字]", topic[:15])
        .replace("[8–16 字]", topic[:16])
    )
    return (
        f"{base}\n\n"
        f"【任務主題】{topic}\n【受眾】{audience}\n"
        f"{filled}\n\n"
        f"Create ONE 1080x1080 Instagram carousel slide ({TYPE_NAMES.get(page_type, page_type)}). "
        f"Page {pn}/{total_s}. Traditional Chinese on-image text. Editorial Minimalism."
    )


def main_cli() -> int:
    import argparse

    ap = argparse.ArgumentParser()
    ap.add_argument("--extract", type=Path)
    args = ap.parse_args()
    if args.extract:
        for p in extract_prompts_from_post_md(args.extract):
            print(p)
            print("---PAGE---")
    return 0


def extract_prompts_from_post_md(post_md: Path) -> list[str]:
    """Parse ```text blocks under ### 頁 NN — in post.md."""
    if not post_md.is_file():
        return []
    text = post_md.read_text(encoding="utf-8")
    blocks = re.findall(r"###\s*頁\s*\d+[^\n]*\n+```(?:text)?\s*\n([\s\S]*?)```", text, flags=re.I)
    return [b.strip() for b in blocks if b.strip()]
