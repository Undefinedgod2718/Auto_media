#!/usr/bin/env python3
"""Connectivity tests for settings UI without exposing secrets."""
from __future__ import annotations

import json
import urllib.parse
import urllib.request
from typing import Any


def _http_get_json(url: str, timeout: int = 12) -> tuple[bool, dict[str, Any], str]:
    req = urllib.request.Request(url, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
            return True, json.loads(raw) if raw else {}, f"http={resp.status}"
    except Exception as e:  # noqa: BLE001
        return False, {}, str(e)


def test_telegram(values: dict[str, str]) -> dict[str, Any]:
    token = values.get("TELEGRAM_BOT_TOKEN", "")
    chat_id = values.get("TELEGRAM_CHAT_ID", "")
    if not token:
        return {"name": "telegram", "ok": False, "message": "TELEGRAM_BOT_TOKEN missing"}
    ok, data, msg = _http_get_json(f"https://api.telegram.org/bot{token}/getMe")
    if not ok or not data.get("ok"):
        return {"name": "telegram", "ok": False, "message": f"getMe failed: {msg}"}
    if chat_id and not chat_id.lstrip("-").isdigit():
        return {"name": "telegram", "ok": False, "message": "TELEGRAM_CHAT_ID format invalid"}
    bot_name = (data.get("result") or {}).get("username", "unknown")
    return {"name": "telegram", "ok": True, "message": f"bot={bot_name}"}


def test_n8n(values: dict[str, str]) -> dict[str, Any]:
    base = values.get("N8N_API_URL", "").rstrip("/")
    if not base:
        return {"name": "n8n_api", "ok": False, "message": "N8N_API_URL missing"}
    ok, _, msg = _http_get_json(f"{base}/healthz")
    if not ok:
        return {"name": "n8n_api", "ok": False, "message": f"healthz failed: {msg}"}
    api_key = values.get("N8N_API_KEY", "")
    if not api_key:
        return {"name": "n8n_api", "ok": True, "message": "healthz ok (no API key check)"}
    req = urllib.request.Request(
        f"{base}/api/v1/workflows",
        headers={"X-N8N-API-KEY": api_key},
        method="GET",
    )
    try:
        with urllib.request.urlopen(req, timeout=12) as resp:
            return {"name": "n8n_api", "ok": True, "message": f"workflows ok http={resp.status}"}
    except Exception as e:  # noqa: BLE001
        return {"name": "n8n_api", "ok": False, "message": f"workflows failed: {e}"}


def test_meta(values: dict[str, str]) -> dict[str, Any]:
    token = values.get("META_PAGE_ACCESS_TOKEN", "")
    page_id = values.get("META_PAGE_ID", "")
    version = values.get("META_GRAPH_API_VERSION", "v21.0")
    if not token or not page_id:
        return {"name": "meta_fb_ig", "ok": False, "message": "META_PAGE_ACCESS_TOKEN or META_PAGE_ID missing"}
    url = (
        f"https://graph.facebook.com/{version}/{page_id}?fields=id,name"
        f"&access_token={urllib.parse.quote(token, safe='')}"
    )
    ok, data, msg = _http_get_json(url)
    if not ok or data.get("error"):
        err = (data.get("error") or {}).get("message", msg)
        return {"name": "meta_fb_ig", "ok": False, "message": f"page check failed: {err}"}
    ig_user = values.get("IG_USER_ID", "")
    if ig_user:
        ig_url = (
            f"https://graph.facebook.com/{version}/{ig_user}?fields=id,username"
            f"&access_token={urllib.parse.quote(token, safe='')}"
        )
        ok2, data2, msg2 = _http_get_json(ig_url)
        if not ok2 or data2.get("error"):
            err2 = (data2.get("error") or {}).get("message", msg2)
            return {"name": "meta_fb_ig", "ok": False, "message": f"ig check failed: {err2}"}
    return {"name": "meta_fb_ig", "ok": True, "message": "Meta page/IG check ok"}


def test_threads(values: dict[str, str]) -> dict[str, Any]:
    token = values.get("THREADS_ACCESS_TOKEN", "")
    user_id = values.get("THREADS_USER_ID", "")
    if not token or not user_id:
        return {"name": "threads", "ok": False, "message": "THREADS_ACCESS_TOKEN or THREADS_USER_ID missing"}
    url = (
        f"https://graph.threads.net/v1.0/{user_id}?fields=id,username"
        f"&access_token={urllib.parse.quote(token, safe='')}"
    )
    ok, data, msg = _http_get_json(url)
    if not ok or data.get("error"):
        err = (data.get("error") or {}).get("message", msg)
        return {"name": "threads", "ok": False, "message": f"threads check failed: {err}"}
    return {"name": "threads", "ok": True, "message": "Threads check ok"}


def run_group(group: str, values: dict[str, str]) -> dict[str, Any]:
    checks = []
    if group in ("all", "telegram"):
        checks.append(test_telegram(values))
    if group in ("all", "n8n_api"):
        checks.append(test_n8n(values))
    if group in ("all", "meta_fb_ig"):
        checks.append(test_meta(values))
    if group in ("all", "threads"):
        checks.append(test_threads(values))
    ok = all(c.get("ok") for c in checks) if checks else False
    return {"ok": ok, "checks": checks}

