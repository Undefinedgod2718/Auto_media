#!/usr/bin/env python3
"""Regression tests for the shell-injection lockdown (PR1-4)."""
from __future__ import annotations

import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "lib"))

import task_md  # noqa: E402

MALICIOUS = '"; rm -rf /data; touch /tmp/PWNED; echo "'


def test_verify_workflow_shell_safe_passes_on_committed_workflows():
    r = subprocess.run(
        ["bash", str(ROOT / "scripts" / "verify_workflow_shell_safe.sh")],
        capture_output=True, text=True,
    )
    assert r.returncode == 0, r.stderr


def test_malicious_topic_is_inert_data_in_task_md():
    with tempfile.TemporaryDirectory() as tmp:
        env_data = Path(tmp)
        os.environ["DATA_ROOT"] = str(env_data)
        try:
            path = task_md.write_task_md("rgr-1", topic=MALICIOUS, publish_targets="threads")
            content = path.read_text(encoding="utf-8")
        finally:
            os.environ.pop("DATA_ROOT", None)
        assert f"topic: {MALICIOUS}" in content
        assert not Path("/tmp/PWNED").exists()


def test_bad_run_id_rejected():
    os.environ["DATA_ROOT"] = tempfile.mkdtemp()
    try:
        for bad in ("../../etc", "a;b", 'x"y', "a b"):
            try:
                task_md.write_task_md(bad, topic="t")
            except ValueError:
                continue
            raise AssertionError(f"bad run_id accepted: {bad!r}")
    finally:
        os.environ.pop("DATA_ROOT", None)


if __name__ == "__main__":
    import traceback

    failed = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try:
                fn()
                print(f"ok   {name}")
            except Exception:
                failed += 1
                print(f"FAIL {name}")
                traceback.print_exc()
    sys.exit(1 if failed else 0)
