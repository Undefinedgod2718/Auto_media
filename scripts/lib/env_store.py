#!/usr/bin/env python3
"""Safe .env read/write helpers for local settings UI."""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import re
from typing import Iterable


@dataclass(frozen=True)
class EnvField:
    name: str
    group: str
    secret: bool = True
    editable: bool = True
    description: str = ""


FIELD_SPECS: tuple[EnvField, ...] = (
    EnvField("N8N_ENCRYPTION_KEY", "n8n", True, True, "n8n encryption key"),
    EnvField("N8N_API_URL", "n8n", False, True, "n8n API base URL"),
    EnvField("N8N_API_KEY", "n8n", True, True, "n8n API key"),
    EnvField("WEBHOOK_URL", "n8n", False, True, "public webhook base URL"),
    EnvField("TELEGRAM_BOT_TOKEN", "telegram", True, True, "Telegram bot token"),
    EnvField("TELEGRAM_CHAT_ID", "telegram", False, True, "Telegram chat id"),
    EnvField("TELEGRAM_WEBHOOK_SECRET", "telegram", True, True, "Telegram webhook secret"),
    EnvField("GATEWAY_INTERNAL_SECRET", "gateway", True, True, "Gateway internal secret"),
    EnvField("META_PAGE_ID", "meta", False, True, "Facebook page id"),
    EnvField("META_PAGE_ACCESS_TOKEN", "meta", True, True, "Facebook page access token"),
    EnvField("META_GRAPH_API_VERSION", "meta", False, True, "Meta Graph API version"),
    EnvField("IG_USER_ID", "meta", False, True, "Instagram business id"),
    EnvField("THREADS_USER_ID", "threads", False, True, "Threads user id"),
    EnvField("THREADS_ACCESS_TOKEN", "threads", True, True, "Threads access token"),
    EnvField("ANTHROPIC_API_KEY", "llm", True, True, "Anthropic API key"),
    EnvField("CLAUDE_CODE_OAUTH_TOKEN", "llm", True, True, "Claude OAuth token"),
    EnvField("GEMINI_API_KEY", "llm", True, True, "Gemini API key"),
)

FIELD_MAP = {f.name: f for f in FIELD_SPECS}
ALLOWED_FIELDS = frozenset(FIELD_MAP.keys())

COMMENT_RE = re.compile(r"^\s*#")
ASSIGN_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$")


def parse_env(path: Path) -> tuple[list[str], dict[str, str]]:
    if not path.exists():
        return [], {}
    lines = path.read_text(encoding="utf-8").splitlines()
    values: dict[str, str] = {}
    for line in lines:
        if COMMENT_RE.match(line):
            continue
        m = ASSIGN_RE.match(line)
        if not m:
            continue
        values[m.group(1)] = m.group(2)
    return lines, values


def mask_value(name: str, value: str) -> str:
    if not value:
        return ""
    spec = FIELD_MAP.get(name)
    if spec and not spec.secret:
        return value
    if len(value) <= 4:
        return "*" * len(value)
    return "*" * (len(value) - 4) + value[-4:]


def status_payload(values: dict[str, str]) -> list[dict]:
    out: list[dict] = []
    for spec in FIELD_SPECS:
        raw = values.get(spec.name, "")
        out.append(
            {
                "name": spec.name,
                "group": spec.group,
                "secret": spec.secret,
                "editable": spec.editable,
                "description": spec.description,
                "is_set": bool(raw),
                "masked": mask_value(spec.name, raw) if raw else "",
            }
        )
    return out


def schema_payload() -> list[dict]:
    return [
        {
            "name": spec.name,
            "group": spec.group,
            "secret": spec.secret,
            "editable": spec.editable,
            "description": spec.description,
        }
        for spec in FIELD_SPECS
    ]


def _validated_updates(updates: dict[str, str]) -> dict[str, str]:
    clean: dict[str, str] = {}
    for key, val in updates.items():
        if key not in ALLOWED_FIELDS:
            raise ValueError(f"field not allowed: {key}")
        if val is None:
            continue
        if not isinstance(val, str):
            raise ValueError(f"invalid value type for {key}")
        v = val.strip()
        if not v:
            continue
        clean[key] = v
    return clean


def _line_index(lines: Iterable[str]) -> dict[str, int]:
    idx: dict[str, int] = {}
    for i, line in enumerate(lines):
        m = ASSIGN_RE.match(line)
        if m:
            idx[m.group(1)] = i
    return idx


def update_env(path: Path, updates: dict[str, str]) -> list[str]:
    clean = _validated_updates(updates)
    if not clean:
        return []
    lines, _ = parse_env(path)
    idx = _line_index(lines)
    changed: list[str] = []
    for key, val in clean.items():
        line = f"{key}={val}"
        if key in idx:
            lines[idx[key]] = line
        else:
            lines.append(line)
        changed.append(key)
    content = "\n".join(lines).rstrip("\n") + "\n"
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(content, encoding="utf-8")
    tmp.replace(path)
    return changed

