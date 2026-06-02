# n8n 產線設定手冊（非工程師）

在 **n8n 網頁介面** 建立自動發文流程，無需匯入 JSON 檔。

---

## PR-0：Wait 語意探測（所有 HITL 工作的前置條件）

> **PR-0 必須在建立主流程之前完成。** Wait 節點若不能真正暫停執行，整個 HITL 架構就不成立。本節告訴你怎麼用 `verify-wait-probe` workflow 取得 Q1–Q4 四個地基性答案。

### 建立 n8n API Key

1. n8n UI 右上角頭像 → **Settings** → **n8n API** → **Create an API key**。
2. 複製金鑰，儲存到 `.env`：
   ```
   N8N_API_KEY=<your_key>
   ```
3. 驗證：
   ```bash
   curl -s -H "X-N8N-API-KEY: $N8N_API_KEY" \
     http://localhost:5678/api/v1/workflows | jq '.data | length'
   ```
   期望：回傳數字（≥0），不是 401。

### 匯入並啟用 verify-wait-probe

1. n8n UI → **Workflows** → **Import from file**。
2. 選 `workflows/verify-wait-probe.json`。
3. 匯入後確認 workflow 名稱為 `verify-wait-probe`。
4. 右上角開關 → **Active**（必須 Active 才能接 webhook，不要只按 Execute）。

### 執行探測

探測分兩個 curl：第一個觸發並取得 execution_id，第二個 resume 並觀察。

**Step A — 觸發（在 devcontainer / Linux shell）：**

```bash
PROBE_ID="pr0-$(date +%s)"

# 觸發 webhook，立即返回（不等）
TRIGGER_RESP=$(curl -s -X POST \
  "http://localhost:5678/webhook/verify-wait-probe" \
  -H "Content-Type: application/json" \
  -d "{\"probe_id\": \"${PROBE_ID}\"}")

echo "trigger response: $TRIGGER_RESP"

# 稍等 1 秒讓 n8n 建立 execution
sleep 1

# 取得最新 execution id
EXEC_ID=$(curl -s \
  -H "X-N8N-API-KEY: $N8N_API_KEY" \
  "http://localhost:5678/api/v1/executions?workflowId=verify-wait-probe&limit=1" \
  | jq -r '.data[0].id')

echo "execution_id: $EXEC_ID"

# 查詢狀態（Q1）
STATUS=$(curl -s \
  -H "X-N8N-API-KEY: $N8N_API_KEY" \
  "http://localhost:5678/api/v1/executions/${EXEC_ID}" \
  | jq -r '.data.status')

echo "Q1 status after trigger: $STATUS"
```

**期望 Q1**：`status` 應為 `waiting`（而非 `running` 或 `success`）。

**Step B — Resume（確認 callback 傳遞，Q2/Q3）：**

```bash
# Resume：POST 到靜態 webhook-wait 路徑（Q2 驗證）
RESUME_RESP=$(curl -s -X POST \
  "http://localhost:5678/webhook-wait/verify-wait-probe-wait" \
  -H "Content-Type: application/json" \
  -d "{\"callback\": \"approve\", \"probe_id\": \"${PROBE_ID}\"}")

echo "resume response: $RESUME_RESP"

sleep 1

# 取得完整 execution 資料（Q3）
EXEC_DATA=$(curl -s \
  -H "X-N8N-API-KEY: $N8N_API_KEY" \
  "http://localhost:5678/api/v1/executions/${EXEC_ID}")

FINAL_STATUS=$(echo "$EXEC_DATA" | jq -r '.data.status')
RESUMED=$(echo "$EXEC_DATA" | jq -r '.data.data.resultData.runData["After wait"][0].data.main[0][0].json.resumed // "missing"')
PAYLOAD_CALLBACK=$(echo "$EXEC_DATA" | jq -r '.data.data.resultData.runData["After wait"][0].data.main[0][0].json.payload.body.callback // "missing"')

echo "Q2 resume status: $FINAL_STATUS"
echo "Q3 resumed flag: $RESUMED"
echo "Q3 payload.callback: $PAYLOAD_CALLBACK"
```

**Step C — Timeout（Q4）：**

不 resume，讓 Wait 自行超時（10 秒）：

