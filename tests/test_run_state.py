#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LIB = ROOT / "scripts" / "lib"
sys.path.insert(0, str(LIB))

import run_state as rs  # noqa: E402


def _run(run_dir: Path, run_id: str, *args: str, env_extra: dict | None = None):
    env = dict(os.environ)
    env["PYTHONPATH"] = str(LIB)
    if env_extra:
        env.update(env_extra)
    return subprocess.run(
        [sys.executable, str(LIB / "run_state.py"), "--run-dir", str(run_dir),
         "--run-id", run_id, *args],
        capture_output=True, text=True, env=env,
    )


def test_ensure_creates_state_with_init_seq():
    run = Path(tempfile.mkdtemp())
    st = rs.load_state(run, "r1")
    assert st["stage_seq"] == -1
    rs.save_state(run, st)
    assert rs.state_path(run).is_file()
    on_disk = json.loads(rs.state_path(run).read_text(encoding="utf-8"))
    assert on_disk["run_id"] == "r1"


def test_mark_stage_monotonic_and_jump():
    run = Path(tempfile.mkdtemp())
    rs.save_state(run, rs.mark_stage(run, "r1", "task_written"))
    rs.save_state(run, rs.mark_stage(run, "r1", "writers_done"))
    # jump forward (skip artists/hitl) is allowed
    st = rs.mark_stage(run, "r1", "pre_publish_ok")
    assert st["stage_seq"] == 7


def test_mark_stage_rejects_regress():
    run = Path(tempfile.mkdtemp())
    rs.save_state(run, rs.mark_stage(run, "r1", "pre_publish_ok"))
    try:
        rs.mark_stage(run, "r1", "writers_done")
    except ValueError:
        pass
    else:
        raise AssertionError("regress should raise")
    # explicit allow_regress overrides
    st = rs.mark_stage(run, "r1", "writers_done", allow_regress=True)
    assert st["stage_seq"] == 1


def test_require_stage_raises_below_min():
    run = Path(tempfile.mkdtemp())
    rs.save_state(run, rs.mark_stage(run, "r1", "hermes_done"))  # seq 4
    rs.require_stage(run, "r1", 4)  # equal ok
    try:
        rs.require_stage(run, "r1", 7)
    except ValueError:
        pass
    else:
        raise AssertionError("require 7 with seq 4 should raise")


def test_cli_require_non_strict_allows():
    run = Path(tempfile.mkdtemp())
    r = _run(run, "r1", "require", "--min-seq", "7")
    assert r.returncode == 0, r.stderr
    assert json.loads(r.stdout)["ok"] is True


def test_cli_require_strict_blocks():
    run = Path(tempfile.mkdtemp())
    r = _run(run, "r1", "require", "--min-seq", "7",
             env_extra={"AUTO_MEDIA_STRICT_STAGE": "1"})
    assert r.returncode == 3, r.stdout + r.stderr
    assert json.loads(r.stdout)["ok"] is False


def test_lock_and_wait():
    run = Path(tempfile.mkdtemp())
    rs.save_state(run, rs.mark_lock(run, "r1", "threads_writer", "threads/post.md", 2))
    rs.save_state(run, rs.set_wait(run, "r1", "feedback-v1", "data/hitl/resume_map/x.json"))
    st = rs.load_state(run, "r1")
    assert st["locks"]["threads_writer"]["revision"] == 2
    assert st["hitl"]["active_wait"] == "feedback-v1"


def test_publish_targets_default_all():
    run = Path(tempfile.mkdtemp())
    # no TASK.md -> default state targets empty (no task); with TASK lacking
    # publish_targets, parse_task returns all three.
    (run / "TASK.md").write_text("topic: t\n", encoding="utf-8")
    st = rs.load_state(run, "r1")
    assert set(st["publish_targets"]) == {"instagram", "threads", "facebook"}
