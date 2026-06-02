#!/usr/bin/env python3
"""Platform content + quota validation (IG / Threads / Facebook)."""
from __future__ import annotations

import json
import os
import re
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

from media_paths import config_path, data_root

DEFAULT_LIMITS_PATH = config_path("platform_limits.json")
DATA_ROOT = data_root()
QUOTA_LEDGER = DATA_ROOT / "hitl" / "publish_quota.jsonl"


@dataclass
class Violation:
    platform: str
    code: str
    message_zh: str
    current: int | str
    limit: int | str
    phase: str = "pre_hitl"

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


def load_limits(path: Path | None = None) -> dict[str, Any]:
    p = path or DEFAULT_LIMITS_PATH
    if not p.is_file():
        raise FileNotFoundError(f"platform_limits.json not found: {p}")
    return json.loads(p.read_text(encoding="utf-8"))


def count_hashtags(text: str) -> int:
    tags = re.findall(r"(?<!\w)#[\w\u0080-\uFFFF]+", text)
    return len(tags)


def _extract_ig_caption(text: str) -> str:
    for pat in (
        r"###\s*Instagram\s*Caption[^\n]*\n+([\s\S]*?)(?=\n###\s|\n##\s|---\s*$|\Z)",
        r"##\s*Instagram\s*Caption[^\n]*\n+([\s\S]*?)(?=\n##\s|---\s*$|\Z)",
    ):
        m = re.search(pat, text, flags=re.I)
        if m:
            return m.group(1).strip()
    return ""


def _split_threads_posts(part1: str) -> list[str]:
    if re.search(r"###\s*貼文\s*\d+", part1, re.I):
        parts = re.findall(
            r"(###\s*貼文\s*\d+[^\n]*\n[\s\S]*?)(?=\n###\s*貼文\s*\d+|$)",
            part1,
            flags=re.I,
        )
        if parts:
            return [p.strip() for p in parts if p.strip()]
    parts = re.findall(
        r"(##\s*第\s*\d+\s*則[^\n]*\n[\s\S]*?)(?=\n##\s*第\s*\d+\s*則|$)",
        part1,
    )
    return [p.strip() for p in parts if p.strip()]


def _extract_part1(text: str) -> str:
    m = re.search(r"##\s*Part\s*1", text, re.I)
    if not m:
        return text
    rest = text[m.start() :]
    m2 = re.search(r"\n##\s*Part\s*2", rest, re.I)
    if m2:
        return rest[: m2.start()].strip()
    return rest.strip()


def _carousel_total_from_task(task_md: Path) -> int | None:
    if not task_md.is_file():
        return None
    for line in task_md.read_text(encoding="utf-8").splitlines():
        m = re.match(r"^carousel_total:\s*(\d+)", line.strip())
        if m:
            return int(m.group(1))
    return None


def _count_carousel_slides(carousel_dir: Path) -> int:
    if not carousel_dir.is_dir():
        return 0
    return len(list(carousel_dir.glob("*.png"))) + len(list(carousel_dir.glob("*.jpg")))


def _targets_from_run(run_dir: Path, targets: set[str] | None) -> set[str]:
    if targets is not None:
        return {t.lower() for t in targets}
    try:
        import parse_task as pt

        return pt.publish_targets(run_dir / "TASK.md")
    except ImportError:
        return {"instagram", "threads", "facebook"}


def _image_ceiling(targets: set[str], lim: dict) -> int:
    cap = 20
    if "instagram" in targets:
        cap = min(cap, lim["instagram"]["carousel_items_max"])
    if "threads" in targets:
        cap = min(cap, lim["threads"]["carousel_media_max"])
    return cap


