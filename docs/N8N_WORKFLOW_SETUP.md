# n8n 產線設定手冊（非工程師）

在 **n8n 網頁介面** 建立自動發文流程，無需匯入 JSON 檔。

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
- Caption（說明文字）：

```text
={{ $('Read post.md').item.json.data }}
```

**憑證**：在節點上建立 **Telegram API** credential，填入 Bot Token（與 `.env` 的 `TELEGRAM_BOT_TOKEN` 相同）。

連線：**Read post.png**、**Read post.md** → **Telegram HITL preview**

---

## 節點 11：Wait for approval（人工審核）

- 節點類型：**Wait**
- Resume：**On Webhook Call**
- 記下 Webhook URL，供 Telegram 按鈕或手動呼叫（進階整合時使用）。

---

## 節點 12：Switch callback

- 節點類型：**Switch**
- 規則：當 `{{ $json.body?.callback || $json.callback }}` **等於** `approve` → 輸出 **approve**
- 其餘走 **fallback**（拒絕或略過發文）。

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

## 啟用與測試

1. 右上角 **Save**。
2. 開關設為 **Active**（若要排程自動跑）。
3. 測試：用 **Manual Trigger** 或 **Execute workflow**。
4. 到專案資料夾查看：`data/runs/<run_id>/` 應有 `post.md`、`art.svg`、`post.png`。

---

## 常見問題


| 現象                          | 處理方式                                                           |
| --------------------------- | -------------------------------------------------------------- |
| Execute Command 失敗、`bash\r` | 腳本需為 Unix 換行（LF）；請技術人員在 Linux/Dev Container 內儲存 `scripts/*.sh` |
| 找不到 `/data/scripts`         | 確認 `docker compose` 有掛載 `./scripts`（見 `docker-compose.yml`）    |
| Telegram 沒收到圖               | 檢查 Bot Token、Chat ID、是否曾對 Bot 按過 Start                         |
| 文案/圖產不出                     | 容器內 CLI 未登入；開發用可設 `AUTO_MEDIA_MOCK=1` 做假資料測試                   |
| Meta 發文 403                 | 檢查 Page Token 權限與 `.env` 變數                                    |


---

## 進階（工程師）

`[workflows/auto-media-happy-path.json](../workflows/auto-media-happy-path.json)` 為同一流程的 **匯出備份**，僅供版本對照或還原，**一般操作請以本手冊在網頁建立為準**。