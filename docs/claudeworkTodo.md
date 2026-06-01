# claude-work TODO：B′ 實機測試指令

給能跑起 n8n 2.21.x + CLI 的環境（Dev Container / Linux host）的 agent 執行。
Windows 本機**無法**跑（無 n8n、無 bash CLI 鏈）。每步附「期望輸出」與「失敗處置」。
跑完把每步結果填回最後的 **回報模板**，貼回 PR。

分支：`feat/b-prime-hardening-v4`

---

## 0. 環境前置

```bash
cd /workspaces/Auto_media          # 或你的 repo 路徑
git fetch origin
git checkout feat/b-prime-hardening-v4
git pull
cp -n .env.example .env             # 若無 .env
```

`.env` 需填：
```
N8N_API_URL=http://localhost:5678
N8N_API_KEY=            # 步驟 2 產生後回填
TELEGRAM_BOT_TOKEN=     # 測 Gateway 才需要
TELEGRAM_CHAT_ID=
TELEGRAM_WEBHOOK_SECRET=    # 任意 1-256 字隨機字串
GATEWAY_INTERNAL_SECRET=    # 任意隨機字串
N8N_ENCRYPTION_KEY=         # 隨機 ≥32 字
```

**期望**：`.env` 存在、上列變數非空（Telegram 三項僅測 Gateway 時必填）。

---

## 1. 啟動 n8n

```bash
docker compose up -d n8n
sleep 5
curl -fsS http://localhost:5678/healthz && echo " OK"
```

**期望**：`healthz` 回 200 `OK`。
**失敗**：`docker compose logs n8n | tail -50` → 多半是 `N8N_ENCRYPTION_KEY` 未設或埠衝突。

---

## 2. 建 API Key + 匯入探測 workflow

1. 瀏覽器開 `http://localhost:5678`
2. **Settings → n8n API → Create API Key** → 複製 → 回填 `.env` 的 `N8N_API_KEY`
3. **Workflows → Import from File** → `workflows/verify-wait-probe.json`
4. 開啟匯入的 workflow → 右上 **Active** 開啟

**期望**：
```bash
set -a; source .env; set +a
curl -fsS -H "X-N8N-API-KEY: $N8N_API_KEY" "$N8N_API_URL/api/v1/workflows?limit=200" \
  | python3 -c "import json,sys; print([w['name'] for w in json.load(sys.stdin)['data'] if w.get('active')])"
```
輸出含 `'verify-wait-probe'`。
**失敗**：未 active → 回 UI 開 Active；401 → API Key 錯。

---

## 3. PR-0：HITL 語意四問（最關鍵）

```bash
bash scripts/verify_n8n_hitl_semantics.sh
cat data/logs/n8n_semantics.json
```

**期望**：`passed: true`，且：
- `q1_wait_status_sequence.waiting_observed: true`，`observed_sequence` 含 `running` 後 `waiting`
- `q2_limit_wait_ttl_payload.status: "tested"`，記錄 `after_wait_json_on_timeout`
- `q3_delete_waiting_execution.delete_http` 有值（記下，多半 200/204），`post_delete_status`
- `q4_resume_url_when_not_waiting.resume_url_http_when_not_waiting` 有值（記下，多半 404）

**失敗**：
- `passed:false` + note「workflow not found / NOT active」→ 回步驟 2。
- `q1 waiting_observed:false` → **重大**：表示外部偵測 `status==waiting` 不可靠，B′ 就緒偵測前提崩，需停下回報。

> **把 q1–q4 的實際數值完整貼回回報模板。** 這四個答案決定 1802 行 workflow 改動是否成立。

---

## 4. 引擎 failover 實機（需至少一個 CLI 登入）

```bash
# 確認哪些 CLI 可用
for b in claude codex gemini; do command -v $b && $b --version 2>/dev/null | head -1; done

# mock 短路測試（不需 CLI）
AUTO_MEDIA_MOCK=1 bash scripts/lib/invoke-engine.sh --run-id smoke --engine copywriter
cat data/runs/smoke/post.md

# 真鏈測試（engines.copy.status 需 active；見 config/platform.yaml）
mkdir -p data/runs/live; printf 'topic: 測試主題\naudience: general\n' > data/runs/live/TASK.md
bash scripts/lib/invoke-engine.sh --run-id live --engine copywriter
echo "exit=$?"; cat data/logs/engine_failover.jsonl
```

**期望**：
- mock：`post.md` 產出，stdout `{"ok":true,...}`。
- 真鏈：成功則 `{"ok":true,"provider_used":"..."}`；每嘗試一行 `engine_failover.jsonl`；**同一 provider 不得出現兩次**（驗證假鏈已除）。
- 停掉 primary（如把 `claude` 改名）應自動降到 gemini → codex，`provider_used` 反映實際成功者。

**失敗**：所有 CLI 未登入 → 三 provider 全 fail，`{"ok":false,...tried: claude_cli gemini_cli codex_cli}`（這也是正確的失敗，證明鏈走完未早退）。

---

## 5. Gateway smoke（需 Telegram token）

```bash
bash scripts/start_gateway.sh &
sleep 2
# 5a. 語法/啟動
curl -s -o /dev/null -w "%{http_code}\n" -X POST http://localhost:8787/telegram -d '{}'
```

**期望**：
- 5a 回 **403**（無 `X-Telegram-Bot-Api-Secret-Token` → 拒收，安全修正生效）。
- 帶正確 header 才放行：
  ```bash
  curl -s -o /dev/null -w "%{http_code}\n" -X POST http://localhost:8787/telegram \
    -H "X-Telegram-Bot-Api-Secret-Token: $TELEGRAM_WEBHOOK_SECRET" \
    -d '{"update_id":1,"message":{"text":"hi","chat":{"id":1}}}'
  ```
  回 **200**。
- `cat data/logs/gateway.jsonl` 有對應 ingress 行。

**失敗**：import error → 不該再發生（語法已修）；若有，貼 `python3 scripts/hermes_telegram_gateway.py` 的 traceback。

收尾：`kill %1`。

---

## 6. 回報模板（填好貼回 PR）

```
### 環境
- n8n 版本：
- 可用 CLI：claude/codex/gemini = ?/?/?

### 步驟 3 — PR-0 四問（貼 n8n_semantics.json 全文）
- Q1 observed_sequence: 
- Q1 waiting_observed: 
- Q2 after_wait_json_on_timeout: 
- Q3 delete_http / post_delete_status: 
- Q4 resume_url_http_when_not_waiting: 
- passed: 

### 步驟 4 — failover
- mock: 
- 真鏈 provider_used: 
- engine_failover.jsonl（每 provider 最多一次？）: 

### 步驟 5 — Gateway
- /telegram 無 header: 應 403 → 實得：
- /telegram 帶 header: 應 200 → 實得：

### 阻斷/異常
- 
```

---

## 注意

- 步驟 3 的 Q1 若 `waiting_observed:false`，**停止後續 workflow 信任**，先回報——B′ 整個就緒偵測建在此假設上。
- 所有 `scripts/*.sh` 必須 LF 換行；CRLF 會讓 Execute Command 報 `bash\r`。
- 不要用 n8n 編輯器「Execute workflow」測 HITL（Wait 不註冊 webhook）；用 `trigger_production_run.sh`。
