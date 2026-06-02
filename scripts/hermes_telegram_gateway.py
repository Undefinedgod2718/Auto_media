#!/usr/bin/env python3
"""B-prime Telegram Gateway: pure I/O proxy (Model A). Async via background worker thread."""
from __future__ import annotations

import json
import logging
import os
import re
import sqlite3
import subprocess
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from queue import Empty, Queue
from typing import Any

REPO_ROOT = Path(os.environ.get("AUTO_MEDIA_ROOT", Path(__file__).resolve().parents[1]))
DATA_ROOT = Path(os.environ.get("DATA_ROOT", REPO_ROOT / "data"))
GATEWAY_DB = Path(os.environ.get("GATEWAY_DB", DATA_ROOT / "hitl" / "gateway.db"))
GATEWAY_LOG = Path(os.environ.get("GATEWAY_LOG", DATA_ROOT / "logs" / "gateway.jsonl"))
GATEWAY_SECRET = os.environ.get("GATEWAY_INTERNAL_SECRET", "")
TELEGRAM_WEBHOOK_SECRET = os.environ.get("TELEGRAM_WEBHOOK_SECRET", "")
TELEGRAM_BOT_TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "")
TELEGRAM_CHAT_ID = os.environ.get("TELEGRAM_CHAT_ID", "")
N8N_API_URL = os.environ.get("N8N_API_URL", "http://localhost:5678").rstrip("/")
N8N_API_KEY = os.environ.get("N8N_API_KEY", "")
N8N_WEBHOOK_RUN = os.environ.get("N8N_WEBHOOK_RUN", "/webhook/auto-media-run")
GATEWAY_PORT = int(os.environ.get("GATEWAY_PORT", "8787"))
HITL_WAIT_POLL_SEC = float(os.environ.get("HITL_WAIT_POLL_SEC", "30"))
POLL_INTERVAL = float(os.environ.get("GATEWAY_POLL_INTERVAL", "0.5"))

JOB_QUEUE: Queue[dict[str, Any]] = Queue()
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
LOG = logging.getLogger("gateway")


def log_gateway(event: str, direction: str, **fields: Any) -> None:
    GATEWAY_LOG.parent.mkdir(parents=True, exist_ok=True)
    row = {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "log": "gateway",
        "direction": direction,
        "event": event,
        "update_id": fields.get("update_id", 0),
        "run_id": fields.get("run_id", ""),
        "execution_id": fields.get("execution_id", ""),
        "job_type": fields.get("job_type", ""),
        "latency_ms": fields.get("latency_ms", 0),
        "ok": fields.get("ok", True),
        "error": fields.get("error", ""),
    }
    with GATEWAY_LOG.open("a", encoding="utf-8") as f:
        f.write(json.dumps(row, ensure_ascii=False) + "\n")


PLATFORM_KEYS = ("instagram", "threads", "facebook")
PLATFORM_TOGGLE = {"ig": "instagram", "threads": "threads", "fb": "facebook"}
PLATFORM_LABELS = {
    "instagram": "Instagram",
    "threads": "Threads",
    "facebook": "Facebook",
}


