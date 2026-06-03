#!/usr/bin/env python3
"""Config version snapshots + manifest for wizard/dashboard rollback."""
from __future__ import annotations

import hashlib
import json
import re
import shutil
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

SECRET_KEYS = re.compile(
    r"(TOKEN|SECRET|KEY|PASSWORD|PIN|OAUTH|CREDENTIAL)",
    re.I,
)


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _git_sha(repo: Path) -> str:
    import subprocess

    try:
        out = subprocess.run(
            ["git", "-C", str(repo), "rev-parse", "--short", "HEAD"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if out.returncode == 0:
            return out.stdout.strip()
    except OSError:
        pass
    return ""


def versions_root(data_root: Path) -> Path:
    return data_root / "versions"


def manifest_path(data_root: Path) -> Path:
    return versions_root(data_root) / "manifest.jsonl"


def _redact_env(text: str) -> str:
    lines: list[str] = []
    for line in text.splitlines():
        if "=" not in line or line.strip().startswith("#"):
            lines.append(line)
            continue
        key, _, val = line.partition("=")
        if SECRET_KEYS.search(key):
            lines.append(f"{key}=***")
        else:
            lines.append(line)
    return "\n".join(lines) + ("\n" if text.endswith("\n") else "")


def snapshot_file(
    data_root: Path,
    target: str,
    source: Path,
    *,
    actor: str = "console",
    reason: str = "",
    repo: Path | None = None,
) -> Path:
    """Copy source to data/versions/<target>/<ts>-<sha8>.snap; append manifest."""
    if not source.is_file():
        raise FileNotFoundError(source)
    content = source.read_text(encoding="utf-8")
    if target == ".env":
        content = _redact_env(content)
    digest = hashlib.sha256(content.encode("utf-8")).hexdigest()[:8]
    ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    dest_dir = versions_root(data_root) / target.replace("/", "_")
    dest_dir.mkdir(parents=True, exist_ok=True)
    snap = dest_dir / f"{ts}-{digest}.snap"
    snap.write_text(content, encoding="utf-8")
    entry = {
        "ts": _now(),
        "target": target,
        "path": str(snap.relative_to(data_root)),
        "sha256": hashlib.sha256(content.encode("utf-8")).hexdigest(),
        "actor": actor,
        "reason": reason,
        "git_sha": _git_sha(repo or data_root.parent),
    }
    mp = manifest_path(data_root)
    mp.parent.mkdir(parents=True, exist_ok=True)
    with mp.open("a", encoding="utf-8") as f:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")
    return snap


def list_versions(data_root: Path, target: str | None = None, limit: int = 50) -> list[dict[str, Any]]:
    mp = manifest_path(data_root)
    if not mp.is_file():
        return []
    rows: list[dict[str, Any]] = []
    for line in mp.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        if target and row.get("target") != target:
            continue
        rows.append(row)
    return rows[-limit:]


def restore_snapshot(data_root: Path, snap_rel: str, dest: Path) -> None:
    snap = data_root / snap_rel
    if not snap.is_file():
        raise FileNotFoundError(snap)
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(snap, dest)
