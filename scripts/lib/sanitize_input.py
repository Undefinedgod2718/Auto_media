#!/usr/bin/env python3
"""Boundary input sanitization (Layer 2 — defense in depth, NOT the main fix).

The primary shell-injection defense is structural: user input never reaches a
shell command string (TASK.md written via argv, run_id gated, other values
base64-wrapped). These helpers are a belt-and-suspenders boundary that
normalizes/clamps untrusted input at the Gateway edge.
"""
from __future__ import annotations

import re

RUN_ID_RE = re.compile(r"^[A-Za-z0-9_-]+$")
_RUN_ID_STRIP = re.compile(r"[^A-Za-z0-9_-]")
ALL_TARGETS = ("instagram", "threads", "facebook")
_TARGET_ALIASES = {
    "instagram": "instagram", "ig": "instagram", "insta": "instagram",
    "threads": "threads", "th": "threads",
    "facebook": "facebook", "fb": "facebook",
}
CALLBACKS = ("approve", "revise", "reject")

# Telegram message hard cap is 4096; TASK.md topic line stays well under it.
TOPIC_MAX = 2000


def sanitize_run_id(value: str, *, fallback: str = "") -> str:
    """Return value if it is a bare [A-Za-z0-9_-] token, else fallback.

    Does not silently strip — an invalid run_id is replaced wholesale so a
    crafted value can never become a different-but-valid path component.
    """
    value = (value or "").strip()
    if RUN_ID_RE.match(value):
        return value
    return fallback


def sanitize_topic(value: str) -> str:
    """Strip control chars (incl. NUL), collapse newlines, clamp length.

    topic is written to TASK.md as data, not passed to a shell; this only
    removes characters that would corrupt the file or downstream parsing.
    """
    value = value or ""
    # Drop C0/C1 control chars except tab/newline; normalize CR/LF to space.
    value = value.replace("\r", " ").replace("\n", " ")
    value = "".join(ch for ch in value if ch == "\t" or ord(ch) >= 0x20)
    value = value.strip()
    return value[:TOPIC_MAX]


def sanitize_publish_targets(value: str) -> str:
    """Whitelist + dedupe + canonical-order comma list. Empty if none valid."""
    seen = set()
    for part in (value or "").split(","):
        key = part.strip().lower()
        canon = _TARGET_ALIASES.get(key)
        if canon:
            seen.add(canon)
    return ",".join(t for t in ALL_TARGETS if t in seen)


def sanitize_callback(value: str, *, fallback: str = "") -> str:
    """Whitelist HITL decision to approve|revise|reject."""
    v = (value or "").strip().lower()
    return v if v in CALLBACKS else fallback
