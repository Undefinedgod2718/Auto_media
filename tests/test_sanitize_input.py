#!/usr/bin/env python3
from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "lib"))

import sanitize_input as si  # noqa: E402


def test_run_id_valid_passes():
    assert si.sanitize_run_id("20260605-abc_DEF-1") == "20260605-abc_DEF-1"


def test_run_id_injection_replaced_by_fallback():
    for bad in ('"; rm -rf /; #', "../../etc/passwd", "a b", "x$(whoami)", ""):
        assert si.sanitize_run_id(bad, fallback="fb") == "fb"


def test_topic_strips_control_and_newlines():
    assert si.sanitize_topic("hi\nthere\r\n\x00bad\x07") == "hi there  bad"


def test_topic_shell_metachars_kept_as_data():
    # topic is data, not shell — metacharacters are preserved verbatim.
    s = '"; rm -rf /data; echo "'
    assert si.sanitize_topic(s) == s


def test_topic_clamped():
    assert len(si.sanitize_topic("x" * 5000)) == si.TOPIC_MAX


def test_publish_targets_whitelist_alias_order_dedupe():
    assert si.sanitize_publish_targets("fb, ig, threads, ig") == "instagram,threads,facebook"
    assert si.sanitize_publish_targets("evil, drop tables") == ""
    assert si.sanitize_publish_targets("THREADS") == "threads"


def test_callback_whitelist():
    assert si.sanitize_callback("approve") == "approve"
    assert si.sanitize_callback("REJECT") == "reject"
    assert si.sanitize_callback("approve; rm", fallback="revise") == "revise"


if __name__ == "__main__":
    import traceback

    fns = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    failed = 0
    for fn in fns:
        try:
            fn()
            print(f"ok   {fn.__name__}")
        except Exception:
            failed += 1
            print(f"FAIL {fn.__name__}")
            traceback.print_exc()
    sys.exit(1 if failed else 0)
