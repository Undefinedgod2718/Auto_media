#!/usr/bin/env python3
"""Apply B-prime v4 workflow patches to happy-path and forwarder JSON."""
from __future__ import annotations

import json
import uuid
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
HAPPY = REPO / "workflows" / "auto-media-happy-path.json"
FWD = REPO / "workflows" / "auto-media-hitl-forwarder.json"

SAVE_JS_V1 = r"""const runId = $('Set run context').item.json.run_id;
const resumeUrl = String($execution.resumeUrl || '');
if (!resumeUrl) throw new Error('Missing resumeUrl — use production webhook trigger');
const stage = 'v1';
const executionId = String($execution.id || '');
const fs = require('fs');
const dir = '/data/hitl/resume_map';
fs.mkdirSync(dir, { recursive: true });
const mapFile = dir + '/' + runId + '-' + stage + '.json';
fs.writeFileSync(mapFile, JSON.stringify({ run_id: runId, stage, resume_url: resumeUrl, execution_id: executionId, created_at: new Date().toISOString() }) + '\n');
return { json: { ...$input.item.json, run_id: runId, resume_url: resumeUrl, execution_id: executionId } };"""

CLASSIFY_RESUME_JS = r"""const cb = $json.body?.callback ?? $json.query?.callback ?? $json.callback;
const has = ['approve','revise','reject'].includes(String(cb || ''));
return { json: { ...$json, hitl_resume_kind: has ? 'human' : 'ttl_expired', callback: cb || '' } };"""

PARSE_RESUME_MAP_JS = r"""const raw = $input.item.json.stdout || '{}';
let map;
try { map = JSON.parse(raw); } catch (e) { throw new Error('invalid resume map: ' + raw); }
const cb = $('Parse Telegram update').item.json;
if (!map.resume_url) throw new Error('resume_url missing');
let url = String(map.resume_url);
url = url.replace(/\/(auto-media-[^/?&]+)$/, '');
url = url.replace(/(signature=[^&]+)\/auto-media-[^&]+/, '$1');
const sep = url.indexOf('?') >= 0 ? '&' : '?';
const resume_url = url + sep + 'callback=' + encodeURIComponent(cb.callback) + '&run_id=' + encodeURIComponent(cb.run_id) + '&stage=' + encodeURIComponent(cb.stage);
return { json: { ...cb, resume_url } };"""


def nid() -> str:
    return uuid.uuid4().hex[:12]