```bash
PROBE_ID2="pr0-timeout-$(date +%s)"

curl -s -X POST \
  "http://localhost:5678/webhook/verify-wait-probe" \
  -H "Content-Type: application/json" \
  -d "{\"probe_id\": \"${PROBE_ID2}\"}" > /dev/null

echo "Waiting 15 seconds for timeout..."
sleep 15

EXEC_ID2=$(curl -s \
  -H "X-N8N-API-KEY: $N8N_API_KEY" \
  "http://localhost:5678/api/v1/executions?workflowId=verify-wait-probe&limit=1" \
  | jq -r '.data[0].id')

Q4_STATUS=$(curl -s \
  -H "X-N8N-API-KEY: $N8N_API_KEY" \
  "http://localhost:5678/api/v1/executions/${EXEC_ID2}" \
  | jq -r '.data.status')

echo "Q4 timeout status: $Q4_STATUS"
```

### Q1–Q4 判讀表

| 問題 | 欄位 | passed 條件 | passed:false 含義 |
|------|------|------------|-------------------|
| **Q1** `waiting_observed` | Step A 的 `status` | `== "waiting"` | Wait 節點在此 n8n 版本不真正暫停；HITL 前提崩潰，**停止所有後續工作** |
| **Q2** `resume_url_works` | Step B 的 `FINAL_STATUS` | `== "success"` | 靜態 `/webhook-wait/<webhookId>` 路徑失效；需改用 `$execution.resumeUrl` 動態路徑 |
| **Q3** `callback_in_body` | Step B 的 `payload.callback` | `== "approve"` | resume payload 沒有出現在 `$json.body`；Switch callback 條件需調整到 `$json.callback` |
| **Q4** `timeout_fires` | Step C 的 `Q4_STATUS` | `== "success"` | limitWaitTime 無效；TTL 保護不可靠，需另設外部監控 |

> **絕對禁止造假**：`passed:false` 是真實語意，不是測試失敗。它告訴你 1802 行 workflow 哪些假設不成立。若 Q1=false 整個 HITL 設計需重來。

### 把結果填入 n8n_semantics.json

探測完畢後，將四個答案填入專案根目錄的 `n8n_semantics.json`：

```json
{
  "probe_run_id": "<EXEC_ID>",
  "timestamp": "<ISO8601>",
  "Q1_waiting_observed": {
    "question": "執行到 Wait 節點後，execution status 是否變為 waiting？",
    "passed": true,
    "evidence": "status=waiting, exec_id=35"
  },
  "Q2_resume_url_works": {
    "question": "POST /webhook-wait/<webhookId> 能否成功 resume Wait？",
    "passed": true,
    "evidence": "final_status=success after resume",
    "url_used": "http://localhost:5678/webhook-wait/verify-wait-probe-wait"
  },
  "Q3_callback_in_body": {
    "question": "Resume POST payload 是否出現在 Wait 之後的 $json.body？",
    "passed": true,
    "evidence": "payload.body.callback=approve"
  },
  "Q4_timeout_fires": {
    "question": "limitWaitTime=true 時，10 秒後 Wait 是否自動往下走（status=success）？",
    "passed": true,
    "evidence": "status=success after 15s wait"
  }
}
```

---

## 給 PM/營運的簡版流程

這條流程可以理解成「先自動產出，再雙層審查，最後才發佈」：

1. 系統先自動產出貼文文案與圖片。
2. Hermes 先做初審，只提供風險與修正建議，不直接改稿。
3. 人類在 Telegram 做複審，可選：
   - `approve`：同意發佈
   - `revise`：要求修正後再看一次
   - `reject`：退回重做
4. 若選 `revise/reject`，系統會依建議自動修正並再送審（可多輪，避免無限循環）。
5. 只有人類核准後才會發佈到社群平台。
6. 每次審查與決策都會留下紀錄，事後可追溯「誰在何時、基於什麼理由放行或退回」。
7. 若平台發佈失敗，才會啟用備援（Plan B）。

> 重點：Hermes 是「審查輔助」，人類是最終決策者；流程設計目標是降低公關風險並保留完整稽核軌跡。

## Task Runner 重要限制

當 `N8N_RUNNERS_ENABLED=true` 時，Code 節點會在 task runner 子程序執行。若在 Code 節點內用 `spawnSync` 呼叫長時間 CLI（例如 Gemini/Codex），會阻塞事件迴圈，heartbeat 逾時後被判定 unresponsive。