def _check_image_files(carousel_dir: Path, max_bytes: int, phase: str) -> list[Violation]:
    violations: list[Violation] = []
    if not carousel_dir.is_dir():
        return violations
    for p in list(carousel_dir.glob("*.png")) + list(carousel_dir.glob("*.jpg")):
        sz = p.stat().st_size
        if sz > max_bytes:
            violations.append(
                Violation(
                    "shared",
                    "image_max_bytes",
                    f"圖片 {p.name} 超過 {max_bytes // (1024*1024)}MB",
                    sz,
                    max_bytes,
                    phase,
                )
            )
    return violations


def validate_content(
    run_dir: Path,
    phase: str = "pre_hitl",
    limits: dict | None = None,
    targets: set[str] | None = None,
) -> list[Violation]:
    lim = limits or load_limits()
    ig = lim["instagram"]
    th = lim["threads"]
    fb = lim["facebook"]
    shared = lim.get("shared", {})
    max_bytes = int(shared.get("image_max_bytes", th.get("image_max_bytes", 8388608)))
    targets = _targets_from_run(run_dir, targets)
    violations: list[Violation] = []

    post_md = run_dir / "post.md"
    text = post_md.read_text(encoding="utf-8", errors="replace") if post_md.is_file() else ""
    if not text.strip():
        violations.append(
            Violation("system", "missing_post", "缺少 post.md", 0, 1, phase)
        )
        return violations

    part1 = _extract_part1(text)
    posts = _split_threads_posts(part1)

    if "threads" in targets:
        max_chars = th["chars_per_post"]
        for i, post in enumerate(posts, start=1):
            n = len(post)
            if n > max_chars:
                violations.append(
                    Violation(
                        "threads",
                        "chars_per_post",
                        f"Threads 第 {i} 則超過 {max_chars} 字元",
                        n,
                        max_chars,
                        phase,
                    )
                )

    caption = _extract_ig_caption(text)

    if "instagram" in targets:
        cap_max = ig["caption_max_chars"]
        if caption and len(caption) > cap_max:
            violations.append(
                Violation(
                    "instagram",
                    "caption_max_chars",
                    f"IG 說明超過 {cap_max} 字",
                    len(caption),
                    cap_max,
                    phase,
                )
            )
        tag_max = ig["hashtag_max"]
        if caption:
            n_tags = count_hashtags(caption)
            if n_tags > tag_max:
                violations.append(
                    Violation(
                        "instagram",
                        "hashtag_max",
                        f"IG Hashtag 最多 {tag_max} 個",
                        n_tags,
                        tag_max,
                        phase,
                    )
                )

    slide_count = _count_carousel_slides(run_dir / "carousel")
    img_cap = _image_ceiling(targets, lim)
    task_total = _carousel_total_from_task(run_dir / "TASK.md")

    if "instagram" in targets:
        ig_max = ig["carousel_items_max"]
        if task_total is not None and task_total > ig_max:
            violations.append(
                Violation(
                    "instagram",
                    "carousel_items_max",
                    f"IG API 輪播最多 {ig_max} 張",
                    task_total,
                    ig_max,
                    phase,
                )
            )
        if slide_count > ig_max:
            violations.append(
                Violation(
                    "instagram",
                    "carousel_items_max",
                    f"IG API 輪播最多 {ig_max} 張",
                    slide_count,
                    ig_max,
                    phase,
                )
            )

    if "threads" in targets:
        th_max = th["carousel_media_max"]
        if slide_count > th_max:
            violations.append(
                Violation(
                    "threads",
                    "carousel_media_max",
                    f"Threads 輪播 API 最多 {th_max} 張媒體",
                    slide_count,
                    th_max,
                    phase,
                )
            )

    if slide_count > img_cap:
        violations.append(
            Violation(
                "shared",
                "carousel_ceiling",
                f"共用圖集超過平台上限（{slide_count} 張，上限 {img_cap}）",
                slide_count,
                img_cap,
                phase,
            )
        )

    violations.extend(_check_image_files(run_dir / "carousel", max_bytes, phase))

    if "facebook" in targets:
        fb_message = caption or part1
        fb_max = fb["message_max_chars"]
        if len(fb_message) > fb_max:
            violations.append(
                Violation(
                    "facebook",
                    "message_max_chars",
                    f"FB 貼文超過 {fb_max} 字元",
                    len(fb_message),
                    fb_max,
                    phase,
                )
            )

    return violations


