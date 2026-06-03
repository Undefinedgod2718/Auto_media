#!/usr/bin/env python3
"""Usage query for Telegram — stub only (not implemented)."""
from __future__ import annotations

USAGE_QUERY_IMPLEMENTED = False

STUB_MESSAGE_ZH = (
    "用量查詢功能開發中，稍後提供 IG / Threads / FB 24 小時剩餘額度。"
)


def handle_usage_query() -> str:
    if USAGE_QUERY_IMPLEMENTED:
        raise NotImplementedError("usage query not wired yet")
    return STUB_MESSAGE_ZH
