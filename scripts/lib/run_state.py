#!/usr/bin/env python3
"""Run state machine for idempotency and execution order checks."""
from __future__ import annotations

import argparse
import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from parse_task import publish_targets

STAGE_SEQ: dict[str, int] = {
    "task_written": 0,
    "writers_done": 1,
    "artists_done": 2,
    "validated_pre_hitl": 3,
    "hermes_done": 4,
    "hitl_v1_pass": 5,
    "hitl_v2_pass": 6,
    "pre_publish_ok": 7,
    "publish_done": 8,
}


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def state_path(run_dir: Path) -> Path:
    return run_dir / "state.json"


def _default_state(run_dir: Path, run_id: str) -> dict[str, Any]:
    task = run_dir / "TASK.md"
    targets = sorted(publish_targets(task)) if task.is_file() else []
    return {
        "run_id": run_id,
        "stage_seq": -1,
        "stage": "init",
        "publish_targets": targets,
        "locks": {},
        "hitl": {"active_wait": "", "resume_url_ref": ""},
        "n8n": {},
        "updated_at": _now(),
    }


def load_state(run_dir: Path, run_id: str) -> dict[str, Any]:
    p = state_path(run_dir)
    if not p.is_file():
        return _default_state(run_dir, run_id)
    data = json.loads(p.read_text(encoding="utf-8"))
    data.setdefault("run_id", run_id)
    data.setdefault("stage_seq", -1)
    data.setdefault("stage", "init")
    data.setdefault("publish_targets", [])
    data.setdefault("locks", {})
    data.setdefault("hitl", {"active_wait": "", "resume_url_ref": ""})
    data.setdefault("n8n", {})
    return data


def save_state(run_dir: Path, state: dict[str, Any]) -> Path:
    state["updated_at"] = _now()
    p = state_path(run_dir)
    p.write_text(json.dumps(state, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return p


def require_stage(run_dir: Path, run_id: str, min_seq: int) -> None:
    current = int(load_state(run_dir, run_id).get("stage_seq", -1))
    if current < min_seq:
        raise ValueError(f"stage_seq {current} < required {min_seq}")


def mark_stage(
    run_dir: Path,
    run_id: str,
    stage: str,
    seq: int | None = None,
    allow_regress: bool = False,
) -> dict[str, Any]:
    st = load_state(run_dir, run_id)
    new_seq = STAGE_SEQ.get(stage, seq if seq is not None else int(st.get("stage_seq", -1)))
    if new_seq is None:
        raise ValueError("unknown stage and no seq provided")
    cur = int(st.get("stage_seq", -1))
    if new_seq < cur and not allow_regress:
        raise ValueError(f"cannot regress stage_seq from {cur} to {new_seq}")
    st["stage_seq"] = int(new_seq)
    st["stage"] = stage
    return st


def mark_lock(
    run_dir: Path,
    run_id: str,
    lock_name: str,
    artifact: str = "",
    revision: int = 0,
    done: bool = True,
) -> dict[str, Any]:
    st = load_state(run_dir, run_id)
    locks = st.setdefault("locks", {})
    locks[lock_name] = {
        "done": bool(done),
        "artifact": artifact,
        "revision": int(revision),
        "updated_at": _now(),
    }
    return st


def set_wait(run_dir: Path, run_id: str, wait_stage: str, resume_ref: str) -> dict[str, Any]:
    st = load_state(run_dir, run_id)
    st.setdefault("hitl", {})
    st["hitl"]["active_wait"] = wait_stage
    st["hitl"]["resume_url_ref"] = resume_ref
    return st


def cli() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--run-dir", required=True)
    ap.add_argument("--run-id", required=True)
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("status")
    sub.add_parser("ensure")
    p_req = sub.add_parser("require")
    p_req.add_argument("--min-seq", type=int, required=True)
    p_mark = sub.add_parser("mark")
    p_mark.add_argument("--stage", required=True)
    p_mark.add_argument("--seq", type=int)
    p_mark.add_argument("--allow-regress", action="store_true")
    p_lock = sub.add_parser("lock")
    p_lock.add_argument("--name", required=True)
    p_lock.add_argument("--artifact", default="")
    p_lock.add_argument("--revision", type=int, default=0)
    p_lock.add_argument("--done", action="store_true", default=True)
    p_wait = sub.add_parser("wait")
    p_wait.add_argument("--stage", required=True)
    p_wait.add_argument("--resume-ref", default="")

    args = ap.parse_args()
    run_dir = Path(args.run_dir)
    run_dir.mkdir(parents=True, exist_ok=True)

    if args.cmd == "status":
        print(json.dumps(load_state(run_dir, args.run_id), ensure_ascii=False))
        return 0
    if args.cmd == "ensure":
        p = save_state(run_dir, load_state(run_dir, args.run_id))
        print(json.dumps({"ok": True, "path": str(p)}, ensure_ascii=False))
        return 0
    if args.cmd == "require":
        # Transition safety (never break userspace): enforce ordering only when
        # AUTO_MEDIA_STRICT_STAGE=1. Otherwise warn and allow, so in-flight runs,
        # manual retries, and pre-state.json runs are not bricked. Flip strict on
        # once the full stage chain is proven end-to-end.
        import os
        strict = os.environ.get("AUTO_MEDIA_STRICT_STAGE", "0") == "1"
        try:
            require_stage(run_dir, args.run_id, args.min_seq)
        except ValueError as e:
            if not strict:
                print(json.dumps(
                    {"ok": True, "warn": f"stage below {args.min_seq} (non-strict): {e}"},
                    ensure_ascii=False,
                ))
                return 0
            print(json.dumps({"ok": False, "error": str(e)}, ensure_ascii=False))
            return 3
        print(json.dumps({"ok": True}, ensure_ascii=False))
        return 0
    if args.cmd == "mark":
        st = mark_stage(run_dir, args.run_id, args.stage, args.seq, args.allow_regress)
        save_state(run_dir, st)
        print(json.dumps({"ok": True, "stage": st["stage"], "stage_seq": st["stage_seq"]}, ensure_ascii=False))
        return 0
    if args.cmd == "lock":
        st = mark_lock(run_dir, args.run_id, args.name, args.artifact, args.revision, args.done)
        save_state(run_dir, st)
        print(json.dumps({"ok": True, "lock": args.name}, ensure_ascii=False))
        return 0
    if args.cmd == "wait":
        st = set_wait(run_dir, args.run_id, args.stage, args.resume_ref)
        save_state(run_dir, st)
        print(json.dumps({"ok": True, "active_wait": args.stage}, ensure_ascii=False))
        return 0
    return 1


if __name__ == "__main__":
    raise SystemExit(cli())