def init_db() -> None:
    GATEWAY_DB.parent.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(GATEWAY_DB) as conn:
        conn.execute(
            "CREATE TABLE IF NOT EXISTS processed_updates (update_id INTEGER PRIMARY KEY)"
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS pending_platform_select (
                run_id TEXT PRIMARY KEY,
                topic TEXT NOT NULL,
                chat_id TEXT NOT NULL,
                selected TEXT NOT NULL DEFAULT '',
                message_id INTEGER,
                created_at REAL NOT NULL
            )
            """
        )
        conn.commit()


def _platform_tips_text() -> str:
    sys_path = str(REPO_ROOT / "scripts" / "lib")
    if sys_path not in __import__("sys").path:
        __import__("sys").path.insert(0, sys_path)
    try:
        from platform_tips import format_platform_tips

        return format_platform_tips()
    except (FileNotFoundError, json.JSONDecodeError, KeyError) as e:
        LOG.warning("platform tips unavailable: %s", e)
        return (
            "請勾選發佈平台（IG / Threads / FB），再按「▶ 開始產出」。\n"
            "僅 Threads 時不產輪播圖；含 IG 時才產 carousel。"
        )


def _parse_selected(raw: str) -> set[str]:
    if not raw:
        return set()
    return {p.strip().lower() for p in raw.split(",") if p.strip()}


def _save_pending(
    run_id: str,
    topic: str,
    chat_id: str,
    selected: set[str],
    message_id: int | None = None,
) -> None:
    sel = ",".join(sorted(selected))
    with sqlite3.connect(GATEWAY_DB) as conn:
        conn.execute(
            """
            INSERT INTO pending_platform_select (run_id, topic, chat_id, selected, message_id, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(run_id) DO UPDATE SET
                selected=excluded.selected,
                message_id=COALESCE(excluded.message_id, pending_platform_select.message_id)
            """,
            (run_id, topic, chat_id, sel, message_id, time.time()),
        )
        conn.commit()


def _load_pending(run_id: str) -> dict[str, Any] | None:
    with sqlite3.connect(GATEWAY_DB) as conn:
        row = conn.execute(
            "SELECT run_id, topic, chat_id, selected, message_id FROM pending_platform_select WHERE run_id=?",
            (run_id,),
        ).fetchone()
    if not row:
        return None
    return {
        "run_id": row[0],
        "topic": row[1],
        "chat_id": row[2],
        "selected": _parse_selected(row[3]),
        "message_id": row[4],
    }


def _clear_pending(run_id: str) -> None:
    with sqlite3.connect(GATEWAY_DB) as conn:
        conn.execute("DELETE FROM pending_platform_select WHERE run_id=?", (run_id,))
        conn.commit()


def _platform_keyboard(run_id: str, selected: set[str]) -> dict:
    def mark(key: str, label: str) -> str:
        on = key in selected
        return ("✓ " if on else "") + label

    return {
        "inline_keyboard": [
            [
                {"text": mark("instagram", "IG"), "callback_data": f"am:plat:toggle:ig:{run_id}"},
                {"text": mark("threads", "Threads"), "callback_data": f"am:plat:toggle:threads:{run_id}"},
                {"text": mark("facebook", "FB"), "callback_data": f"am:plat:toggle:fb:{run_id}"},
            ],
            [{"text": "▶ 開始產出", "callback_data": f"am:plat:confirm:{run_id}"}],
        ]
    }


def send_platform_select(chat_id: str, run_id: str, topic: str, selected: set[str] | None = None) -> None:
    sel = selected or set()
    text = f"主題：{topic[:200]}\n\n{_platform_tips_text()}"
    resp = telegram_api(
        "sendMessage",
        {
            "chat_id": chat_id,
            "text": text,
            "reply_markup": _platform_keyboard(run_id, sel),
        },
    )
    mid = (resp.get("result") or {}).get("message_id")
    _save_pending(run_id, topic, chat_id, sel, int(mid) if mid else None)


def _edit_platform_select(chat_id: str, message_id: int, run_id: str, topic: str, selected: set[str]) -> None:
    text = f"主題：{topic[:200]}\n\n{_platform_tips_text()}"
    telegram_api(
        "editMessageText",
        {
            "chat_id": chat_id,
            "message_id": message_id,
            "text": text,
            "reply_markup": _platform_keyboard(run_id, selected),
        },
    )


def handle_platform_callback(update: dict) -> bool:
    """Return True if handled (do not forward to n8n)."""
    cb = update.get("callback_query") or {}
    data = str(cb.get("data", ""))
    if not data.startswith("am:plat:"):
        return False

    parts = data.split(":")
    if len(parts) < 4:
        return True

    cq_id = cb.get("id", "")
    msg = cb.get("message") or {}
    chat_id = str((msg.get("chat") or {}).get("id", TELEGRAM_CHAT_ID))
    message_id = int(msg.get("message_id", 0))

    if parts[2] == "confirm":
        run_id = parts[3]
        pending = _load_pending(run_id)
        if not pending:
            telegram_api("answerCallbackQuery", {"callback_query_id": cq_id, "text": "已過期，請重新送主題"})
            return True
        selected = pending["selected"]
        if not selected:
            telegram_api("answerCallbackQuery", {"callback_query_id": cq_id, "text": "請至少選一個平台"})
            return True
        targets = ",".join(sorted(selected))
        run_script(
            "write_task.sh",
            "--run-id",
            run_id,
            "--topic",
            pending["topic"],
            "--publish-targets",
            targets,
            "--publish-mode-threads",
            "carousel",
        )
        _clear_pending(run_id)
        trigger_n8n_run(run_id, pending["topic"], chat_id, targets)
        telegram_api(
            "answerCallbackQuery",
            {"callback_query_id": cq_id, "text": f"已選：{targets}"},
        )
        telegram_api(
            "sendMessage",
            {
                "chat_id": chat_id,
                "text": f"已收到，生產中… run_id={run_id}\n發佈：{targets}",
            },
        )
        return True

    if parts[2] != "toggle" or len(parts) < 5:
        return True

    plat_key = parts[3]
    run_id = parts[4]
    platform = PLATFORM_TOGGLE.get(plat_key, plat_key)
    pending = _load_pending(run_id)
    if not pending:
        telegram_api("answerCallbackQuery", {"callback_query_id": cq_id, "text": "已過期"})
        return True
    selected = set(pending["selected"])
    if platform in selected:
        selected.discard(platform)
    else:
        selected.add(platform)
    _save_pending(run_id, pending["topic"], chat_id, selected, message_id)
    if message_id:
        _edit_platform_select(chat_id, message_id, run_id, pending["topic"], selected)
    telegram_api("answerCallbackQuery", {"callback_query_id": cq_id, "text": PLATFORM_LABELS.get(platform, platform)})
    return True


def mark_update(update_id: int) -> bool:
    """Return True if new update, False if duplicate."""
    try:
        with sqlite3.connect(GATEWAY_DB) as conn:
            conn.execute("INSERT INTO processed_updates (update_id) VALUES (?)", (update_id,))
            conn.commit()
        return True
    except sqlite3.IntegrityError:
        return False


def http_json(method: str, url: str, body: dict | None = None, headers: dict | None = None) -> tuple[int, Any]:
    hdrs = {"Content-Type": "application/json", **(headers or {})}
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, headers=hdrs, method=method)
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            raw = resp.read().decode()
            return resp.status, json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        raw = e.read().decode(errors="replace")
        try:
            return e.code, json.loads(raw)
        except json.JSONDecodeError:
            return e.code, {"raw": raw}


def telegram_api(method: str, payload: dict) -> dict:
    url = f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/{method}"
    _, data = http_json("POST", url, payload)
    return data if isinstance(data, dict) else {}


def n8n_get_execution(execution_id: str) -> dict:
    code, data = http_json(
        "GET",
        f"{N8N_API_URL}/api/v1/executions/{execution_id}",
        headers={"X-N8N-API-KEY": N8N_API_KEY},
    )
    if code != 200 or not isinstance(data, dict):
        return {"status": "unknown", "http_code": code}
    return data.get("data", data)


def poll_execution_ready(execution_id: str) -> str:
    """Return 'waiting', 'running', or terminal status string."""
    deadline = time.time() + HITL_WAIT_POLL_SEC
    while time.time() < deadline:
        ex = n8n_get_execution(execution_id)
        status = str(ex.get("status", "")).lower()
        if status == "waiting":
            return "waiting"
        if status in ("success", "error", "crashed", "canceled", "cancelled", "failed"):
            return status
        time.sleep(POLL_INTERVAL)
    return "timeout"


def run_script(script: str, *args: str) -> tuple[int, str]:
    cmd = ["/bin/bash", str(REPO_ROOT / "scripts" / script), *args]
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
    return proc.returncode, (proc.stdout or "") + (proc.stderr or "")


def prereview_run(run_id: str) -> bool:
    code, _ = run_script("hermes_agent_prereview.sh", "--run-id", run_id)
    if code == 0:
        return True
    code, _ = run_script("hermes_prereview.sh", "--run-id", run_id)
    return code == 0


def _hermes_block(assessment: dict) -> str:
    risk = assessment.get("risk_level", "low")
    hint = assessment.get("verdict_hint", "pass")
    reasons = assessment.get("reasons") or []
    suggestions = assessment.get("suggestions") or []
    if not isinstance(reasons, list):
        reasons = [str(reasons)]
    if not isinstance(suggestions, list):
        suggestions = [str(suggestions)]
    return (
        f"\n\n[Hermes初審] risk={risk} | hint={hint}\n"
        f"理由: {'；'.join(str(r) for r in reasons)}\n"
        f"建議: {'；'.join(str(s) for s in suggestions)}"
    )


def build_caption(run_id: str, stage: str = "v1") -> str:
    post = DATA_ROOT / "runs" / run_id / "post.md"
    assess_path = DATA_ROOT / "runs" / run_id / "hermes_assessment.json"
    body = post.read_text(encoding="utf-8", errors="replace").strip() if post.is_file() else ""
    hermes = ""
    if assess_path.is_file():
        try:
            hermes = _hermes_block(json.loads(assess_path.read_text(encoding="utf-8")))
        except json.JSONDecodeError:
            pass
    prefix = "（修正後）\n" if stage == "v2" else ""
    max_len = 1024
    if not hermes:
        return (prefix + body)[:max_len]
    budget = max_len - len(prefix) - len(hermes)
    if budget < 1:
        return (prefix + hermes)[:max_len]
    trimmed = body[:budget].rstrip()
    if body and len(body) > budget:
        trimmed = trimmed.rstrip() + "…"
    return (prefix + trimmed + hermes)[:max_len]


def _preview_keyboard(stage: str, run_id: str) -> dict:
    return {
        "inline_keyboard": [[
            {"text": "✅", "callback_data": f"am:{stage}:approve:{run_id}"},
            {"text": "🛠", "callback_data": f"am:{stage}:revise:{run_id}"},
            {"text": "❌", "callback_data": f"am:{stage}:reject:{run_id}"},
        ]]
    }


def _collect_carousel_images(run_id: str, limit: int = 10) -> list[Path]:
    carousel = DATA_ROOT / "runs" / run_id / "carousel"
    if not carousel.is_dir():
        return []
    slides = sorted(carousel.glob("*.png")) + sorted(carousel.glob("*.jpg"))
    return slides[:limit]


def _split_part1_posts(post_md: Path) -> list[str]:
    import re

    text = post_md.read_text(encoding="utf-8", errors="replace") if post_md.is_file() else ""
    if re.search(r"##\s*Part\s*2", text, re.I):
        text = re.split(r"\n##\s*Part\s*2", text, maxsplit=1, flags=re.I)[0]
    posts = re.findall(
        r"(###\s*貼文\s*\d+[^\n]*\n[\s\S]*?)(?=\n###\s*貼文\s*\d+|$)",
        text,
        flags=re.I,
    )
    if posts:
        return [p.strip() for p in posts if p.strip()]
    posts = re.findall(
        r"(##\s*第\s*\d+\s*則[^\n]*\n[\s\S]*?)(?=\n##\s*第\s*\d+\s*則|$)",
        text,
    )
    return [p.strip() for p in posts if p.strip()]


def _short_album_caption(run_id: str, stage: str, slide_count: int) -> str:
    prefix = "（修正後）\n" if stage == "v2" else ""
    assess_path = DATA_ROOT / "runs" / run_id / "hermes_assessment.json"
    hermes = ""
    if assess_path.is_file():
        try:
            hermes = _hermes_block(json.loads(assess_path.read_text(encoding="utf-8")))
        except json.JSONDecodeError:
            pass
    base = f"{prefix}run_id={run_id}\n共 {slide_count} 張輪播圖，全文見後續訊息。"
    cap = (base + hermes)[:1024]
    return cap


def _multipart_send(method: str, fields: dict, file_field: str | None = None, file_path: Path | None = None) -> None:
    boundary = "----automediagateway"
    body: list[bytes] = []
    for name, val in fields.items():
        if val is None:
            continue
        part = (
            f"--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n"
            f"{val}\r\n"
        ).encode()
        body.append(part)
    if file_field and file_path and file_path.is_file():
        mime = "image/jpeg" if file_path.suffix.lower() in (".jpg", ".jpeg") else "image/png"
        head = (
            f"--{boundary}\r\nContent-Disposition: form-data; name=\"{file_field}\"; "
            f"filename=\"{file_path.name}\"\r\nContent-Type: {mime}\r\n\r\n"
        ).encode()
        body.append(head)
        with file_path.open("rb") as f:
            body.append(f.read())
        body.append(f"\r\n--{boundary}--\r\n".encode())
    else:
        body.append(f"--{boundary}--\r\n".encode())
    payload = b"".join(body)
    req = urllib.request.Request(
        f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/{method}",
        data=payload,
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
        method="POST",
    )
    urllib.request.urlopen(req, timeout=120)


def send_preview_album(run_id: str, stage: str, keyboard: dict) -> int:
    slides = _collect_carousel_images(run_id)
    if not slides:
        return 0
    caption = _short_album_caption(run_id, stage, len(slides))
    if len(slides) == 1:
        _multipart_send(
            "sendPhoto",
            {"chat_id": TELEGRAM_CHAT_ID, "caption": caption, "reply_markup": json.dumps(keyboard)},
            "photo",
            slides[0],
        )
        return 1
    media = []
    for i, path in enumerate(slides):
        item: dict[str, Any] = {"type": "photo", "media": f"attach://photo{i}"}
        if i == 0:
            item["caption"] = caption
        media.append(item)
    boundary = "----automediagateway"
    parts: list[bytes] = []
    parts.append(
        (
            f"--{boundary}\r\nContent-Disposition: form-data; name=\"chat_id\"\r\n\r\n"
            f"{TELEGRAM_CHAT_ID}\r\n"
        ).encode()
    )
    parts.append(
        (
            f"--{boundary}\r\nContent-Disposition: form-data; name=\"media\"\r\n\r\n"
            f"{json.dumps(media, ensure_ascii=False)}\r\n"
        ).encode()
    )
    for i, path in enumerate(slides):
        mime = "image/jpeg" if path.suffix.lower() in (".jpg", ".jpeg") else "image/png"
        parts.append(
            (
                f"--{boundary}\r\nContent-Disposition: form-data; name=\"photo{i}\"; "
                f"filename=\"{path.name}\"\r\nContent-Type: {mime}\r\n\r\n"
            ).encode()
        )
        with path.open("rb") as f:
            parts.append(f.read())
        parts.append(b"\r\n")
    parts.append(f"--{boundary}--\r\n".encode())
    payload = b"".join(parts)
    req = urllib.request.Request(
        f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendMediaGroup",
        data=payload,
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
        method="POST",
    )
    urllib.request.urlopen(req, timeout=180)
    return len(slides)


def send_preview_copy(run_id: str, stage: str) -> None:
    post = DATA_ROOT / "runs" / run_id / "post.md"
    if not post.is_file():
        return
    posts = _split_part1_posts(post)
    total = len(posts) or 1
    for i, text in enumerate(posts or [post.read_text(encoding="utf-8", errors="replace")[:4000]], start=1):
        header = f"貼文 {i}/{total}\n\n"
        chunk = header + text
        while chunk:
            piece = chunk[:4096]
            chunk = chunk[4096:]
            telegram_api("sendMessage", {"chat_id": TELEGRAM_CHAT_ID, "text": piece})
    doc_path = post
    boundary = "----automediagateway"
    with doc_path.open("rb") as f:
        doc_bytes = f.read()
    fields = {"chat_id": TELEGRAM_CHAT_ID}
    fname = f"{run_id}-post.md"
    parts: list[bytes] = []
    for name, val in fields.items():
        parts.append(
            (
                f"--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n"
                f"{val}\r\n"
            ).encode()
        )
    parts.append(
        (
            f"--{boundary}\r\nContent-Disposition: form-data; name=\"document\"; "
            f"filename=\"{fname}\"\r\nContent-Type: text/markdown\r\n\r\n"
        ).encode()
    )
    parts.append(doc_bytes)
    parts.append(f"\r\n--{boundary}--\r\n".encode())
    req = urllib.request.Request(
        f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendDocument",
        data=b"".join(parts),
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
        method="POST",
    )
    urllib.request.urlopen(req, timeout=60)


def _run_post_image(run_id: str) -> Path | None:
    run_dir = DATA_ROOT / "runs" / run_id
    carousel = run_dir / "carousel"
    if carousel.is_dir():
        for pattern in ("01.png", "01.jpg", "1.png"):
            p = carousel / pattern
            if p.is_file():
                return p
        slides = sorted(carousel.glob("*.png")) + sorted(carousel.glob("*.jpg"))
        if slides:
            return slides[0]
    for name in ("post.png", "post.jpg", "post.jpeg"):
        p = run_dir / name
        if p.is_file():
            return p
    return None


def send_preview(run_id: str, stage: str = "v1") -> None:
    keyboard = _preview_keyboard(stage, run_id)
    album_n = send_preview_album(run_id, stage, keyboard)
    send_preview_copy(run_id, stage)
    if album_n == 0:
        telegram_api(
            "sendMessage",
            {
                "chat_id": TELEGRAM_CHAT_ID,
                "text": f"（本 run 未產輪播圖，僅文字預覽）run_id={run_id}",
            },
        )
    telegram_api(
        "sendMessage",
        {
            "chat_id": TELEGRAM_CHAT_ID,
            "text": (
                f"審閱 run_id={run_id}（{stage}）— "
                + ("請確認上方輪播與全文後選擇：" if album_n else "請確認上方全文後選擇：")
            ),
            "reply_markup": keyboard,
        },
    )


def abort_pre_wait(execution_id: str, run_id: str, reason: str) -> None:
    if N8N_API_KEY and execution_id:
        http_json(
            "DELETE",
            f"{N8N_API_URL}/api/v1/executions/{execution_id}",
            headers={"X-N8N-API-KEY": N8N_API_KEY},
        )
    telegram_api("sendMessage", {"chat_id": TELEGRAM_CHAT_ID, "text": f"Run {run_id} aborted (pre-wait): {reason}"})
    map_file = DATA_ROOT / "hitl" / "resume_map" / f"{run_id}-v1.json"
    if map_file.is_file():
        map_file.unlink()


def _n8n_resume_url(url: str) -> str:
    """Rewrite localhost resume URLs so gateway container can reach n8n."""
    if not url:
        return url
    # n8n often emits http://localhost:5678/webhook-waiting/...
    for bad in ("http://localhost:5678", "http://127.0.0.1:5678"):
        if url.startswith(bad):
            base = os.environ.get("N8N_API_URL", "http://n8n:5678").rstrip("/")
            return base + url[len(bad) :]
    return url


def abort_post_wait(run_id: str, stage: str, reason: str) -> None:
    map_file = DATA_ROOT / "hitl" / "resume_map" / f"{run_id}-{stage}.json"
    if map_file.is_file():
        m = json.loads(map_file.read_text(encoding="utf-8"))
        url = _n8n_resume_url(str(m.get("resume_url", "")))
        if url:
            sep = "&" if "?" in url else "?"
            http_json("GET", f"{url}{sep}callback=reject&run_id={urllib.parse.quote(run_id)}&stage={stage}")
    telegram_api(
        "sendMessage",
        {
            "chat_id": TELEGRAM_CHAT_ID,
            "text": f"Run {run_id} aborted: {reason}",
            "reply_markup": {
                "inline_keyboard": [[{"text": "Dismiss", "callback_data": f"am:{stage}:reject:{run_id}"}]]
            },
        },
    )


def _route_user_text(text: str) -> str:
    t = text.strip()
    if t in ("/用量", "/usage", "用量查詢", "用量查询"):
        return "usage_query"
    if t.startswith("/"):
        return "unknown_command"
    return "topic_start"


def _parse_hitl_callback(update: dict) -> tuple[str, str, str]:
    cb = update.get("callback_query") or {}
    data = str(cb.get("data", ""))
    m = re.match(r"^am:(v[12]):(approve|revise|reject):([A-Za-z0-9._-]+)$", data)
    if not m:
        return "", "", ""
    return m.group(1), m.group(2), m.group(3)


def _mark_hitl_stage(run_id: str, stage: str) -> None:
    run_dir = DATA_ROOT / "runs" / run_id
    cmd = [
        "python3",
        str(REPO_ROOT / "scripts" / "lib" / "run_state.py"),
        "--run-dir",
        str(run_dir),
        "--run-id",
        run_id,
        "mark",
        "--stage",
        stage,
    ]
    subprocess.run(cmd, check=True, capture_output=True, text=True, timeout=20)


def mark_hitl_approval_if_needed(update: dict) -> None:
    stage, decision, run_id = _parse_hitl_callback(update)
    if decision != "approve" or not run_id:
        return
    try:
        if stage == "v1":
            _mark_hitl_stage(run_id, "hitl_v1_pass")
        elif stage == "v2":
            _mark_hitl_stage(run_id, "hitl_v2_pass")
    except Exception as e:
        # Keep callback forwarding available even when stage mark fails.
        LOG.warning("mark hitl stage failed run_id=%s stage=%s err=%s", run_id, stage, e)


def forward_to_n8n(update: dict) -> None:
    url = f"{N8N_API_URL}/webhook/auto-media-telegram-in"
    http_json("POST", url, update)


def send_hermes_plan(run_id: str, chat_id: str) -> None:
    plan_path = DATA_ROOT / "runs" / run_id / "hermes_plan.json"
    if not plan_path.is_file():
        return
    try:
        plan = json.loads(plan_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return
    sys_path = str(REPO_ROOT / "scripts" / "lib")
    if sys_path not in __import__("sys").path:
        __import__("sys").path.insert(0, sys_path)
    from hermes_content_review import format_telegram

    telegram_api("sendMessage", {"chat_id": chat_id, "text": format_telegram(plan)[:4096]})


def trigger_n8n_run(run_id: str, topic: str, chat_id: str, publish_targets: str = "") -> None:
    body: dict[str, Any] = {
        "run_id": run_id,
        "topic": topic,
        "chat_id": chat_id,
        "audience": "general",
    }
    if publish_targets:
        body["publish_targets"] = publish_targets
    http_json("POST", f"{N8N_API_URL}{N8N_WEBHOOK_RUN}", body)


def worker_loop() -> None:
    while True:
        try:
            job = JOB_QUEUE.get(timeout=1)
        except Empty:
            continue
        t0 = time.time()
        jt = job.get("job_type", "")
        try:
            if jt == "telegram_callback":
                mark_hitl_approval_if_needed(job["update"])
                forward_to_n8n(job["update"])
            elif jt == "telegram_feedback":
                forward_to_n8n(job["update"])
            elif jt == "topic_start":
                run_id = job["run_id"]
                chat_id = job.get("chat_id", TELEGRAM_CHAT_ID)
                send_platform_select(chat_id, run_id, job["topic"])
            elif jt == "platform_callback":
                handle_platform_callback(job["update"])
            elif jt == "schedule_prereview":
                eid = job["execution_id"]
                run_id = job["run_id"]
                state = poll_execution_ready(eid)
                if state == "waiting":
                    run_script("hermes_content_review.sh", "--run-id", run_id)
                    send_hermes_plan(run_id, TELEGRAM_CHAT_ID)
                    if prereview_run(run_id):
                        send_preview(run_id, job.get("stage", "v1"))
                    else:
                        abort_post_wait(run_id, job.get("stage", "v1"), "prereview failed")
                elif state == "timeout":
                    abort_pre_wait(eid, run_id, "poll timeout (never reached waiting)")
                else:
                    abort_pre_wait(eid, run_id, f"execution ended early: {state}")
            elif jt == "abort_hitl":
                mode = job.get("abort_mode", "pre_wait")
                if mode == "post_wait":
                    abort_post_wait(job["run_id"], job.get("stage", "v1"), job.get("reason", ""))
                else:
                    abort_pre_wait(job.get("execution_id", ""), job["run_id"], job.get("reason", ""))
            elif jt == "notify":
                telegram_api("sendMessage", {"chat_id": job.get("chat_id", TELEGRAM_CHAT_ID), "text": job["text"]})
            elif jt == "usage_query":
                sys_path = str(REPO_ROOT / "scripts" / "lib")
                if sys_path not in __import__("sys").path:
                    __import__("sys").path.insert(0, sys_path)
                from usage_query import handle_usage_query

                telegram_api(
                    "sendMessage",
                    {"chat_id": job.get("chat_id", TELEGRAM_CHAT_ID), "text": handle_usage_query()},
                )
            log_gateway(jt, "out", job_type=jt, run_id=job.get("run_id", ""), latency_ms=int((time.time() - t0) * 1000), ok=True)
        except Exception as e:
            LOG.exception("job %s failed", jt)
            log_gateway(jt, "out", job_type=jt, ok=False, error=str(e))
        finally:
            JOB_QUEUE.task_done()


class GatewayHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt: str, *args: Any) -> None:
        LOG.debug(fmt, *args)

    def _check_secret(self) -> bool:
        if not GATEWAY_SECRET:
            return True
        import hmac
        return hmac.compare_digest(self.headers.get("X-Gateway-Secret", ""), GATEWAY_SECRET)

    def _check_telegram_secret(self) -> bool:
        # Telegram echoes the secret_token set via setWebhook in this header.
        # Refuse if no secret is configured: an unauthenticated /telegram can
        # trigger the full production publish pipeline.
        if not TELEGRAM_WEBHOOK_SECRET:
            return False
        import hmac
        got = self.headers.get("X-Telegram-Bot-Api-Secret-Token", "")
        return hmac.compare_digest(got, TELEGRAM_WEBHOOK_SECRET)

    def _json_response(self, code: int, body: dict) -> None:
        raw = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self) -> None:
        path = self.path.split("?", 1)[0]
        if path in ("/", "/healthz"):
            self._json_response(200, {"ok": True, "service": "hermes-gateway"})
            return
        self._json_response(404, {"ok": False, "error": "not found"})

    def do_POST(self) -> None:
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length else b"{}"
        try:
            payload = json.loads(raw.decode() or "{}")
        except json.JSONDecodeError:
            self._json_response(400, {"ok": False, "error": "invalid json"})
            return

        path = self.path.split("?", 1)[0]

        if path == "/telegram":
            if not self._check_telegram_secret():
                log_gateway("telegram_update", "in", ok=False, error="bad telegram secret")
                self._json_response(403, {"ok": False, "error": "forbidden"})
                return
            update = payload if "update_id" in payload else payload.get("update", payload)
            uid = int(update.get("update_id", 0))
            if uid and not mark_update(uid):
                self._json_response(200, {"ok": True, "deduped": True})
                return
            log_gateway("telegram_update", "in", update_id=uid)
            if update.get("callback_query"):
                data = str((update.get("callback_query") or {}).get("data", ""))
                if data.startswith("am:plat:"):
                    JOB_QUEUE.put({"job_type": "platform_callback", "update": update})
                else:
                    JOB_QUEUE.put({"job_type": "telegram_callback", "update": update})
            elif update.get("message", {}).get("reply_to_message"):
                JOB_QUEUE.put({"job_type": "telegram_feedback", "update": update})
            elif update.get("message", {}).get("text"):
                text = update["message"]["text"].strip()
                if not text:
                    pass
                else:
                    chat_id = str(update["message"]["chat"]["id"])
                    route = _route_user_text(text)
                    if route == "usage_query":
                        JOB_QUEUE.put({"job_type": "usage_query", "chat_id": chat_id})
                    elif route == "unknown_command":
                        telegram_api(
                            "sendMessage",
                            {"chat_id": chat_id, "text": "未知指令。輸入主題文字開始產文，或傳送「用量查詢」。"},
                        )
                    else:
                        import uuid

                        run_id = time.strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:8]
                        JOB_QUEUE.put({"job_type": "topic_start", "run_id": run_id, "topic": text, "chat_id": chat_id})
            self._json_response(200, {"ok": True})
            return

        if path.startswith("/internal/"):
            if not self._check_secret():
                self._json_response(403, {"ok": False, "error": "forbidden"})
                return
            if path == "/internal/schedule-prereview":
                JOB_QUEUE.put({
                    "job_type": "schedule_prereview",
                    "run_id": payload.get("run_id", ""),
                    "execution_id": str(payload.get("execution_id", "")),
                    "stage": payload.get("stage", "v1"),
                })
                self._json_response(200, {"ok": True, "queued": True})
                return
            if path in ("/internal/abort-hitl", "/internal/abort-pre-wait", "/internal/abort-post-wait"):
                mode = payload.get("abort_mode", "pre_wait")
                if path.endswith("post-wait"):
                    mode = "post_wait"
                elif path.endswith("pre-wait"):
                    mode = "pre_wait"
                JOB_QUEUE.put({
                    "job_type": "abort_hitl",
                    "abort_mode": mode,
                    "run_id": payload.get("run_id", ""),
                    "execution_id": str(payload.get("execution_id", "")),
                    "stage": payload.get("stage", "v1"),
                    "reason": payload.get("reason", ""),
                })
                self._json_response(200, {"ok": True})
                return
            if path == "/internal/notify":
                JOB_QUEUE.put({
                    "job_type": "notify",
                    "chat_id": payload.get("chat_id", TELEGRAM_CHAT_ID),
                    "text": payload.get("text", ""),
                })
                self._json_response(200, {"ok": True})
                return

        self._json_response(404, {"ok": False, "error": "not found"})


def main() -> None:
    init_db()
    threading.Thread(target=worker_loop, daemon=True, name="gateway-worker").start()
    server = ThreadingHTTPServer(("0.0.0.0", GATEWAY_PORT), GatewayHandler)
    LOG.info("Gateway listening on :%s db=%s", GATEWAY_PORT, GATEWAY_DB)
    server.serve_forever()


if __name__ == "__main__":
    main()