def validate_quota(
    phase: str = "pre_publish",
    limits: dict | None = None,
    ledger_path: Path | None = None,
    *,
    ig_enabled: bool = True,
    threads_enabled: bool = True,
) -> list[Violation]:
    if phase != "pre_publish":
        return []
    import publish_quota as pq

    count_units = pq.count_units
    planned_units = pq.planned_units

    lim = limits or load_limits()
    violations: list[Violation] = []
    path = ledger_path or QUOTA_LEDGER

    if ig_enabled:
        ig_lim = lim["instagram"]["posts_per_24h"]
        used = count_units(path, "instagram", hours=24)
        need = planned_units("instagram")
        if used + need > ig_lim:
            violations.append(
                Violation(
                    "instagram",
                    "posts_per_24h",
                    f"IG 24 小時 API 發文將超出上限（已發 {used}，本輪 +{need}，上限 {ig_lim}）",
                    used + need,
                    ig_lim,
                    phase,
                )
            )

    if threads_enabled:
        th = lim["threads"]
        used_24 = count_units(path, "threads", hours=24)
        used_1h = count_units(path, "threads", hours=1)
        need = planned_units("threads")
        if used_24 + need > th["posts_per_24h"]:
            violations.append(
                Violation(
                    "threads",
                    "posts_per_24h",
                    f"Threads 24 小時將超出 {th['posts_per_24h']} 則（已發 {used_24}，本輪 +{need}）",
                    used_24 + need,
                    th["posts_per_24h"],
                    phase,
                )
            )
        if used_1h + need > th["posts_per_hour"]:
            violations.append(
                Violation(
                    "threads",
                    "posts_per_hour",
                    f"Threads 1 小時將超出 {th['posts_per_hour']} 則（已發 {used_1h}，本輪 +{need}）",
                    used_1h + need,
                    th["posts_per_hour"],
                    phase,
                )
            )

    return violations


def check_run(
    run_dir: Path,
    phase: str,
    *,
    ig_enabled: bool | None = None,
    threads_enabled: bool | None = None,
    fb_enabled: bool | None = None,
    targets: set[str] | None = None,
) -> dict[str, Any]:
    targets = _targets_from_run(run_dir, targets)
    ig_enabled = (
        ig_enabled
        if ig_enabled is not None
        else bool(os.environ.get("IG_USER_ID")) and "instagram" in targets
    )
    threads_enabled = (
        threads_enabled
        if threads_enabled is not None
        else bool(os.environ.get("THREADS_USER_ID")) and "threads" in targets
    )
    fb_enabled = (
        fb_enabled
        if fb_enabled is not None
        else bool(os.environ.get("META_PAGE_ID")) and "facebook" in targets
    )

    violations = validate_content(run_dir, phase, targets=targets)
    violations.extend(
        validate_quota(
            phase,
            ig_enabled=ig_enabled,
            threads_enabled=threads_enabled,
        )
    )
    return {
        "ok": len(violations) == 0,
        "phase": phase,
        "violations": [v.to_dict() for v in violations],
    }


def format_telegram_message(run_id: str, phase: str, violations: list[dict]) -> str:
    phase_zh = "產出審核前" if phase == "pre_hitl" else "發佈前"
    lines = [
        "⛔ 無法繼續：平台規則未通過",
        f"run_id: {run_id}",
        f"階段: {phase_zh}",
        "",
    ]
    for v in violations:
        lines.append(f"• {v.get('message_zh', v.get('code', 'error'))}")
    lines.extend(["", "請修正 post.md 或稍後再觸發新 run。"])
    return "\n".join(lines)
