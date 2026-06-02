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

SAVE_JS_V2 = r"""const runId = $('Set run context').item.json.run_id;
const resumeUrl = String($execution.resumeUrl || '');
if (!resumeUrl) throw new Error('Missing resumeUrl — use production webhook trigger');
const stage = 'v2';
const executionId = String($execution.id || '');
const fs = require('fs');
const dir = '/data/hitl/resume_map';
fs.mkdirSync(dir, { recursive: true });
const mapFile = dir + '/' + runId + '-' + stage + '.json';
fs.writeFileSync(mapFile, JSON.stringify({ run_id: runId, stage, resume_url: resumeUrl, execution_id: executionId, created_at: new Date().toISOString() }) + '\n');
return { json: { ...$input.item.json, run_id: runId, resume_url: resumeUrl, execution_id: executionId } };"""

TELEGRAM_PREVIEW_NODES = ("Telegram HITL preview", "Telegram HITL preview (stage2)")

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

SAVE_JS_FEEDBACK = r"""const runId = $('Set run context').item.json.run_id;
const resumeUrl = String($execution.resumeUrl || '');
if (!resumeUrl) throw new Error('Missing resumeUrl — use production webhook trigger');
const stage = 'feedback-v1';
const executionId = String($execution.id || '');
const fs = require('fs');
const dir = '/data/hitl/resume_map';
fs.mkdirSync(dir, { recursive: true });
const mapFile = dir + '/' + runId + '-' + stage + '.json';
fs.writeFileSync(mapFile, JSON.stringify({ run_id: runId, stage, resume_url: resumeUrl, execution_id: executionId, created_at: new Date().toISOString() }) + '\n');
return { json: { ...$input.item.json, run_id: runId, resume_url: resumeUrl, execution_id: executionId } };"""

PARSE_FEEDBACK_RESUME_JS = r"""const raw = $input.item.json.stdout || '{}';
let map;
try { map = JSON.parse(raw); } catch (e) { throw new Error('invalid feedback resume map: ' + raw); }
const fb = $('Merge feedback payload').item.json;
if (!map.resume_url) throw new Error('resume_url missing');
let url = String(map.resume_url);
url = url.replace(/\/(auto-media-[^/?&]+)$/, '');
url = url.replace(/(signature=[^&]+)\/auto-media-[^&]+/, '$1');
const sep = url.indexOf('?') >= 0 ? '&' : '?';
const resume_url = url + sep
  + 'feedback_text=' + encodeURIComponent(fb.feedback_text || '')
  + '&decision=' + encodeURIComponent(fb.decision || 'revise')
  + '&run_id=' + encodeURIComponent(fb.run_id || '')
  + '&stage=' + encodeURIComponent(fb.stage || 'v1');
return { json: { ...fb, resume_url } };"""

FEEDBACK_TEXT_EXPR = (
    "={{ $json.body?.feedback_text || $json.query?.feedback_text || $json.feedback_text || '' }}"
)


def nid() -> str:
    return uuid.uuid4().hex[:12]


RUN_ID_EXPR = "{{ $('Set run context').item.json.run_id }}"
CAROUSEL_TOTAL_EXPR = (
    "{{ $('Set run context').item.json.carousel_total || "
    "$('Webhook Run').item.json.body?.carousel_total || 8 }}"
)

SYNC_CAROUSEL_CMD = (
    f"=/bin/bash /data/scripts/sync_carousel_total.sh --run-id \"{RUN_ID_EXPR}\""
)

CAROUSEL_CMD = (
    f"=/bin/bash /data/scripts/generate_carousel_images.sh --run-id \"{RUN_ID_EXPR}\""
)

CHECK_SHOULD_CAROUSEL_CMD = (
    f"=/bin/bash /data/scripts/should_generate_carousel.sh --run-id \"{RUN_ID_EXPR}\" --json"
)

PARSE_SHOULD_CAROUSEL_JS = r"""const raw = ($input.item.json.stdout || '').trim();
let data = { should_generate: false };
try {
  const line = raw.split('\n').filter(Boolean).pop() || raw;
  data = JSON.parse(line);
} catch (e) {}
return { json: { ...$input.item.json, should_generate: !!data.should_generate } };"""

