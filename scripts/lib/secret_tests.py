#!/usr/bin/env python3
"""Connectivity tests for settings UI without exposing secrets."""
from __future__ import annotations

import json
import urllib.error
import urllib.parse
import urllib.request
from typing import Any


def _http_get_json(url: str, timeout: int = 12) -> tuple[bool, dict[str, Any], str]:
    req = urllib.request.Request(url, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
            data = json.loads(raw) if raw else {}
            if isinstance(data, dict) and data.get("error"):
                err = data["error"]
                msg = err.get("message", str(err)) if isinstance(err, dict) else str(err)
                return False, data, msg
            return True, data, f"http={resp.status}"
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", errors="replace")
        try:
            data = json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            data = {}
        if isinstance(data, dict) and data.get("error"):
            err = data["error"]
            msg = err.get("message", str(err)) if isinstance(err, dict) else str(err)
            return False, data, msg
        return False, data, f"http={e.code}: {raw[:200] or e.reason}"
    except Exception as e:  # noqa: BLE001
        return False, {}, str(e)


def _token_expired_message(msg: str) -> bool:
    m = msg.lower()
    return "session has expired" in m or "error validating access token" in m or "code 190" in m


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
    except urllib.error.HTTPError as e:
        return {"name": "n8n_api", "ok": False, "message": f"workflows failed: http={e.code}"}
    except Exception as e:  # noqa: BLE001
        return {"name": "n8n_api", "ok": False, "message": f"workflows failed: {e}"}


def test_meta(values: dict[str, str]) -> dict[str, Any]:
    token = values.get("META_PAGE_ACCESS_TOKEN", "")
    page_id = values.get("META_PAGE_ID", "")
    version = values.get("META_GRAPH_API_VERSION", "v21.0") or "v21.0"
    if not token or not page_id:
        return {"name": "meta_fb_ig", "ok": False, "message": "META_PAGE_ACCESS_TOKEN or META_PAGE_ID missing"}
    url = (
        f"https://graph.facebook.com/{version}/{page_id}?fields=id,name"
        f"&access_token={urllib.parse.quote(token, safe='')}"
    )
    ok, data, msg = _http_get_json(url)
    if not ok:
        hint = " (token expired — refresh in Graph API Explorer)" if _token_expired_message(msg) else ""
        return {"name": "meta_fb_ig", "ok": False, "message": f"page check failed: {msg}{hint}"}
    ig_user = values.get("IG_USER_ID", "")
    if ig_user:
        ig_url = (
            f"https://graph.facebook.com/{version}/{ig_user}?fields=id,username"
            f"&access_token={urllib.parse.quote(token, safe='')}"
        )
        ok2, _, msg2 = _http_get_json(ig_url)
        if not ok2:
            hint = " (token expired — refresh in Graph API Explorer)" if _token_expired_message(msg2) else ""
            return {"name": "meta_fb_ig", "ok": False, "message": f"ig check failed: {msg2}{hint}"}
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
    ok, _, msg = _http_get_json(url)
    if not ok:
        hint = " (token expired — refresh in Graph API Explorer)" if _token_expired_message(msg) else ""
        return {"name": "threads", "ok": False, "message": f"threads check failed: {msg}{hint}"}
    return {"name": "threads", "ok": True, "message": "Threads check ok"}


def merge_values(base: dict[str, str], overrides: dict[str, str] | None) -> dict[str, str]:
    merged = dict(base)
    if not overrides:
        return merged
    for key, val in overrides.items():
        if isinstance(val, str) and val.strip():
            merged[key] = val.strip()
    return merged


def run_group(group: str, values: dict[str, str], overrides: dict[str, str] | None = None) -> dict[str, Any]:
    effective = merge_values(values, overrides)
    from_form = bool(overrides)
    checks: list[dict[str, Any]] = []
    if group in ("all", "telegram"):
        checks.append(test_telegram(effective))
    if group in ("all", "n8n_api"):
        checks.append(test_n8n(effective))
    if group in ("all", "meta_fb_ig", "meta"):
        checks.append(test_meta(effective))
    if group in ("all", "threads"):
        checks.append(test_threads(effective))
    ok = all(c.get("ok") for c in checks) if checks else False
    out: dict[str, Any] = {"ok": ok, "checks": checks, "group": group}
    if from_form:
        out["note"] = "Tested form values (not yet saved). Click Save updates, then: docker compose up -d n8n"
    else:
        out["note"] = "Tested values from .env on disk. After Save, run: docker compose up -d n8n"
    return out
