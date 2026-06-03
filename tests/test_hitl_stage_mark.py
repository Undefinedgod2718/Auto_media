#!/usr/bin/env python3
from __future__ import annotations

import json
import tempfile
from pathlib import Path

import scripts.hermes_telegram_gateway as gw


def _state(run_dir: Path, run_id: str) -> dict:
    p = run_dir / run_id / "state.json"
    return json.loads(p.read_text(encoding="utf-8"))


def test_mark_v1_approve_sets_stage5(monkeypatch):
    root = Path(tempfile.mkdtemp())
    monkeypatch.setattr(gw, "DATA_ROOT", root)
    run_id = "test-run-v1"
    (root / "runs" / run_id).mkdir(parents=True)

    gw.mark_hitl_approval_if_needed({"callback_query": {"data": f"am:v1:approve:{run_id}"}})
    st = _state(root / "runs", run_id)
    assert st["stage"] == "hitl_v1_pass"
    assert st["stage_seq"] == 5


def test_mark_v2_approve_sets_stage6(monkeypatch):
    root = Path(tempfile.mkdtemp())
    monkeypatch.setattr(gw, "DATA_ROOT", root)
    run_id = "test-run-v2"
    (root / "runs" / run_id).mkdir(parents=True)

    gw.mark_hitl_approval_if_needed({"callback_query": {"data": f"am:v2:approve:{run_id}"}})
    st = _state(root / "runs", run_id)
    assert st["stage"] == "hitl_v2_pass"
    assert st["stage_seq"] == 6


def test_reject_or_revise_do_not_mark(monkeypatch):
    root = Path(tempfile.mkdtemp())
    monkeypatch.setattr(gw, "DATA_ROOT", root)
    run_id = "test-run-no-mark"
    (root / "runs" / run_id).mkdir(parents=True)

    gw.mark_hitl_approval_if_needed({"callback_query": {"data": f"am:v1:reject:{run_id}"}})
    gw.mark_hitl_approval_if_needed({"callback_query": {"data": f"am:v1:revise:{run_id}"}})
    st_path = root / "runs" / run_id / "state.json"
    assert not st_path.exists()


def test_invalid_callback_data_no_throw(monkeypatch):
    root = Path(tempfile.mkdtemp())
    monkeypatch.setattr(gw, "DATA_ROOT", root)
    gw.mark_hitl_approval_if_needed({"callback_query": {"data": "bad-format"}})
