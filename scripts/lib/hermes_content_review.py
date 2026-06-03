#!/usr/bin/env python3
"""Rule-based Hermes content review plan (no LLM rewrite)."""
from __future__ import annotations

import json
import re
from pathlib import Path

try:
    import parse_task as pt
    import platform_limits as pl
except ImportError:
    pt = None  # type: ignore
    pl = None  # type: ignore


def _extract_part1(text: str) -> str:
    m2 = re.search(r"\n##\s*Part\s*2\b", text, re.I)
    prefix = text[: m2.start()] if m2 else text
    m = re.search(r"##\s*Part\s*1", prefix, re.I)
    return prefix[m.start() :].strip() if m else prefix.strip()


def _threads_posts(part1: str) -> list[str]:
    posts = re.findall(
        r"(###\s*貼文\s*\d+[^\n]*\n[\s\S]*?)(?=\n###\s*貼文\s*\d+|$)",
        part1,
        flags=re.I,
    )
    if posts:
        return [p.strip() for p in posts if p.strip()]
    chunks = re.findall(
        r"(##\s*第\s*\d+\s*則[^\n]*\n[\s\S]*?)(?=\n##\s*第\s*\d+\s*則|$)",
        part1,
        flags=re.I,
    )
    if chunks:
        return [c.strip() for c in chunks if c.strip()]
    # Single-block Threads copy (no numbered sections).
    body = part1.strip()
    return [body] if body else []


def _ig_caption(text: str) -> str:
    for pat in (
        r"###\s*Instagram\s*Caption[^\n]*\n+([\s\S]*?)(?=\n###\s|\n##\s|---\s*$|\Z)",
        r"##\s*Instagram\s*Caption[^\n]*\n+([\s\S]*?)(?=\n##\s|---\s*$|\Z)",
    ):
        m = re.search(pat, text, re.I)
        if m:
            return m.group(1).strip()
    return ""


def build_plan(run_dir: Path) -> dict:
    lim = pl.load_limits() if pl else {}
    th_lim = lim.get("threads", {})
    ig_lim = lim.get("instagram", {})
    max_chars = int(th_lim.get("chars_per_post", 500))
    target_hint = int(th_lim.get("chars_per_post_target", 450))

    task_path = run_dir / "TASK.md"
    targets = pt.publish_targets(task_path) if pt else {"instagram", "threads", "facebook"}
    post_path = run_dir / "post.md"
    text = post_path.read_text(encoding="utf-8", errors="replace") if post_path.is_file() else ""

    plan: dict = {
        "run_id": run_dir.name,
        "publish_targets": sorted(targets),
        "verdict_hint": "pass",
        "threads": {},
        "instagram": {},
        "images": {},
        "notes": [],
    }

    part1 = _extract_part1(text)
    posts = _threads_posts(part1)
    break_hints: list[str] = []
    char_warnings: list[dict] = []
    fail = False

    if "threads" in targets:
        for i, post in enumerate(posts, start=1):
            n = len(post)
            if n > max_chars:
                fail = True
                char_warnings.append({"post": i, "chars": n, "limit": max_chars, "level": "fail"})
            elif n > target_hint:
                char_warnings.append({"post": i, "chars": n, "limit": target_hint, "level": "warn"})
                break_hints.append(
                    f"貼文 {i} 共 {n} 字，建議在 ~{target_hint} 字附近斷句以利串文銜接"
                )
        plan["threads"] = {
            "post_count": len(posts),
            "break_hints": break_hints,
            "char_warnings": char_warnings,
        }
        if not posts:
            plan["notes"].append("未偵測到 Threads 貼文區塊，請確認 post.md 結構")
            fail = True

    if "instagram" in targets:
        cap = _ig_caption(text)
        m = re.search(r"總頁數\s*[：:]\s*(?:\*\*)?\s*(\d+)", text)
        carousel_n = int(m.group(1)) if m else 0
        plan["instagram"] = {
            "carousel_count": carousel_n,
            "caption_chars": len(cap),
            "caption_strategy": "使用 Part 2 Instagram Caption 摘要（非五則全文貼上）",
        }
        if cap and len(cap) > int(ig_lim.get("caption_max_chars", 2200)):
            fail = True

    carousel_dir = run_dir / "carousel"
    slide_count = 0
    if carousel_dir.is_dir():
        slide_count = len(list(carousel_dir.glob("*.png"))) + len(list(carousel_dir.glob("*.jpg")))
    img_cap = 10
    if pl:
        img_cap = pl._image_ceiling(targets, lim)  # type: ignore[attr-defined]
    plan["images"] = {
        "count": slide_count,
        "ceiling": img_cap,
        "within_limits": slide_count <= img_cap,
    }
    if slide_count > img_cap:
        fail = True
        plan["notes"].append(f"圖片 {slide_count} 張超過共用上限 {img_cap}（IG≤10、Threads≤20）")

    if pl:
        violations = pl.validate_content(run_dir, "pre_hitl", targets=targets)
        for v in violations:
            plan["notes"].append(v.message_zh)
            fail = True

    plan["verdict_hint"] = "fail" if fail else ("warn" if char_warnings else "pass")
    return plan


def format_telegram(plan: dict) -> str:
    lines = [
        "Hermes 內容審閱（不重寫全文）",
        f"run_id: {plan.get('run_id', '')}",
        f"發佈目標: {', '.join(plan.get('publish_targets', []))}",
        f"判定: {plan.get('verdict_hint', 'pass')}",
        "",
    ]
    th = plan.get("threads") or {}
    if th:
        lines.append(f"Threads：{th.get('post_count', 0)} 則")
        for h in th.get("break_hints") or []:
            lines.append(f"  · {h}")
    ig = plan.get("instagram") or {}
    if ig:
        lines.append(
            f"Instagram：輪播 {ig.get('carousel_count', 0)} 張；Caption {ig.get('caption_chars', 0)} 字"
        )
        lines.append(f"  · {ig.get('caption_strategy', '')}")
    img = plan.get("images") or {}
    if img:
        lines.append(f"圖片：{img.get('count', 0)} 張（上限 {img.get('ceiling', 10)}）")
    for n in plan.get("notes") or []:
        lines.append(f"⚠ {n}")
    lines.append("")
    lines.append("接續會送出完整預覽；若預覽失敗，將在本訊息下方提供審核按鈕。")
    return "\n".join(lines)


def _write_plan_file(path: Path, body: str) -> None:
    """Write plan JSON; recover when a root-owned file blocks n8n (node) overwrite."""
    try:
        path.write_text(body, encoding="utf-8")
    except PermissionError:
        if path.exists():
            try:
                path.unlink()
            except OSError:
                pass
        path.write_text(body, encoding="utf-8")


def main(run_dir: Path) -> int:
    plan = build_plan(run_dir)
    out = run_dir / "hermes_plan.json"
    _write_plan_file(out, json.dumps(plan, ensure_ascii=False, indent=2) + "\n")
    verdict = plan["verdict_hint"]
    print(
        json.dumps(
            {"ok": True, "path": str(out), "verdict": verdict, "verdict_hint": verdict},
            ensure_ascii=False,
        )
    )
    # Advisory review: always exit 0 so n8n continues; consumers read verdict_hint.
    return 0


if __name__ == "__main__":
    import sys

    sys.exit(main(Path(sys.argv[1])))