- 長任務（>25 秒）一律使用 **Execute Command**，不要在 Code 節點包 `spawnSync`。
- 本手冊所有 shell 指令節點都使用 **Execute Command**，請照這個做法。
- 若有既有流程仍使用 Code 節點跑長任務，才考慮調整 `N8N_RUNNERS_HEARTBEAT_INTERVAL`（不建議當主解法）。

## 前置準備

1. 確認 Docker Desktop 正在執行。
2. 在專案資料夾複製設定檔：`cp .env.example .env`，並填入：
  - `N8N_ENCRYPTION_KEY`（至少 32 字元隨機字串）
  - `TELEGRAM_BOT_TOKEN`、`TELEGRAM_CHAT_ID`
  - `META_PAGE_ID`、`META_PAGE_ACCESS_TOKEN`（若要自動發 Facebook）
3. 啟動 n8n（由技術人員或 Dev Container 內執行一次即可）：

```bash
docker compose up -d
```

1. 瀏覽器開啟：**[http://localhost:5678](http://localhost:5678)**，完成 n8n 首次帳號設定。

---

## 建立 Workflow

1. 左側 **Workflows** → **Add workflow**。
2. 右上角將名稱改為：`auto-media-happy-path`。
3. 依下列順序新增節點並連線（由左到右）。

> **第一次測試建議**：可將「Schedule Trigger」改為 **Manual Trigger**（手動執行），確認流程正常後再改回每 24 小時排程。

### 流程總覽

```text
Schedule → Load runtime（可選）→ Set 變數 → Write TASK
    → Invoke 文案 + Invoke image（平行，直接 post.png）
    → 讀 PNG + 讀 MD → Telegram 預覽 → 等待審核 → 分支
    → 核准 → Meta 發文；失敗 → 寫 api_dead.json
```

---

## 節點 1：Schedule Trigger（排程）

- 搜尋節點：**Schedule Trigger**
- 設定：**Every 24 hours**（或依需求調整）

測試時可改用 **Manual Trigger**，連到下一節點即可。

---

## 節點 2：Load platform.runtime.json（可選）

- 節點類型：**Execute Command**
- 名稱：`Load platform.runtime.json`
- Command：

```text
cat /data/config/platform.runtime.json
```

僅用於確認設定檔存在；若不需要可刪除此節點，讓 Schedule 直接連到「Set run context」。

---

## 節點 3：Set run context（設定本次執行）

- 節點類型：**Edit Fields (Set)**
- 名稱：`Set run context`
- 新增三個欄位（Mode: Manual Mapping）：


| 欄位名        | 類型     | 值                                                                 |
| ---------- | ------ | ----------------------------------------------------------------- |
| `run_id`   | String | `={{ $('Webhook Run').item.json.body?.run_id \|\| $now.format('yyyyMMdd-HHmmss') + '-' + $execution.id }}` |
| `topic`    | String | `={{ $('Webhook Run').item.json.body?.topic \|\| 'AI 發展趨勢' }}` |
| `audience` | String | `={{ $('Webhook Run').item.json.body?.audience \|\| '25-35 歲科技愛好者' }}` |

上游為 `Load platform.runtime.json` 時，不可使用 `$json.body`（會拿不到 Gateway 傳入的 `run_id`/`topic`）。


---

## 節點 4：Write TASK.md

- 節點類型：**Execute Command**
- 名稱：`Write TASK.md`
- Command（整段貼上，保留 `{{ }}` 表達式）：

```bash
mkdir -p /data/runs/{{ $json.run_id }} && /bin/bash /data/scripts/write_task.sh --run-id "{{ $json.run_id }}" --topic "{{ $json.topic }}" --audience "{{ $json.audience }}" --action generate_copy
```

連線：**Set run context** → **Write TASK.md**

---

## 節點 5–6：Invoke copywriter / Invoke svg artist（平行）

從 **Write TASK.md** 拉出 **兩條線** 到下面兩個節點（同時執行）。

### 5a. Invoke copywriter

- 節點類型：**Execute Command**
- Command：

```bash
/bin/bash /data/scripts/invoke-engine.sh --run-id "{{ $('Set run context').item.json.run_id }}" --engine copywriter
```

### 5b. Invoke svg artist

- 節點類型：**Execute Command**
- Command：

```bash
/bin/bash /data/scripts/invoke-engine.sh --run-id "{{ $('Set run context').item.json.run_id }}" --engine svg_artist
```

> 兩者都需連到下一節點 **Render PNG**（n8n 會等兩邊都完成再往下）。

---

## 節點 7：Render PNG

- 節點類型：**Execute Command**
- Command：

```bash
/bin/bash /data/scripts/render_png.sh --run-id "{{ $('Set run context').item.json.run_id }}"
```

連線：**Invoke copywriter**、**Invoke svg artist** → **Render PNG**

---

## 節點 8–9：讀取產出檔

從 **Render PNG** 拉出兩條線。

### 8. Read post.png

- 節點類型：**Read/Write Files from Disk**
- Operation：Read File(s) From Disk
- File(s) Selector：

```text
/data/runs/{{ $('Set run context').item.json.run_id }}/post.png
```

### 9. Read post.md

- 同上，路徑改為：

```text
/data/runs/{{ $('Set run context').item.json.run_id }}/post.md
```

---

## 節點 10：Telegram HITL preview

- 節點類型：**Telegram**
- Operation：**Send Photo**
- Chat ID：`={{ $env.TELEGRAM_CHAT_ID }}`
- 勾選使用上一節點的二進位（圖片）
- **Reply Markup**（頂層欄位，勿放在 Additional Fields）：**Inline Keyboard**，並設定三顆按鈕的 `callback_data`（見下表）
- Caption（說明文字）：

```text
={{ $('Read post.md').item.json.data }}
```

**憑證**：在節點上建立 **Telegram API** credential，填入 Bot Token（與 `.env` 的 `TELEGRAM_BOT_TOKEN` 相同）。

連線（含 Hermes 初審時）：**Render PNG** → **Read post.png** / **Read post.md** → **Merge review inputs** → Hermes 鏈 → **Set review caption** → **Attach preview binary** → **Telegram HITL preview**

> **Attach preview binary**（Code）會從 `$('Read post.png')` 取回 `binary.data`，因為 Hermes / Set 節點只傳 JSON，無法直接餵給 `sendPhoto`。

---

## 節點 11：Wait for approval（stage1）

- 節點類型：**Wait**
- Resume：**On Webhook Call**
- **Webhook ID**：`auto-media-hitl-v1`（與 forwarder 對應）
- 由 **`auto-media-hitl-forwarder`** workflow 在按鈕點擊後 POST 恢復，不需手動呼叫。

---

## 節點 12：Switch callback（stage1）

- 節點類型：**Switch**
- **approve** → 寫入人審 audit 後進 Meta / Threads 發文
- **revise / reject** → 要求使用者回覆修正意見（Force Reply）→ Hermes 產生修正計畫與 `rerun_scope` → 重跑流程 → stage2 預覽
- **fallback** → 結束（未識別的 callback）

---

## HITL：Telegram inline keyboard + Forwarder（必開第二條 workflow）

主流程 `auto-media-happy-path` 的 **Telegram HITL preview** 需設定 **Inline Keyboard**：

| 按鈕 | callback_data |
|------|----------------|
| ✅ 核准 | `am:v1:approve:<run_id>` |
| 🛠 修正 | `am:v1:revise:<run_id>` |
| ❌ 拒絕 | `am:v1:reject:<run_id>` |

stage2 預覽同樣使用三按鈕（`approve/revise/reject`）：`am:v2:<decision>:<run_id>`。

### 匯入並啟用 Forwarder

1. 匯入 [`workflows/auto-media-hitl-forwarder.json`](../workflows/auto-media-hitl-forwarder.json)。
2. 使用與主流程相同的 **Telegram API** 憑證。
3. **Active** 此 workflow（全專案只能有一個 **Telegram Trigger** 綁定同一 bot）。
4. `.env` 設定公開 URL：`WEBHOOK_URL=https://你的-n8n-網域`（本機開發可用 tunnel）。

Forwarder 會將事件 POST 到 n8n Wait webhook：

| 事件 | Wait Webhook ID |
|------|------------------|
| stage1 三種按鈕（approve/revise/reject） | `auto-media-hitl-v1` |
| stage2 三種按鈕（approve/revise/reject） | `auto-media-hitl-v2` |
| revise/reject 後的修正意見（回覆 Force Reply） | `auto-media-feedback-v1` |

實際 URL 形如：`{WEBHOOK_URL}/webhook-wait/auto-media-hitl-v1`（以 n8n Wait 節點 UI 顯示為準）。

### reply_to_message_id 對照（檔案 mapping）

拒絕後 **Telegram request feedback** 會送 Force Reply；**Save HITL reply map** 寫入：

```text
/data/hitl/reply_map/<telegram_message_id>.json
```

內容：`{ "run_id", "stage", "created_at" }`。Forwarder 收到回覆時用 `read_hitl_reply_map.sh` 查出 `run_id`，再恢復 **Wait for feedback**。

此目錄已在 `docker-compose.yml` 的 `N8N_RESTRICT_FILE_ACCESS_TO`（`/data`）內，**Read/Write Files** 可讀寫 `/data/hitl/feedback/<run_id>.txt`。

### revise/reject 後重跑範圍（Hermes 驅動）

1. `apply_feedback_task.sh` 更新 `TASK.md`（併入人類建議）
2. `hermes_revision_plan.sh` 產生 `rerun_scope`（`copy_only` / `copy_render` / `full`）
3. n8n 依 `rerun_scope` 重跑：
   - `copy_only`：重跑 copy
   - `copy_render`：重跑 copy + render
   - `full`：重跑 copy + svg + render
4. stage2 Telegram 預覽 → **Wait for approval (stage2)**；若再 `revise/reject` 會回到修正回圈
5. 觸發上限時寫入 `stop_reason`（`max_rounds_reached` / `no_progress` / `manual_stop`）

---

## Meta 發文失敗重試與熔斷（建議設定）

在 **Meta Graph API publish** 節點：

1. **Settings → Retry On Fail**：開啟，**Max Tries = 3**（與 `platform.yaml` 的 `circuit_breaker.retries` 一致）。
2. 仍失敗時，走 **錯誤輸出** 連到下方「節點 14」寫入 `api_dead.json`。
3. Linux 宿主可每分鐘檢查信號：`./scripts/check_api_dead.sh` 或 `amctl supervisor`（見 [HERMES_SETUP.md](HERMES_SETUP.md)）。

---

## 節點 13：Meta Graph API publish（核准後發文）

- 節點類型：**HTTP Request**
- Method：**POST**
- URL：

```text
https://graph.facebook.com/{{ $env.META_GRAPH_API_VERSION }}/{{ $env.META_PAGE_ID }}/photos
```

- Query：`access_token` = `={{ $env.META_PAGE_ACCESS_TOKEN }}`
- Body：multipart-form-data，欄位 `message` = `={{ $('Read post.md').item.json.data }}`
- 需帶入圖片二進位（依 n8n 版本從 Read post.png 節點選擇 Binary 欄位）

連線：**Switch** 的 **approve** 輸出 → 本節點。

---

## 節點 14：Write api_dead.json（發文失敗時）

- 節點類型：**Execute Command**
- 連在 **Meta Graph API publish** 的 **錯誤/第二輸出**（或 HTTP 失敗分支）
- Command：

```bash
/bin/bash /data/scripts/write_circuit_breaker.sh "{{ $('Set run context').item.json.run_id }}" "{{ $json.statusCode }}" "{{ $json.body }}"
```

供 Hermes Plan B 讀取 `data/logs/api_dead.json`。

---

## 正式路徑（上線必讀）

**不要用編輯器「Execute workflow」測 HITL。** 那是 manual/test 執行，Wait 節點不會註冊 `/webhook-wait/auto-media-hitl-v1`，forwarder 無法恢復。

| 步驟 | 正式做法 |
|------|----------|
| 觸發主流程 | **Schedule Trigger** 或 `POST /webhook/auto-media-run` → `bash scripts/trigger_production_run.sh` |
| Telegram 入站 | 設定 `WEBHOOK_URL=https://你的網域`，forwarder **啟用 Telegram Trigger** 並 Active |
| 本機無 HTTPS | `WEBHOOK_URL` 留空 → Telegram Trigger **停用**，用 `Webhook Telegram IN` + `bash scripts/telegram_poll_forwarder.sh` |
| 審核 | 只點 inline 按鈕（Approve/Revise/Reject），不要打字 |
| 恢復 Wait | forwarder 必須對 `$execution.resumeUrl` 發 **GET**（勿 POST、勿手動加 `/auto-media-hitl-v1` 後綴） |

**Approve 沒反應時先查這三項：**

1. Telegram 有沒進 n8n：本機需常駐 `bash scripts/telegram_poll_forwarder.sh`（或設定 `WEBHOOK_URL` 啟用 Telegram Trigger）。
2. `read_hitl_resume_map.sh` 是否 LF 換行（CRLF 會讓 forwarder 在讀 map 時失敗）。
3. resume map 裡的 URL 是否被錯誤加上 `auto-media-hitl-v1`；正確格式應為 `http://localhost:5678/webhook-waiting/<executionId>?signature=<token>`。

一鍵檢查／設定：

```bash
bash scripts/setup_production_hitl.sh   # 依 WEBHOOK_URL 切換模式
bash scripts/trigger_production_run.sh  # 觸發 production 執行
bash scripts/check_telegram_hitl.sh     # 診斷 Wait / forwarder / Telegram
```

---

## 啟用與測試

1. 右上角 **Save** → **Publish**。
2. 開關設為 **Active**（排程自動跑）。
3. 測試 HITL：`bash scripts/trigger_production_run.sh`（勿用編輯器 Execute）。
4. 到專案資料夾查看：`data/runs/<run_id>/` 應有 `post.md`、`art.svg`、`post.png`。

---

## B-prime HITL（Gateway + Save → Schedule → Wait）

當 `features.hermes_gateway: true` 且已執行 `amctl apply`：

1. **主題入口**：Telegram 文字 → Gateway **平台多選**（IG/Threads/FB）→ 確認後 `POST /webhook/auto-media-run`（body 含 `publish_targets`）。診斷：`bash scripts/verify_gateway_platform_flow.sh`。
2. **產線後 HITL（stage1）**：`Render PNG` → **Save wait resume URL (stage1)** → **Schedule Gateway prereview (stage1)** → **Wait for approval (stage1)**。
3. **Revise 後 HITL（stage2）**：`Rerun render PNG` → **Save wait resume URL (stage2)** → **Schedule Gateway prereview (stage2)** → **Wait for approval (stage2)**。
4. **預覽（Gateway 獨佔）**：`hermes_telegram_gateway.py` 在 `waiting` 後執行 `hermes_prereview.sh`，再送 **`sendMediaGroup`（最多 10 張輪播圖）**、Part 1 五則 `sendMessage`、以及 `post.md` 全文 `sendDocument`；審核按鈕附在最後一則文字。workflow 內 **`Telegram HITL preview` / `(stage2)` 必須 `disabled: true`**。
5. **資料目錄**：`docker compose up -d n8n gateway` — **Gateway 與 n8n 共用** `./data/runs`、`./data/hitl`、`./data/logs`。`.env` 設 `N8N_GATEWAY_URL=http://gateway:8787`。勿僅在宿主跑 Gateway。若曾用 named volume `n8n_runs`，複製至 `./data/runs` 後再 up。
6. **Forwarder**：`Read wait resume map` → `Parse wait resume map` → **GET** `$execution.resumeUrl`（勿用靜態 `/webhook-wait/...`）。
7. **Reject**：Switch 第三出口 → `Notify run rejected`（不進 Force Reply）。
8. **TTL**：Wait 後 **Check resume type** — 無 callback 視為超時。
9. **驗證**：`VERIFY_CLAUDE_STRICT=1 bash scripts/verify_n8n_claude_engine.sh`；`bash scripts/verify_workflow_live_parity.sh`；`bash scripts/verify_gateway_exclusive_preview.sh`；`bash scripts/verify_runs_mount_parity.sh <run_id>`；`bash scripts/enforce_telegram_gateway.sh`。
10. **同步 live workflow**（Dev Container）：`.env` 設 `N8N_SYNC_API_URL=http://host.docker.internal:5678`，執行 `python3 scripts/sync_workflow_to_n8n.py`；記錄見 `data/logs/verify_exec85_followup.json`。

---

## Instagram 發佈設定（Page + Graph API）

1. **IG 帳號綁 Page**：IG App → Business/Creator；FB Page → Settings → Linked accounts → Instagram。
2. **Token scopes**（Graph Explorer → Page Access Token）：`instagram_basic`、`instagram_content_publish`、`pages_show_list`、`pages_read_engagement`。
3. **取得 `IG_USER_ID`**：
   ```bash
   curl -s "https://graph.facebook.com/v21.0/${META_PAGE_ID}?fields=instagram_business_account&access_token=${META_PAGE_ACCESS_TOKEN}"
   ```
   將回傳的 `instagram_business_account.id` 寫入 `.env` 的 `IG_USER_ID`。
4. **Long-lived Page token**：與 FB 相同流程換長效 token，存於 `META_PAGE_ACCESS_TOKEN`。
5. **驗證**：`bash scripts/verify_meta_tokens.sh` → `docker compose up -d n8n`。

**注意**：圖片 URL 須公開 HTTPS（不可用 localhost）；container 建立後請盡快 publish；IG 約 **25 篇/日** 上限。

核准後發佈為 **env-gated fan-out**：`META_PAGE_ID` → FB `/photos`；`THREADS_USER_ID` → Threads chain；`IG_USER_ID` → IG carousel。共用 `upload_carousel_catbox.sh` 的 URL。

---

## 常見問題

| 現象 | 處理方式 |
|------|----------|
| Execute Command 失敗、`bash\r` | 腳本需為 Unix 換行（LF）；請技術人員在 Linux/Dev Container 內儲存 `scripts/*.sh` |
| 找不到 `/data/scripts` | 腳本在 **image build** 時 COPY 進容器；新增腳本後需 `docker compose build n8n && docker compose up -d n8n`，或執行 `bash scripts/sync_scripts_to_n8n.sh` |
| `sync_carousel_total.sh: No such file` | 同上；workflow 已接 Carousel 但容器映像未更新 |
| `prereview failed` | Gateway 與 n8n 未共用 runs：改 `docker compose up -d gateway`，勿 `GATEWAY_RUN_MODE=host` |
| Telegram 有圖無文案 | 確認 gateway 容器內 `/data/runs/<run_id>/post.md` 存在；`verify_runs_mount_parity.sh` |
| 文案總是 Gemini | `verify_n8n_claude_engine.sh`；`sync_claude_oauth.sh` + `inject_n8n_secrets.sh`；查 `data/logs/engine_failover.jsonl` |
| Telegram 沒收到圖 | 檢查 Bot Token、Chat ID、是否曾對 Bot 按過 Start |
| 預覽出現兩次 | 執行 `enforce_telegram_gateway.sh`；確認 `Telegram HITL preview` 節點為 disabled |
| 文案/圖產不出 | 容器內 CLI 未登入；開發用可設 `AUTO_MEDIA_MOCK=1` 做假資料測試 |
| Meta 發文 403 | 檢查 Page Token 權限與 `.env` 變數 |
| Threads `OAuthException` code 190 / Session has expired | `THREADS_ACCESS_TOKEN` 已過期。至 [Graph API Explorer](https://developers.facebook.com/tools/explorer/) 重新產生 User Token（需 `threads_basic`、`threads_content_publish` 等權限），更新 `.env` 後 `docker compose restart n8n`，執行 `bash scripts/verify_meta_tokens.sh` |
| Threads `THApiException` / `text` at most 500 characters | **Publish Threads chain** 預設 `--mode by_post`：每個 `### 貼文 N` 為一則（≤500 字），共 5 則串文；首則 `IMAGE`+圖，後續 `TEXT`+`reply_to_id`。乾跑：`bash scripts/verify_threads_publish.sh --run-id <id>`。 |
| n8n 顯示 Success 但沒發文 | 舊版 Publish 節點設了 `continueOnFail`；請 `python3 scripts/patch_bprime_workflows.py` 並 sync。核准後以 **`finalize_publish_gate.sh`** 讀 `publish_*.json`，任一本該發的平台失敗則 workflow **Error**。 |
| IG 只有 1 張 / caption 很短 | `carousel/` 少於 2 張時 **`upload_carousel_catbox.sh` 會 exit 1**（不再 fallback 單張 `post.png`）。產圖前 **`validate_post_md.sh`** 與 **`generate_carousel_images.sh`**（≥80% 張數且 ≥2）會擋下短稿。 |
| Telegram 只看到一張圖、文案被截斷 | 請重建 **gateway** 映像；舊版僅 `sendPhoto` + 1024 字 caption。 |
| `post.md` 驗證失敗 | **Validate post.md** 僅檢 **上限**（每則 ≤500、Caption ≤2200、輪播張數等），依 `TASK.md` 的 `publish_targets` 跳過未選平台；**不**再強制 5 則或最低字數。 |
| 圖片產物 | **僅當 TASK 含 `instagram`**：`IF Should generate carousel` → **Invoke carousel images**（張數由 `post.md` 總頁數經 sync 寫入 `carousel_total`）。**僅 Threads** 時跳過產圖（`carousel_total: 0`），Threads 發佈可走純 TEXT 串文。 |
| Telegram 無平台按鈕、立刻「生產中」 | Gateway 未更新或未走 `/telegram`：重啟 gateway；確認 `GATEWAY_URL`；新流程確認後應含「發佈：…」 |
| IG 發佈 403 | Page Token 需含 `instagram_basic`、`instagram_content_publish`；`.env` 設 `IG_USER_ID`（見下方 IG 設定）。圖片須為 **公開 HTTPS**（`upload_carousel_catbox.sh` → catbox）。 |
| IG Carousel | 核准後 **IF `IG_USER_ID`** → `publish_ig_carousel.sh`（子 container → `media_type=CAROUSEL` → `media_publish`）。與 FB Page、Threads **並行**，未設 env 則 skip。 |
| 按 Approve 沒反應 | 見上方「正式路徑」三項；確認 forwarder Active、主流程在 `waiting` 狀態 |
| Wait resume 404 | 勿用靜態 `/webhook-wait/...`；用執行期 `$execution.resumeUrl` + GET |

---

## 平台規則關卡（IG / Threads / Facebook）

規則常數：[`data/config/platform_limits.json`](../data/config/platform_limits.json)。檢查腳本：[`check_platform_limits.sh`](../scripts/check_platform_limits.sh)。

| 平台 | 規則 | 檢查時機 |
|------|------|----------|
| Instagram | 輪播 **2–10** 張；Caption ≤2200 字；Hashtag ≤30；圖 JPEG/PNG ≤8MB；24h API 發文 ≤25 篇 | 內容：`pre_hitl`；用量：`pre_publish` |
| Threads | 每則 ≤500 字（建議 ~450 斷句）；**輪播 API 最多 20** 媒體；非輪播 1 圖；JPEG/PNG ≤8MB；24h ≤250、1h ≤200 | 內容：`pre_hitl`；用量：`pre_publish` |
| Facebook | 訊息 ≤63206 字元 | `pre_hitl` / 發佈腳本 |

**IG 10 vs Threads 20**：產圖與 Hermes 審閱以 **共用一套圖** 為準，張數上限 = `min(規劃值, 10, 20)`；IG 輪播 API 硬上限 10。Threads **Phase 1** 發佈仍用 [`publish_threads_chain.sh`](../scripts/publish_threads_chain.sh)（首則 1 圖 + TEXT 串文）；**Phase 2** 才接 [`publish_threads_carousel.sh`](../scripts/publish_threads_carousel.sh)（`media_type=CAROUSEL`，≤20 媒體）。

Workflow 節點：`Validate post.md` → **Check platform limits (pre-HITL)** → **IF Should generate carousel** →（是）Sync + Invoke carousel /（否）直達 Hermes review；核准後 **Check platform limits (pre-publish)** → 上傳／發佈。

滾動用量帳本：`data/hitl/publish_quota.jsonl`（成功發佈後由 `record_publish_quota.sh` 記帳）。

**Telegram 指令**

| 指令 | 行為 |
|------|------|
| `/用量`、`用量查詢` | 回覆「功能開發中」（stub，尚未查剩餘額度） |
| 一般文字 | 主題 → **多選** IG / Threads / Facebook（至少一項）→「開始產出」才觸發 n8n |

Threads 動態 API 額度（約 \(4800 \times\) 曝光）目前僅文件註記；Graph rate limit 仍由發佈腳本錯誤轉述至 Telegram。

---

## 進階（工程師）

`[workflows/auto-media-happy-path.json](../workflows/auto-media-happy-path.json)` 為同一流程的 **匯出備份**，僅供版本對照或還原，**一般操作請以本手冊在網頁建立為準**。