UPLOAD_CATBOX_CMD = (
    f"=/bin/bash /data/scripts/upload_carousel_catbox.sh --run-id \"{RUN_ID_EXPR}\""
)

PUBLISH_THREADS_CMD = (
    f"=/bin/bash /data/scripts/publish_threads_chain.sh --run-id \"{RUN_ID_EXPR}\""
)

PUBLISH_IG_CMD = f"=/bin/bash /data/scripts/publish_ig_carousel.sh --run-id \"{RUN_ID_EXPR}\""

VALIDATE_POST_CMD = (
    f"=/bin/bash /data/scripts/validate_post_md.sh --run-id \"{RUN_ID_EXPR}\""
)

PUBLISH_FB_CMD = f"=/bin/bash /data/scripts/publish_facebook.sh --run-id \"{RUN_ID_EXPR}\""

FINALIZE_GATE_CMD = (
    f"=/bin/bash /data/scripts/finalize_publish_gate.sh --run-id \"{RUN_ID_EXPR}\""
)

CHECK_LIMITS_PRE_HITL_CMD = (
    f"=/bin/bash /data/scripts/check_platform_limits.sh --run-id \"{RUN_ID_EXPR}\" --phase pre_hitl"
)

CHECK_LIMITS_PRE_PUBLISH_CMD = (
    f"=/bin/bash /data/scripts/check_platform_limits.sh --run-id \"{RUN_ID_EXPR}\" --phase pre_publish"
)

HERMES_CONTENT_REVIEW_CMD = (
    f"=/bin/bash /data/scripts/hermes_content_review.sh --run-id \"{RUN_ID_EXPR}\""
)

WRITE_TASK_CMD = (
    "=mkdir -p /data/runs/{{ $('Set run context').item.json.run_id }} && "
    "/bin/bash /data/scripts/write_task.sh "
    '--run-id "{{ $(\'Set run context\').item.json.run_id }}" '
    '--topic "{{ $(\'Set run context\').item.json.topic }}" '
    '--audience "{{ $(\'Set run context\').item.json.audience }}" '
    "--action generate_copy "
    "--carousel-total {{ $('Set run context').item.json.carousel_total || 0 }} "
    '--publish-targets "{{ $(\'Set run context\').item.json.publish_targets || $(\'Webhook Run\').item.json.body?.publish_targets || \'threads\' }}" '
    '--publish-mode-threads "{{ $(\'Set run context\').item.json.publish_mode_threads || \'carousel\' }}"'
)


def make_should_carousel_if_node(name: str, position: list[int]) -> dict:
    return {
        "parameters": {
            "conditions": {
                "options": {
                    "caseSensitive": True,
                    "leftValue": "",
                    "typeValidation": "strict",
                },
                "conditions": [
                    {
                        "id": nid(),
                        "leftValue": "={{ $json.should_generate }}",
                        "rightValue": True,
                        "operator": {
                            "type": "boolean",
                            "operation": "true",
                            "singleValue": True,
                        },
                    }
                ],
                "combinator": "and",
            },
            "options": {},
        },
        "id": f"if-carousel-{nid()}",
        "name": name,
        "type": "n8n-nodes-base.if",
        "typeVersion": 2.2,
        "position": position,
    }


def ensure_carousel_gate(
    data: dict,
    conn: dict,
    *,
    suffix: str,
    upstream: str,
    true_target: str,
    false_target: str,
    exec_pos: list[int],
    parse_pos: list[int],
    if_pos: list[int],
) -> None:
    check_name = f"Check should generate carousel{suffix}"
    parse_name = f"Parse should generate carousel{suffix}"
    if_name = f"IF Should generate carousel{suffix}"

    ensure_execute_node(data, check_name, CHECK_SHOULD_CAROUSEL_CMD, exec_pos)
    names = {n["name"] for n in data["nodes"]}
    if parse_name not in names:
        data["nodes"].append({
            "parameters": {"mode": "runOnceForEachItem", "jsCode": PARSE_SHOULD_CAROUSEL_JS},
            "id": f"parse-carousel-{suffix or 'main'}-{nid()}",
            "name": parse_name,
            "type": "n8n-nodes-base.code",
            "typeVersion": 2,
            "position": parse_pos,
        })
    nodes = {n["name"]: n for n in data["nodes"]}
    if if_name not in nodes:
        data["nodes"].append(make_should_carousel_if_node(if_name, if_pos))
    else:
        for n in data["nodes"]:
            if n.get("name") == if_name:
                n["parameters"] = make_should_carousel_if_node(if_name, if_pos)["parameters"]

    conn[upstream] = {"main": [[{"node": check_name, "type": "main", "index": 0}]]}
    conn[check_name] = {"main": [[{"node": parse_name, "type": "main", "index": 0}]]}
    conn[parse_name] = {"main": [[{"node": if_name, "type": "main", "index": 0}]]}
    conn[if_name] = {"main": [
        [{"node": true_target, "type": "main", "index": 0}],
        [{"node": false_target, "type": "main", "index": 0}],
    ]}


