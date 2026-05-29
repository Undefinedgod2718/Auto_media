#!/usr/bin/env python3
"""Patch auto-media-happy-path.json with HITL inline keyboard + reject feedback flow."""
from __future__ import annotations

import json
from copy import deepcopy
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
TARGETS = [
    REPO / "workflows" / "auto-media-happy-path.json",
    REPO / "workflows" / "wf-patched.json",
]

RUN_CTX = "$('Set run context').item.json.run_id"
READ_MD = "$('Read post.md').item.json.data"

CALLBACK_EXPR = "={{ $json.body?.callback || $json.query?.callback || $json.callback }}"


def inline_keyboard_v1() -> dict:
    return {
        "replyMarkup": "inlineKeyboard",
        "inlineKeyboard": {
            "rows": [
                {
                    "row": {
                        "buttons": [
                            {
                                "text": "✅ 核准",
                                "additionalFields": {
                                    "callback_data": (
                                        "={{ 'am:v1:approve:' + "
                                        + RUN_CTX
                                        + " }}"
                                    ),
                                },
                            },
                            {
                                "text": "❌ 拒絕",
                                "additionalFields": {
                                    "callback_data": (
                                        "={{ 'am:v1:reject:' + "
                                        + RUN_CTX
                                        + " }}"
                                    ),
                                },
                            },
                        ]
                    }
                }
            ]
        },
    }


def inline_keyboard_v2() -> dict:
    return {
        "replyMarkup": "inlineKeyboard",
        "inlineKeyboard": {
            "rows": [
                {
                    "row": {
                        "buttons": [
                            {
                                "text": "✅ 核准發文",
                                "additionalFields": {
                                    "callback_data": (
                                        "={{ 'am:v2:approve:' + "
                                        + RUN_CTX
                                        + " }}"
                                    ),
                                },
                            },
                        ]
                    }
                }
            ]
        },
    }


def switch_callback(
    node_id: str, name: str, position: list[int], *, approve_only: bool
) -> dict:
    rules = [
        {
            "conditions": {
                "options": {
                    "caseSensitive": True,
                    "leftValue": "",
                    "typeValidation": "strict",
                },
                "conditions": [
                    {
                        "leftValue": CALLBACK_EXPR,
                        "rightValue": "approve",
                        "operator": {"type": "string", "operation": "equals"},
                    }
                ],
                "combinator": "and",
            },
            "renameOutput": True,
            "outputKey": "approve",
        }
    ]
    if not approve_only:
        rules.append(
            {
                "conditions": {
                    "options": {
                        "caseSensitive": True,
                        "leftValue": "",
                        "typeValidation": "strict",
                    },
                    "conditions": [
                        {
                            "leftValue": CALLBACK_EXPR,
                            "rightValue": "reject",
                            "operator": {"type": "string", "operation": "equals"},
                        }
                    ],
                    "combinator": "and",
                },
                "renameOutput": True,
                "outputKey": "reject",
            }
        )
    return {
        "parameters": {
            "rules": {"values": rules},
            "options": {"fallbackOutput": "extra"},
        },
        "id": node_id,
        "name": name,
        "type": "n8n-nodes-base.switch",
        "typeVersion": 3.2,
        "position": position,
    }


def wait_node(node_id: str, name: str, webhook_id: str, position: list[int]) -> dict:
    return {
        "parameters": {"resume": "webhook", "options": {}},
        "id": node_id,
        "name": name,
        "type": "n8n-nodes-base.wait",
        "typeVersion": 1.1,
        "position": position,
        "webhookId": webhook_id,
    }


def exec_node(node_id: str, name: str, command: str, position: list[int]) -> dict:
    return {
        "parameters": {"command": command},
        "id": node_id,
        "name": name,
        "type": "n8n-nodes-base.executeCommand",
        "typeVersion": 1,
        "position": position,
    }


def telegram_send_photo(
    node_id: str, name: str, position: list[int], keyboard: dict, caption: str
) -> dict:
    return {
        "parameters": {
            "operation": "sendPhoto",
            "chatId": "={{ $env.TELEGRAM_CHAT_ID }}",
            "binaryData": True,
            **keyboard,
            "additionalFields": {"caption": caption},
        },
        "id": node_id,
        "name": name,
        "type": "n8n-nodes-base.telegram",
        "typeVersion": 1.2,
        "position": position,
        "credentials": {
            "telegramApi": {"id": "CONFIGURE_ME", "name": "Telegram account"}
        },
    }


def telegram_send_message_force_reply(
    node_id: str, name: str, position: list[int], text: str
) -> dict:
    return {
        "parameters": {
            "operation": "sendMessage",
            "chatId": "={{ $env.TELEGRAM_CHAT_ID }}",
            "text": text,
            "replyMarkup": "forceReply",
            "forceReply": {
                "force_reply": True,
                "input_field_placeholder": "請輸入修正意見（僅一輪）",
            },
            "additionalFields": {},
        },
        "id": node_id,
        "name": name,
        "type": "n8n-nodes-base.telegram",
        "typeVersion": 1.2,
        "position": position,
        "credentials": {
            "telegramApi": {"id": "CONFIGURE_ME", "name": "Telegram account"}
        },
    }


