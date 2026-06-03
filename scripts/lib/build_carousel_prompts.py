#!/usr/bin/env python3
"""Build per-page image prompts for carousel generation."""
from __future__ import annotations

import argparse
import importlib.util
import json
import sys
from pathlib import Path

_LIB = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("carousel_plan", _LIB / "carousel_plan.py")
cp = importlib.util.module_from_spec(_spec)
assert _spec.loader
_spec.loader.exec_module(cp)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--skill-dir", required=True)
    ap.add_argument("--topic", required=True)
    ap.add_argument("--audience", default="general")
    ap.add_argument("--total", type=int, default=8)
    ap.add_argument("--post-md", default="")
    args = ap.parse_args()
    skill = Path(args.skill_dir)
    total = max(2, min(20, args.total))
    plan = cp.page_plan(total)

    from_post = []
    if args.post_md:
        from_post = cp.extract_prompts_from_post_md(Path(args.post_md))

    prompts = []
    for i in range(total):
        if i < len(from_post) and len(from_post[i]) > 200:
            prompts.append(from_post[i])
        else:
            prompts.append(
                cp.build_page_prompt(
                    skill,
                    topic=args.topic,
                    audience=args.audience,
                    page_num=i + 1,
                    total=total,
                    page_type=plan[i],
                )
            )

    print(
        json.dumps(
            {"plan": plan, "prompts": prompts, "total": total},
            ensure_ascii=False,
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