def make_if_node(name: str, env_var: str, position: list[int], platform: str = "") -> dict:
    # publish_targets gating lives in publish_*.sh (publish_target_gate.sh).
    # Do not embed fs IIFE here — nested {{ }} breaks n8n IF expressions (invalid syntax).
    _ = platform
    conditions: list[dict] = [
        {
            "id": nid(),
            "leftValue": f"={{{{ $env.{env_var} }}}}",
            "rightValue": "",
            "operator": {
                "type": "string",
                "operation": "notEmpty",
                "singleValue": True,
            },
        }
    ]
    return {
        "parameters": {
            "conditions": {
                "options": {
                    "caseSensitive": True,
                    "leftValue": "",
                    "typeValidation": "strict",
                },
                "conditions": conditions,
                "combinator": "and",
            },
            "options": {},
        },
        "id": f"if-{env_var.lower()}-{nid()}",
        "name": name,
        "type": "n8n-nodes-base.if",
        "typeVersion": 2.2,
        "position": position,
    }


def make_noop(name: str, position: list[int]) -> dict:
    return {
        "parameters": {},
        "id": f"noop-{nid()}",
        "name": name,
        "type": "n8n-nodes-base.noOp",
        "typeVersion": 1,
        "position": position,
    }


def ensure_execute_node(data: dict, name: str, command: str, position: list[int]) -> None:
    for n in data["nodes"]:
        if n.get("name") == name:
            n["parameters"] = {"command": command}
            if name == "Invoke carousel images":
                n.setdefault("parameters", {})["command"] = command
            return
    data["nodes"].append({
        "parameters": {"command": command},
        "id": f"exec-{name.replace(' ', '-').lower()}-{nid()}",
        "name": name,
        "type": "n8n-nodes-base.executeCommand",
        "typeVersion": 1,
        "position": position,
    })