def patch_workflow(wf: dict) -> dict:
    wf = deepcopy(wf)
    by_id = {n["id"]: n for n in wf["nodes"]}

    preview = by_id["telegram-preview"]
    preview["parameters"] = {
        **preview["parameters"],
        **inline_keyboard_v1(),
        "additionalFields": {
            "caption": preview["parameters"]["additionalFields"]["caption"],
        },
    }

    by_id["wait-approval"]["webhookId"] = "auto-media-hitl-v1"
    by_id["wait-approval"]["name"] = "Wait for approval (stage1)"

    by_id["switch-callback"] = switch_callback(
        "switch-callback",
        "Switch callback (stage1)",
        [2200, 0],
        approve_only=False,
    )

    extra = [
        telegram_send_message_force_reply(
            "telegram-feedback-prompt",
            "Telegram request feedback",
            [2420, 200],
            "=請回覆此訊息，說明要修改的文案方向（不會重跑 SVG，只重寫文案並重新合成 PNG）。",
        ),
        exec_node(
            "save-hitl-reply-map",
            "Save HITL reply map",
            (
                "=mkdir -p /data/hitl/reply_map && /bin/bash /data/scripts/write_hitl_reply_map.sh "
                '--message-id "{{ $json.result?.message_id || $json.message_id }}" '
                f'--run-id "{{{{ {RUN_CTX} }}}}" --stage v1'
            ),
            [2640, 200],
        ),
        wait_node("wait-feedback", "Wait for feedback", "auto-media-feedback-v1", [2860, 200]),
        {
            "parameters": {
                "operation": "write",
                "fileName": f"=/data/hitl/feedback/{{{{ {RUN_CTX} }}}}.txt",
                "dataPropertyName": "feedback_text",
                "options": {},
            },
            "id": "write-feedback-file",
            "name": "Write feedback file",
            "type": "n8n-nodes-base.readWriteFile",
            "typeVersion": 1,
            "position": [3080, 200],
        },
        {
            "parameters": {
                "mode": "manual",
                "duplicateItem": False,
                "assignments": {
                    "assignments": [
                        {
                            "id": "feedback_text",
                            "name": "feedback_text",
                            "value": "={{ $json.body?.feedback_text || $json.feedback_text || '' }}",
                            "type": "string",
                        }
                    ]
                },
                "options": {},
            },
            "id": "set-feedback-text",
            "name": "Set feedback text",
            "type": "n8n-nodes-base.set",
            "typeVersion": 3.4,
            "position": [2970, 200],
        },
        exec_node(
            "apply-feedback-task",
            "Apply feedback to TASK.md",
            (
                f"=/bin/bash /data/scripts/apply_feedback_task.sh --run-id \"{{{{ {RUN_CTX} }}}}\" "
                f'--feedback-file "/data/hitl/feedback/{{{{ {RUN_CTX} }}}}.txt"'
            ),
            [3190, 200],
        ),
        exec_node(
            "rerun-copywriter",
            "Rerun copywriter",
            f"=/bin/bash /data/scripts/generate_copy.sh --run-id \"{{{{ {RUN_CTX} }}}}\"",
            [3300, 200],
        ),
        exec_node(
            "rerun-render-png",
            "Rerun render PNG",
            f"=/bin/bash /data/scripts/render_png.sh --run-id \"{{{{ {RUN_CTX} }}}}\"",
            [3520, 200],
        ),
        {
            "parameters": {
                "fileSelector": f"=/data/runs/{{{{ {RUN_CTX} }}}}/post.png",
                "options": {},
            },
            "id": "read-png-stage2",
            "name": "Read post.png (stage2)",
            "type": "n8n-nodes-base.readWriteFile",
            "typeVersion": 1,
            "position": [3740, 160],
        },
        {
            "parameters": {
                "fileSelector": f"=/data/runs/{{{{ {RUN_CTX} }}}}/post.md",
                "options": {},
            },
            "id": "read-md-stage2",
            "name": "Read post.md (stage2)",
            "type": "n8n-nodes-base.readWriteFile",
            "typeVersion": 1,
            "position": [3740, 240],
        },
        telegram_send_photo(
            "telegram-preview-stage2",
            "Telegram HITL preview (stage2)",
            [3960, 200],
            inline_keyboard_v2(),
            "=（第 2 輪預覽）\n={{ $('Read post.md (stage2)').item.json.data }}",
        ),
        wait_node(
            "wait-approval-stage2",
            "Wait for approval (stage2)",
            "auto-media-hitl-v2",
            [4180, 200],
        ),
        switch_callback(
            "switch-callback-stage2",
            "Switch callback (stage2)",
            [4400, 200],
            approve_only=True,
        ),
    ]
    for n in extra:
        by_id[n["id"]] = n

    wf["nodes"] = list(by_id.values())

    conn: dict = {}

    def link(src: str, *targets: dict) -> None:
        conn.setdefault(src, {"main": [[]]})
        conn[src]["main"][0].extend(targets)

    def link_outputs(src: str, outputs: list[list[dict]]) -> None:
        conn[src] = {"main": outputs}

    link_outputs(
        "Switch callback (stage1)",
        [
            [
                {"node": "Meta Graph API publish", "type": "main", "index": 0},
                {"node": "Upload image to catbox", "type": "main", "index": 0},
            ],
            [{"node": "Telegram request feedback", "type": "main", "index": 0}],
            [],
        ],
    )
    link_outputs(
        "Switch callback (stage2)",
        [
            [
                {"node": "Meta Graph API publish", "type": "main", "index": 0},
                {"node": "Upload image to catbox", "type": "main", "index": 0},
            ],
            [],
        ],
    )

    link_outputs("Telegram HITL preview", [{"node": "Wait for approval (stage1)", "type": "main", "index": 0}])
    link_outputs("Wait for approval (stage1)", [{"node": "Switch callback (stage1)", "type": "main", "index": 0}])
    link_outputs("Telegram request feedback", [{"node": "Save HITL reply map", "type": "main", "index": 0}])
    link_outputs("Save HITL reply map", [{"node": "Wait for feedback", "type": "main", "index": 0}])
    link_outputs("Wait for feedback", [{"node": "Set feedback text", "type": "main", "index": 0}])
    link_outputs("Set feedback text", [{"node": "Write feedback file", "type": "main", "index": 0}])
    link_outputs("Write feedback file", [{"node": "Apply feedback to TASK.md", "type": "main", "index": 0}])
    link_outputs("Apply feedback to TASK.md", [{"node": "Rerun copywriter", "type": "main", "index": 0}])
    link_outputs("Rerun copywriter", [{"node": "Rerun render PNG", "type": "main", "index": 0}])
    link_outputs(
        "Rerun render PNG",
        [
            {"node": "Read post.png (stage2)", "type": "main", "index": 0},
            {"node": "Read post.md (stage2)", "type": "main", "index": 0},
        ],
    )
    link_outputs(
        "Telegram HITL preview (stage2)",
        [{"node": "Wait for approval (stage2)", "type": "main", "index": 0}],
    )
    link_outputs(
        "Wait for approval (stage2)",
        [{"node": "Switch callback (stage2)", "type": "main", "index": 0}],
    )

    link_outputs(
        "Read post.png",
        [{"node": "Telegram HITL preview", "type": "main", "index": 0}],
    )
    link_outputs(
        "Read post.md",
        [{"node": "Telegram HITL preview", "type": "main", "index": 0}],
    )
    link_outputs(
        "Read post.png (stage2)",
        [{"node": "Telegram HITL preview (stage2)", "type": "main", "index": 0}],
    )
    link_outputs(
        "Read post.md (stage2)",
        [{"node": "Telegram HITL preview (stage2)", "type": "main", "index": 0}],
    )

    preserved = {
        "Schedule Trigger": [["Load platform.runtime.json"]],
        "Load platform.runtime.json": [["Set run context"]],
        "Set run context": [["Write TASK.md"]],
        "Write TASK.md": [["Invoke copywriter", "Invoke svg artist"]],
        "Invoke copywriter": [["Merge branches"]],
        "Invoke svg artist": [["Merge branches"]],
        "Merge branches": [["Render PNG"]],
        "Render PNG": [["Read post.png", "Read post.md"]],
        "Upload image to catbox": [["Threads create container"]],
        "Threads create container": [["Threads publish"]],
        "Meta Graph API publish": [[], ["Write api_dead.json"]],
    }

    name_to_node = {n["name"]: n["name"] for n in wf["nodes"]}
    for src, outs in preserved.items():
        if src in ("Read post.png", "Read post.md"):
            continue
        built: list[list[dict]] = []
        row: list[dict] = []
        for target in outs[0]:
            if isinstance(target, str):
                row.append({"node": target, "type": "main", "index": 0})
        if row:
            built.append(row)
        if len(outs) > 1 and outs[1]:
            err_row = [{"node": outs[1][0], "type": "main", "index": 0}]
            built.append(err_row)
        conn[src] = {"main": built}

    wf["connections"] = conn
    return wf


def main() -> None:
    for path in TARGETS:
        wf = json.loads(path.read_text(encoding="utf-8"))
        patched = patch_workflow(wf)
        path.write_text(
            json.dumps(patched, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        print(f"Patched {path}")


if __name__ == "__main__":
    main()
