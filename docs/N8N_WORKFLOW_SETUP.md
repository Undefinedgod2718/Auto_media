# n8n 產線設定手冊（非工程師）

在 **n8n 網頁介面** 建立自動發文流程，無需匯入 JSON 檔。

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
    → Invoke 文案 + Invoke 圖（平行）→ Render PNG
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


| 欄位名        | 類型     | 值                                                           |
| ---------- | ------ | ----------------------------------------------------------- |
| `run_id`   | String | `={{ $now.format('yyyyMMdd-HHmmss') }}-{{ $execution.id }}` |
| `topic`    | String | `AI 發展趨勢`（可改成你的主題）                                          |
| `audience` | String | `25-35 歲科技愛好者`                                              |


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

1. **主題入口**：Telegram 文字 → Gateway → `POST /webhook/auto-media-run`（body: `run_id`, `topic`, `chat_id`）。
2. **產線後 HITL**：`Render PNG` → **Save wait resume URL** → **Schedule Gateway prereview**（`GATEWAY_URL/internal/schedule-prereview`，只等 200）→ **Wait for approval (stage1)**。
3. **預覽**：Gateway worker 輪詢 `GET /api/v1/executions/{execution_id}`，僅在 `status=waiting` 後初審並 `sendPhoto`（非 n8n Telegram 節點）。
4. **Forwarder**：`Read wait resume map` → `Parse wait resume map` → **GET** `$execution.resumeUrl`（勿用靜態 `/webhook-wait/...`）。
5. **Reject**：Switch 第三出口 → `Notify run rejected`（不進 Force Reply）。
6. **TTL**：Wait 後 **Check resume type** — 無 callback 視為超時。
7. **PR-0**：`bash scripts/verify_n8n_hitl_semantics.sh`（需 n8n 運行）；`bash scripts/inventory_repo.sh` 產出 ground truth。

---

## 常見問題


| 現象                          | 處理方式                                                           |
| --------------------------- | -------------------------------------------------------------- |
| Execute Command 失敗、`bash\r` | 腳本需為 Unix 換行（LF）；請技術人員在 Linux/Dev Container 內儲存 `scripts/*.sh` |
| 找不到 `/data/scripts`         | 確認 `docker compose` 有掛載 `./scripts`（見 `docker-compose.yml`）    |
| Telegram 沒收到圖               | 檢查 Bot Token、Chat ID、是否曾對 Bot 按過 Start                         |
| 文案/圖產不出                     | 容器內 CLI 未登入；開發用可設 `AUTO_MEDIA_MOCK=1` 做假資料測試                   |
| Meta 發文 403                 | 檢查 Page Token 權限與 `.env` 變數                                    |
| 按 Approve 沒反應               | 見上方「正式路徑」三項；確認 forwarder Active、主流程在 `waiting` 狀態 |
| Wait resume 404               | 勿用靜態 `/webhook-wait/...`；用執行期 `$execution.resumeUrl` + GET |


---

## 進階（工程師）

`[workflows/auto-media-happy-path.json](../workflows/auto-media-happy-path.json)` 為同一流程的 **匯出備份**，僅供版本對照或還原，**一般操作請以本手冊在網頁建立為準**。

---

## PR-0：實機驗證 n8n HITL 語意（前置步驟）

`scripts/verify_n8n_hitl_semantics.sh` 用實機探測四個 HITL 行為（Q1–Q4），**結果決定 1802 行 workflow 改動是否站得住**。跑此腳本前，必須先把探測 workflow 匯入並啟用。

> **前提**：只能在跑得起 n8n 2.21.x 的環境執行（Dev Container / Linux host）。Windows 本機無 n8n，無法執行。

### 步驟

1. **設定 API Key**
   - n8n UI → **Settings → n8n API → Create API Key**
   - 貼到 `.env`：
     ```
     N8N_API_URL=http://localhost:5678
     N8N_API_KEY=<貼上>
     ```

2. **匯入探測 workflow**
   - n8n UI → **Workflows → Import from File** → `workflows/verify-wait-probe.json`
   - 開啟後右上角 **Active** 切為開啟（必須 active，腳本才找得到）

3. **啟動 n8n**（若未啟動）
   ```bash
   docker compose up -d n8n
   curl -fsS http://localhost:5678/healthz
   ```

4. **執行探測**
   ```bash
   bash scripts/verify_n8n_hitl_semantics.sh
   cat data/logs/n8n_semantics.json
   ```

### 判讀 `data/logs/n8n_semantics.json`

| 欄位 | 問題 | 期望 |
|------|------|------|
| `q1_wait_status_sequence.observed_sequence` | 進 Wait 前後 execution status | 見 `running` → `waiting`；`waiting_observed: true` |
| `q2_limit_wait_ttl_payload.after_wait_json_on_timeout` | `limitWaitTime`(10s) 超時後 `After wait` 收到的 `$json` | 確認「無 callback 欄位 = 超時」判別法 |
| `q3_delete_waiting_execution.delete_http` / `post_delete_status` | 對 waiting execution `DELETE` 結果 | 確認 abort（未 waiting 來源）可用 DELETE |
| `q4_resume_url_when_not_waiting.resume_url_http_when_not_waiting` | execution 非 waiting 時打 resume_url 的 code | 確認非 waiting 時 resume 無效（abort 分流依據） |

- **`passed: true`** ＝ 四問全完成且 Q1 觀測到 `waiting`。
- **`passed: false`** ＋ `note` ＝ 缺項或某問未完成；按 note 修正後重跑。腳本**不會**在未驗證時假裝通過。

四問拿到真答案前，`auto-media-happy-path.json` 的 Save→Schedule→Wait、Check resume type、abort 分流、forwarder resume_url 皆為**未驗證假設**。