def patch_happy(data: dict) -> None:
    nodes = {n["name"]: n for n in data["nodes"]}
    conn = data.setdefault("connections", {})

    # Webhook body (upstream is Load platform.runtime.json — not $json.body)
    wh = "$('Webhook Run').item.json.body"
    if "Set run context" in nodes:
        for a in nodes["Set run context"]["parameters"]["assignments"]["assignments"]:
            if a["name"] == "topic":
                a["value"] = f"={{{{ {wh}?.topic || 'AI 發展趨勢' }}}}"
            if a["name"] == "run_id":
                a["value"] = (
                    f"={{{{ {wh}?.run_id || $now.format('yyyyMMdd-HHmmss') + '-' + $execution.id }}}}"
                )
            if a["name"] == "audience":
                a["value"] = f"={{{{ {wh}?.audience || '25-35 歲科技愛好者' }}}}"
            if a["name"] == "carousel_total":
                a["value"] = f"={{{{ {wh}?.carousel_total || 0 }}}}"
            if a["name"] == "publish_targets":
                a["value"] = f"={{{{ {wh}?.publish_targets || 'threads' }}}}"
            if a["name"] == "publish_mode_threads":
                a["value"] = f"={{{{ {wh}?.publish_mode_threads || 'carousel' }}}}"
        assigns = nodes["Set run context"]["parameters"]["assignments"]["assignments"]
        if not any(a.get("name") == "carousel_total" for a in assigns):
            assigns.append({
                "id": "carousel_total",
                "name": "carousel_total",
                "value": f"={{{{ {wh}?.carousel_total || 0 }}}}",
                "type": "number",
            })
        if not any(a.get("name") == "publish_targets" for a in assigns):
            assigns.append({
                "id": "publish_targets",
                "name": "publish_targets",
                "value": f"={{{{ {wh}?.publish_targets || 'threads' }}}}",
                "type": "string",
            })
        if not any(a.get("name") == "publish_mode_threads" for a in assigns):
            assigns.append({
                "id": "publish_mode_threads",
                "name": "publish_mode_threads",
                "value": f"={{{{ {wh}?.publish_mode_threads || 'carousel' }}}}",
                "type": "string",
            })

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
                "command": '=/usr/bin/env bash -lc "curl -fsS -X POST \"https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage\" -d \"chat_id=${TELEGRAM_CHAT_ID}\" -d \"text=Run {{ $(\'Set run context\').item.json.run_id }} rejected (TTL or abort).\""',
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

    # stage2 revise: Rerun render -> Save -> Schedule Gateway -> Wait (Gateway-exclusive preview)
    if "Save wait resume URL (stage2)" not in nodes:
        data["nodes"].append({
            "parameters": {"mode": "runOnceForEachItem", "jsCode": SAVE_JS_V2},
            "id": f"save-resume-v2-{nid()}",
            "name": "Save wait resume URL (stage2)",
            "type": "n8n-nodes-base.code",
            "typeVersion": 2,
            "position": [6060, 120],
        })
    if "Schedule Gateway prereview (stage2)" not in nodes:
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
                "jsonBody": '={{ JSON.stringify({ run_id: $("Set run context").item.json.run_id, execution_id: String($execution.id), stage: "v2" }) }}',
                "options": {"timeout": 3000},
            },
            "id": f"sched-gw-v2-{nid()}",
            "name": "Schedule Gateway prereview (stage2)",
            "type": "n8n-nodes-base.httpRequest",
            "typeVersion": 4.2,
            "position": [6280, 120],
        })

    nodes = {n["name"]: n for n in data["nodes"]}
    conn["Rerun render PNG"] = {"main": [[
        {"node": "Save wait resume URL (stage2)", "type": "main", "index": 0}
    ]]}
    conn["Save wait resume URL (stage2)"] = {"main": [[
        {"node": "Schedule Gateway prereview (stage2)", "type": "main", "index": 0}
    ]]}
    conn["Schedule Gateway prereview (stage2)"] = {"main": [[
        {"node": "Wait for approval (stage2)", "type": "main", "index": 0}
    ]]}

    # B-prime publish path: read post.md after approve (legacy Read post.md not on main line)
    if "Read post.md (publish)" not in nodes:
        data["nodes"].append({
            "parameters": {
                "fileSelector": "=/data/runs/{{ $('Set run context').item.json.run_id }}/post.md",
                "options": {},
            },
            "id": f"read-md-publish-{nid()}",
            "name": "Read post.md (publish)",
            "type": "n8n-nodes-base.readWriteFile",
            "typeVersion": 1,
            "position": [2680, 140],
        })
    nodes = {n["name"]: n for n in data["nodes"]}
    for n in data["nodes"]:
        if n.get("type") == "n8n-nodes-base.httpRequest":
            params = n.get("parameters") or {}
            for bp in (params.get("bodyParameters") or {}).get("parameters") or []:
                if bp.get("value") == "={{ $('Read post.md').item.json.data }}":
                    bp["value"] = "={{ $('Read post.md (publish)').item.json.data }}"
            if params.get("bodyParameters", {}).get("parameters"):
                for bp in params["bodyParameters"]["parameters"]:
                    if "Read post.md').item.json.data" in str(bp.get("value", "")):
                        bp["value"] = str(bp["value"]).replace(
                            "$('Read post.md')", "$('Read post.md (publish)')"
                        )
    for audit in ("Audit human decision v1", "Audit human decision v2"):
        conn[audit] = {"main": [[{"node": "Read post.md (publish)", "type": "main", "index": 0}]]}
    # Pre-HITL: copywriter → sync carousel N → generate carousel images
    ensure_execute_node(data, "Write TASK.md", WRITE_TASK_CMD, [660, 0])
    ensure_execute_node(data, "Sync carousel total", SYNC_CAROUSEL_CMD, [1000, 0])
    ensure_execute_node(data, "Sync carousel total (revision)", SYNC_CAROUSEL_CMD, [5080, 320])

    data["nodes"] = [
        n for n in data["nodes"] if n.get("id") not in ("invoke-svg", "invoke-svg-revision")
    ]
    for n in data["nodes"]:
        if n.get("name") == "Invoke image":
            n["name"] = "Invoke carousel images"
            n["parameters"] = {"command": CAROUSEL_CMD}
        if n.get("name") == "Invoke image (revision)":
            n["name"] = "Invoke carousel images (revision)"
            n["parameters"] = {"command": CAROUSEL_CMD}

    seen_car, seen_car_rev = False, False
    deduped_car = []
    for n in data["nodes"]:
        nm = n.get("name")
        if nm == "Invoke carousel images":
            if seen_car:
                continue
            seen_car = True
        if nm == "Invoke carousel images (revision)":
            if seen_car_rev:
                continue
            seen_car_rev = True
        deduped_car.append(n)
    data["nodes"] = deduped_car
    if not seen_car:
        ensure_execute_node(data, "Invoke carousel images", CAROUSEL_CMD, [1220, 0])
    if not seen_car_rev:
        ensure_execute_node(data, "Invoke carousel images (revision)", CAROUSEL_CMD, [5300, 400])

    nodes = {n["name"]: n for n in data["nodes"]}
    conn["Write TASK.md"] = {"main": [[{"node": "Invoke copywriter", "type": "main", "index": 0}]]}
    ensure_execute_node(data, "Validate post.md", VALIDATE_POST_CMD, [880, 0])
    conn["Invoke copywriter"] = {"main": [[{"node": "Validate post.md", "type": "main", "index": 0}]]}
    ensure_execute_node(data, "Check platform limits (pre-HITL)", CHECK_LIMITS_PRE_HITL_CMD, [990, 0])
    conn["Validate post.md"] = {"main": [[{"node": "Check platform limits (pre-HITL)", "type": "main", "index": 0}]]}
    ensure_carousel_gate(
        data,
        conn,
        suffix="",
        upstream="Check platform limits (pre-HITL)",
        true_target="Sync carousel total",
        false_target="Hermes content review",
        exec_pos=[1040, 0],
        parse_pos=[1060, 0],
        if_pos=[1080, 0],
    )
    conn["Sync carousel total"] = {"main": [[{"node": "Invoke carousel images", "type": "main", "index": 0}]]}
    ensure_execute_node(data, "Hermes content review", HERMES_CONTENT_REVIEW_CMD, [1340, 0])
    conn["Invoke carousel images"] = {"main": [[
        {"node": "Hermes content review", "type": "main", "index": 0},
    ]]}
    conn["Hermes content review"] = {"main": [[
        {"node": "Save wait resume URL (stage1)", "type": "main", "index": 0},
    ]]}
    if "Merge branches" in conn:
        conn["Merge branches"] = {"main": [[
            {"node": "Save wait resume URL (stage1)", "type": "main", "index": 0},
        ]]}

    # Revision: copywriter → carousel gate → sync/images or skip
    ensure_carousel_gate(
        data,
        conn,
        suffix=" (revision)",
        upstream="Invoke copywriter (revision)",
        true_target="Sync carousel total (revision)",
        false_target="Merge revision branches",
        exec_pos=[5180, 400],
        parse_pos=[5240, 400],
        if_pos=[5300, 400],
    )
    conn["Sync carousel total (revision)"] = {"main": [[
        {"node": "Invoke carousel images (revision)", "type": "main", "index": 0},
    ]]}
    conn["Invoke carousel images (revision)"] = {"main": [[
        {"node": "Merge revision branches", "type": "main", "index": 0},
    ]]}
    sc_rev = conn.get("Switch rerun scope", {}).get("main", [[], [], []])
    if len(sc_rev) >= 3:
        sc_rev[2] = [{"node": "Invoke copywriter (revision)", "type": "main", "index": 0}]
        conn["Switch rerun scope"] = {"main": sc_rev}

    # Publish fan-out: env-gated FB / Threads / IG → merge → finalize
    publish_nodes = {
        "IF META_PAGE_ID": make_if_node("IF META_PAGE_ID", "META_PAGE_ID", [2760, -120], "facebook"),
        "No Op FB (skip)": make_noop("No Op FB (skip)", [2980, -200]),
        "IF THREADS_USER_ID": make_if_node("IF THREADS_USER_ID", "THREADS_USER_ID", [2760, 280], "threads"),
        "No Op Threads (skip)": make_noop("No Op Threads (skip)", [2980, 360]),
        "IF IG_USER_ID": make_if_node("IF IG_USER_ID", "IG_USER_ID", [2760, 480], "instagram"),
        "No Op IG (skip)": make_noop("No Op IG (skip)", [2980, 560]),
        "Merge publish outcomes": {
            "parameters": {"mode": "append", "numberInputs": 3},
            "id": f"merge-publish-{nid()}",
            "name": "Merge publish outcomes",
            "type": "n8n-nodes-base.merge",
            "typeVersion": 3.2,
            "position": [3200, 200],
        },
    }
    for pname, pnode in publish_nodes.items():
        if pname not in nodes:
            data["nodes"].append(pnode)

    publish_if_specs = {
        "IF META_PAGE_ID": ("META_PAGE_ID", "facebook", [2760, -120]),
        "IF THREADS_USER_ID": ("THREADS_USER_ID", "threads", [2760, 280]),
        "IF IG_USER_ID": ("IG_USER_ID", "instagram", [2760, 480]),
    }
    for n in data["nodes"]:
        spec = publish_if_specs.get(n.get("name", ""))
        if spec:
            env_var, platform, pos = spec
            n["parameters"] = make_if_node(n["name"], env_var, pos, platform)["parameters"]

    for n in data["nodes"]:
        if n.get("name") == "Upload image to catbox":
            n["name"] = "Upload carousel catbox"
            n["parameters"] = {"command": UPLOAD_CATBOX_CMD}
    ensure_execute_node(data, "Upload carousel catbox", UPLOAD_CATBOX_CMD, [2640, 280])
    # Drop duplicate upload node names (keep first)
    seen_upload = False
    deduped = []
    for n in data["nodes"]:
        if n.get("name") == "Upload carousel catbox":
            if seen_upload:
                continue
            seen_upload = True
        deduped.append(n)
    data["nodes"] = deduped
    conn.pop("Upload image to catbox", None)
    conn.pop("Invoke image", None)
    conn.pop("Invoke image (revision)", None)

    if "Publish Facebook" not in nodes:
        data["nodes"].append({
            "parameters": {"command": PUBLISH_FB_CMD},
            "id": f"publish-fb-{nid()}",
            "name": "Publish Facebook",
            "type": "n8n-nodes-base.executeCommand",
            "typeVersion": 1,
            "position": [2980, -120],
        })
    if "Publish Threads chain" not in nodes:
        data["nodes"].append({
            "parameters": {"command": PUBLISH_THREADS_CMD},
            "id": f"publish-threads-{nid()}",
            "name": "Publish Threads chain",
            "type": "n8n-nodes-base.executeCommand",
            "typeVersion": 1,
            "position": [2980, 280],
        })
    if "Publish IG carousel" not in nodes:
        data["nodes"].append({
            "parameters": {"command": PUBLISH_IG_CMD},
            "id": f"publish-ig-{nid()}",
            "name": "Publish IG carousel",
            "type": "n8n-nodes-base.executeCommand",
            "typeVersion": 1,
            "position": [2980, 480],
        })
    if "Finalize publish gate" not in nodes:
        data["nodes"].append({
            "parameters": {"command": FINALIZE_GATE_CMD},
            "id": f"finalize-gate-{nid()}",
            "name": "Finalize publish gate",
            "type": "n8n-nodes-base.executeCommand",
            "typeVersion": 1,
            "position": [3420, 200],
        })

    ensure_execute_node(data, "Check platform limits (pre-publish)", CHECK_LIMITS_PRE_PUBLISH_CMD, [2580, 280])

    nodes = {n["name"]: n for n in data["nodes"]}
    conn["Read post.md (publish)"] = {"main": [[
        {"node": "Check platform limits (pre-publish)", "type": "main", "index": 0},
    ]]}
    conn["Check platform limits (pre-publish)"] = {"main": [[
        {"node": "IF META_PAGE_ID", "type": "main", "index": 0},
        {"node": "Upload carousel catbox", "type": "main", "index": 0},
    ]]}
    conn["IF META_PAGE_ID"] = {"main": [
        [{"node": "Publish Facebook", "type": "main", "index": 0}],
        [{"node": "No Op FB (skip)", "type": "main", "index": 0}],
    ]}
    conn["Publish Facebook"] = {"main": [[
        {"node": "Merge publish outcomes", "type": "main", "index": 0},
    ]]}
    for n in data["nodes"]:
        if n.get("name") == "Meta Graph API publish":
            n["disabled"] = True
    conn["No Op FB (skip)"] = {"main": [[
        {"node": "Merge publish outcomes", "type": "main", "index": 0},
    ]]}
    conn["Upload carousel catbox"] = {"main": [[
        {"node": "IF THREADS_USER_ID", "type": "main", "index": 0},
        {"node": "IF IG_USER_ID", "type": "main", "index": 0},
    ]]}
    conn["IF THREADS_USER_ID"] = {"main": [
        [{"node": "Publish Threads chain", "type": "main", "index": 0}],
        [{"node": "No Op Threads (skip)", "type": "main", "index": 0}],
    ]}
    conn["IF IG_USER_ID"] = {"main": [
        [{"node": "Publish IG carousel", "type": "main", "index": 0}],
        [{"node": "No Op IG (skip)", "type": "main", "index": 0}],
    ]}
    conn["Publish Threads chain"] = {"main": [[
        {"node": "Merge publish outcomes", "type": "main", "index": 1},
    ]]}
    conn["No Op Threads (skip)"] = {"main": [[
        {"node": "Merge publish outcomes", "type": "main", "index": 1},
    ]]}
    conn["Publish IG carousel"] = {"main": [[
        {"node": "Merge publish outcomes", "type": "main", "index": 2},
    ]]}
    conn["No Op IG (skip)"] = {"main": [[
        {"node": "Merge publish outcomes", "type": "main", "index": 2},
    ]]}
    conn["Merge publish outcomes"] = {"main": [[
        {"node": "Finalize publish gate", "type": "main", "index": 0},
    ]]}
    conn["Finalize publish gate"] = {
        "main": [[{"node": "Finalize review summary (success)", "type": "main", "index": 0}]],
    }
    for n in data["nodes"]:
        if n.get("name") == "Finalize publish gate":
            n["onError"] = "continueErrorOutput"
    conn.setdefault("Finalize publish gate", {})["error"] = [[
        {"node": "Finalize review summary (fail)", "type": "main", "index": 0},
    ]]

    for n in data["nodes"]:
        if n.get("name") == "Publish Facebook":
            n["parameters"] = {"command": PUBLISH_FB_CMD}
            n.pop("continueOnFail", None)
        if n.get("name") == "Publish Threads chain":
            n["parameters"] = {"command": PUBLISH_THREADS_CMD}
            n.pop("continueOnFail", None)
        if n.get("name") == "Publish IG carousel":
            n["parameters"] = {"command": PUBLISH_IG_CMD}
            n.pop("continueOnFail", None)
        if n.get("name") == "Check platform limits (pre-HITL)":
            n["parameters"] = {"command": CHECK_LIMITS_PRE_HITL_CMD}
            n.pop("continueOnFail", None)
        if n.get("name") == "Check platform limits (pre-publish)":
            n["parameters"] = {"command": CHECK_LIMITS_PRE_PUBLISH_CMD}
            n.pop("continueOnFail", None)
        if n.get("name") == "Finalize publish gate":
            n["parameters"] = {"command": FINALIZE_GATE_CMD}
            n.pop("continueOnFail", None)
        if n.get("name") == "Meta Graph API publish":
            n["disabled"] = True
            n.pop("continueOnFail", None)
        if n.get("name") in (
            "Prepare Threads publish",
            "Threads create container",
            "Threads publish",
            "Render PNG",
        ):
            n["disabled"] = True
        if n.get("name") in ("Invoke svg artist", "Invoke image") and n.get("id") not in (
            "invoke-svg",
            "invoke-svg-revision",
        ):
            n["name"] = "Invoke carousel images"
            n["parameters"] = {"command": CAROUSEL_CMD}
        if n.get("name") in ("Invoke svg artist (revision)", "Invoke image (revision)") and n.get(
            "id"
        ) not in ("invoke-svg-revision",):
            n["name"] = "Invoke carousel images (revision)"
            n["parameters"] = {"command": CAROUSEL_CMD}
        if n.get("name") == "Finalize review summary (success)":
            n["parameters"] = {"command": "=echo publish gate already finalized"}
        if n.get("name") == "Finalize review summary (fail)":
            n["parameters"] = {
                "command": (
                    f"=/bin/bash /data/scripts/finalize_review_summary.sh --run-id "
                    f"\"{RUN_ID_EXPR}\" --publish-status fail "
                    "--publish-targets 'facebook,threads,instagram'"
                ),
            }
    for n in data["nodes"]:
        if n.get("name") == "Meta Graph API publish":
            for bp in (n.get("parameters") or {}).get("bodyParameters", {}).get("parameters") or []:
                if bp.get("name") == "message":
                    bp["value"] = "={{ $json.data }}"

    # Gateway-exclusive: disable n8n Telegram sendPhoto nodes (preview via hermes_telegram_gateway.py)
    for n in data["nodes"]:
        if n.get("name") in TELEGRAM_PREVIEW_NODES:
            n["disabled"] = True

    # Feedback Wait: save dynamic resume URL before pausing (n8n 2.21 requires GET $execution.resumeUrl)
    if "Save wait resume URL (feedback-v1)" not in nodes:
        data["nodes"].append({
            "parameters": {"mode": "runOnceForEachItem", "jsCode": SAVE_JS_FEEDBACK},
            "id": f"save-resume-feedback-{nid()}",
            "name": "Save wait resume URL (feedback-v1)",
            "type": "n8n-nodes-base.code",
            "typeVersion": 2,
            "position": [2980, 320],
        })
    nodes = {n["name"]: n for n in data["nodes"]}
    for n in data["nodes"]:
        if n.get("name") == "Set feedback text":
            for a in n["parameters"]["assignments"]["assignments"]:
                if a.get("name") == "feedback_text":
                    a["value"] = FEEDBACK_TEXT_EXPR
    conn["Save HITL reply map"] = {"main": [[
        {"node": "Save wait resume URL (feedback-v1)", "type": "main", "index": 0}
    ]]}
    conn["Save wait resume URL (feedback-v1)"] = {"main": [[
        {"node": "Wait for feedback", "type": "main", "index": 0}
    ]]}


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
        if n["name"].startswith("Resume Wait feedback"):
            n["parameters"] = {
                "method": "GET",
                "url": "={{ $json.resume_url }}",
                "options": {},
            }

    names = {n["name"] for n in data["nodes"]}
    if "Read feedback resume map" not in names:
        data["nodes"].append({
            "parameters": {
                "command": (
                    "=/bin/bash /data/scripts/read_hitl_resume_map.sh "
                    "--run-id \"{{ $('Merge feedback payload').item.json.run_id }}\" "
                    "--stage feedback-v1"
                ),
            },
            "id": f"read-fb-resume-{nid()}",
            "name": "Read feedback resume map",
            "type": "n8n-nodes-base.executeCommand",
            "typeVersion": 1,
            "position": [1080, 160],
        })
        data["nodes"].append({
            "parameters": {"mode": "runOnceForEachItem", "jsCode": PARSE_FEEDBACK_RESUME_JS},
            "id": f"parse-fb-resume-{nid()}",
            "name": "Parse feedback resume map",
            "type": "n8n-nodes-base.code",
            "typeVersion": 2,
            "position": [1320, 160],
        })

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
    conn["Merge feedback payload"] = {"main": [[
        {"node": "Read feedback resume map", "type": "main", "index": 0}
    ]]}
    conn["Read feedback resume map"] = {"main": [[
        {"node": "Parse feedback resume map", "type": "main", "index": 0}
    ]]}
    conn["Parse feedback resume map"] = {"main": [[
        {"node": "Resume Wait feedback-v1", "type": "main", "index": 0}
    ]]}


def main() -> None:
    for path, patcher in ((HAPPY, patch_happy), (FWD, patch_forwarder)):
        data = json.loads(path.read_text(encoding="utf-8"))
        patcher(data)
        path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        print(f"Patched {path.name}")


if __name__ == "__main__":
    main()