def patch_happy(data: dict) -> None:
    nodes = {n["name"]: n for n in data["nodes"]}
    conn = data.setdefault("connections", {})

    # Webhook body for topic entry
    if "Set run context" in nodes:
        for a in nodes["Set run context"]["parameters"]["assignments"]["assignments"]:
            if a["name"] == "topic":
                a["value"] = "={{ $json.body?.topic || $json.topic || 'AI 發展趨勢' }}"
            if a["name"] == "run_id":
                a["value"] = "={{ $json.body?.run_id || $now.format('yyyyMMdd-HHmmss') + '-' + $execution.id }}"
            if a["name"] == "audience":
                a["value"] = "={{ $json.body?.audience || $json.audience || '25-35 歲科技愛好者' }}"

    # Add nodes if missing
    if "Save wait resume URL (stage1)" not in nodes:
        data["nodes"].append({
            "parameters": {"mode": "runOnceForEachItem", "jsCode": SAVE_JS_V1},
            "id": f"save-resume-v1-{nid()}",
            "name": "Save wait resume URL (stage1)",
            "type": "n8n-nodes-base.code",
            "typeVersion": 2,
            "position": [1700, -60],
        })
    if "Schedule Gateway prereview (stage1)" not in nodes:
        data["nodes"].append({
            "parameters": {
                "method": "POST",
                "url": "={{ (process.env.GATEWAY_URL || 'http://host.docker.internal:8787') + '/internal/schedule-prereview' }}",
                "sendHeaders": True,
                "headerParameters": {
                    "parameters": [
                        {"name": "X-Gateway-Secret", "value": "={{ process.env.GATEWAY_INTERNAL_SECRET || '' }}"},
                        {"name": "Content-Type", "value": "application/json"},
                    ]
                },
                "sendBody": True,
                "specifyBody": "json",
                "jsonBody": '={{ JSON.stringify({ run_id: $("Set run context").item.json.run_id, execution_id: String($execution.id), stage: "v1" }) }}',
                "options": {"timeout": 3000},
            },
            "id": f"sched-gw-v1-{nid()}",
            "name": "Schedule Gateway prereview (stage1)",
            "type": "n8n-nodes-base.httpRequest",
            "typeVersion": 4.2,
            "position": [1920, -60],
        })
    if "Check resume type (stage1)" not in nodes:
        data["nodes"].append({
            "parameters": {"mode": "runOnceForEachItem", "jsCode": CLASSIFY_RESUME_JS},
            "id": f"classify-v1-{nid()}",
            "name": "Check resume type (stage1)",
            "type": "n8n-nodes-base.code",
            "typeVersion": 2,
            "position": [2200, 0],
        })
    if "Notify run rejected (stage1)" not in nodes:
        data["nodes"].append({
            "parameters": {
                "command": '=/bin/bash -c \'curl -fsS -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" -d "chat_id=${TELEGRAM_CHAT_ID}" -d "text=Run {{ $(\'Set run context\').item.json.run_id }} rejected (TTL or abort)."\'\'',
            },
            "id": f"notify-reject-v1-{nid()}",
            "name": "Notify run rejected (stage1)",
            "type": "n8n-nodes-base.executeCommand",
            "typeVersion": 1,
            "position": [2640, 200],
        })

    nodes = {n["name"]: n for n in data["nodes"]}

    # Rewire: Render PNG -> Save -> Schedule -> Wait; Wait -> Check resume type
    conn["Render PNG"] = {"main": [[
        {"node": "Save wait resume URL (stage1)", "type": "main", "index": 0}
    ]]}
    conn["Save wait resume URL (stage1)"] = {"main": [[
        {"node": "Schedule Gateway prereview (stage1)", "type": "main", "index": 0}
    ]]}
    conn["Schedule Gateway prereview (stage1)"] = {"main": [[
        {"node": "Wait for approval (stage1)", "type": "main", "index": 0}
    ]]}
    conn["Wait for approval (stage1)"] = {"main": [[
        {"node": "Check resume type (stage1)", "type": "main", "index": 0}
    ]]}

    # Check resume type -> Switch callback OR ttl reject path
    conn["Check resume type (stage1)"] = {"main": [[
        {"node": "Switch callback (stage1)", "type": "main", "index": 0}
    ]]}

    # Switch reject [2] -> notify reject (not feedback)
    sc = conn.get("Switch callback (stage1)", {}).get("main", [[], [], []])
    if len(sc) >= 3:
        sc[2] = [{"node": "Notify run rejected (stage1)", "type": "main", "index": 0}]
    conn["Switch callback (stage1)"] = {"main": sc}


def patch_forwarder(data: dict) -> None:
    names = {n["name"] for n in data["nodes"]}
    if "Read wait resume map" not in names:
        data["nodes"].append({
            "parameters": {
                "command": "=/bin/bash /data/scripts/read_hitl_resume_map.sh --run-id \"{{ $('Parse Telegram update').item.json.run_id }}\" --stage \"{{ $('Parse Telegram update').item.json.stage }}\"",
            },
            "id": f"read-resume-{nid()}",
            "name": "Read wait resume map",
            "type": "n8n-nodes-base.executeCommand",
            "typeVersion": 1,
            "position": [720, -280],
        })
        data["nodes"].append({
            "parameters": {"mode": "runOnceForEachItem", "jsCode": PARSE_RESUME_MAP_JS},
            "id": f"parse-resume-{nid()}",
            "name": "Parse wait resume map",
            "type": "n8n-nodes-base.code",
            "typeVersion": 2,
            "position": [840, -280],
        })
    for n in data["nodes"]:
        if n["name"].startswith("Resume Wait hitl-v1"):
            n["parameters"] = {
                "method": "GET",
                "url": "={{ $json.resume_url }}",
                "options": {},
            }
        if n["name"].startswith("Resume Wait hitl-v2"):
            n["parameters"] = {
                "method": "GET",
                "url": "={{ $json.resume_url }}",
                "options": {},
            }

    conn = data.setdefault("connections", {})
    conn["Route callback stage"] = {
        "main": [
            [{"node": "Read wait resume map", "type": "main", "index": 0}],
            [{"node": "Read wait resume map", "type": "main", "index": 0}],
        ]
    }
    conn["Read wait resume map"] = {"main": [[{"node": "Parse wait resume map", "type": "main", "index": 0}]]}
    conn["Parse wait resume map"] = {
        "main": [[{"node": "Resume Wait hitl-v1", "type": "main", "index": 0}]]
    }


def main() -> None:
    for path, patcher in ((HAPPY, patch_happy), (FWD, patch_forwarder)):
        data = json.loads(path.read_text(encoding="utf-8"))
        patcher(data)
        path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        print(f"Patched {path.name}")


if __name__ == "__main__":
    main()
