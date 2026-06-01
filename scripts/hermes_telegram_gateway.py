#!/usr/bin/env python3
"""B-prime Telegram Gateway: pure I/O proxy (Model A). Async via background worker thread."""
from __future__ import annotations

import json
import logging
import os
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


def init_db() -> None:
    GATEWAY_DB.parent.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(GATEWAY_DB) as conn:
        conn.execute(
            "CREATE TABLE IF NOT EXISTS processed_updates (update_id INTEGER PRIMARY KEY)"
        )
        conn.commit()


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


def build_caption(run_id: str) -> str:
    post = DATA_ROOT / "runs" / run_id / "post.md"
    assess = DATA_ROOT / "runs" / run_id / "hermes_assessment.json"
    body = post.read_text(encoding="utf-8", errors="replace") if post.is_file() else ""
    hint = ""
    if assess.is_file():
        try:
            a = json.loads(assess.read_text(encoding="utf-8"))
            hint = f"\n[Hermes] risk={a.get('risk_level','low')} hint={a.get('verdict_hint','pass')}"
        except json.JSONDecodeError:
            pass
    return (body[:900] + hint)[:1024]


def send_preview(run_id: str, stage: str = "v1") -> None:
    png = DATA_ROOT / "runs" / run_id / "post.png"
    if not png.is_file():
        telegram_api("sendMessage", {"chat_id": TELEGRAM_CHAT_ID, "text": f"run {run_id}: missing post.png"})
        return
    caption = build_caption(run_id)
    keyboard = {
        "inline_keyboard": [[
            {"text": "Approve", "callback_data": f"am:{stage}:approve:{run_id}"},
            {"text": "Revise", "callback_data": f"am:{stage}:revise:{run_id}"},
            {"text": "Reject", "callback_data": f"am:{stage}:reject:{run_id}"},
        ]]
    }
    with png.open("rb") as f:
        import mimetypes
        boundary = "----automediagateway"
        body = []
        for field, val in [("chat_id", TELEGRAM_CHAT_ID), ("caption", caption), ("reply_markup", json.dumps(keyboard))]:
            body.append(f"--{boundary}\r\nContent-Disposition: form-data; name=\"{field}\"\r\n\r\n{val}\r\n")
        body.append(
            f"--{boundary}\r\nContent-Disposition: form-data; name=\"photo\"; filename=\"post.png\"\r\n"
            f"Content-Type: image/png\r\n\r\n"
        )
        tail = f"\r\n--{boundary}--\r\n"
        payload = "".join(body).encode() + f.read() + tail.encode()
        req = urllib.request.Request(
            f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendPhoto",
            data=payload,
            headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
            method="POST",
        )
        urllib.request.urlopen(req, timeout=60)


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


def abort_post_wait(run_id: str, stage: str, reason: str) -> None:
    map_file = DATA_ROOT / "hitl" / "resume_map" / f"{run_id}-{stage}.json"
    if map_file.is_file():
        m = json.loads(map_file.read_text(encoding="utf-8"))
        url = str(m.get("resume_url", ""))
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


def forward_to_n8n(update: dict) -> None:
    url = f"{N8N_API_URL}/webhook/auto-media-telegram-in"
    http_json("POST", url, update)


def trigger_n8n_run(run_id: str, topic: str, chat_id: str) -> None:
    body = {"run_id": run_id, "topic": topic, "chat_id": chat_id, "audience": "general"}
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
                forward_to_n8n(job["update"])
            elif jt == "telegram_feedback":
                forward_to_n8n(job["update"])
            elif jt == "topic_start":
                run_id = job["run_id"]
                run_script("write_task.sh", "--run-id", run_id, "--topic", job["topic"])
                trigger_n8n_run(run_id, job["topic"], job.get("chat_id", ""))
                telegram_api("sendMessage", {"chat_id": job.get("chat_id", TELEGRAM_CHAT_ID), "text": f"已收到，生產中… run_id={run_id}"})
            elif jt == "schedule_prereview":
                eid = job["execution_id"]
                run_id = job["run_id"]
                state = poll_execution_ready(eid)
                if state == "waiting":
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
                JOB_QUEUE.put({"job_type": "telegram_callback", "update": update})
            elif update.get("message", {}).get("reply_to_message"):
                JOB_QUEUE.put({"job_type": "telegram_feedback", "update": update})
            elif update.get("message", {}).get("text"):
                text = update["message"]["text"].strip()
                if text and not text.startswith("/"):
                    import uuid
                    run_id = time.strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:8]
                    chat_id = str(update["message"]["chat"]["id"])
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
