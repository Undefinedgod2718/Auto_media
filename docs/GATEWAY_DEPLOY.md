# B′ Gateway 部署 runbook（Model A：Telegram 文字主題入口）

讓使用者在 Telegram **直接打主題文字**就啟動整條產線。文字入口已內建於
`scripts/hermes_telegram_gateway.py` 的 `topic_start` job — **零改碼**，本文件只講部署。

> 適用：`features.hermes_gateway: true`。Gateway 跑在 **host**，n8n 跑在容器，
> 兩者共用 `./data` 掛載，故 `TASK.md` 互通。

---

## 資料流（已對碼確認）

```
Telegram 文字（純文字、非 / 開頭、非回覆）
  → Gateway POST /telegram（驗 X-Telegram-Bot-Api-Secret-Token）
  → topic_start job:
      write_task.sh --run-id <id> --topic <整段文字>     # 寫 /data/runs/<id>/TASK.md
      POST {N8N_API_URL}/webhook/auto-media-run {run_id, topic, chat_id}
  → happy-path: Webhook Run → Load runtime → Set run context（讀 body.topic）
      → Write TASK → invoke copy/svg → Render → Save → Schedule Gateway prereview → Wait
  → Gateway worker poll GET /executions/{id} 至 status=waiting → sendPhoto（三按鈕）
  → 使用者按 Approve/Revise/Reject → Gateway → resume Wait
```

---

## 步驟 0 — 🔴 修 `platform.runtime.json`（必先做）

`Webhook Run` 與 `Schedule Trigger` **都**先進 `Load platform.runtime.json` 節點
（`cat /data/config/platform.runtime.json`）。**缺檔 = 任何觸發都掛在第一個節點。**

```bash
cd <repo>
AUTO_MEDIA_ALLOW_MISSING_CLI=1 uv run auto-media-apply   # 或 python3 -m auto_media_tools.apply
ls data/config/platform.runtime.json                     # 確認生成
```
host 生成即容器可見（共用 `./data`）。

---

## 步驟 1 — `.env`

```
N8N_API_URL=http://localhost:5678
N8N_API_KEY=<n8n UI: Settings → n8n API → Create API Key>   # Gateway poll executions 需要
TELEGRAM_BOT_TOKEN=<...>
TELEGRAM_CHAT_ID=<...>
TELEGRAM_WEBHOOK_SECRET=<隨機 1-256 字>      # setWebhook + Gateway 兩端必一致
GATEWAY_INTERNAL_SECRET=<隨機字串>
GATEWAY_PUBLIC_URL=https://<公開 HTTPS>      # Telegram 要打得到 Gateway:8787
```

---

## 步驟 2 — 啟 Gateway（host）

```bash
bash scripts/start_gateway.sh
# 健康檢查：無 secret header 應回 403（認證生效 + 進程活）
curl -s -o /dev/null -w '%{http_code}\n' -X POST localhost:8787/telegram -d '{}'   # 期望 403
```

---

## 步驟 3 — 指 Telegram webhook 到 Gateway

```bash
bash scripts/enforce_telegram_gateway.sh
# 內含：setWebhook(url=GATEWAY_PUBLIC_URL/telegram, secret_token=TELEGRAM_WEBHOOK_SECRET)
#       + 停用 n8n 所有 telegramTrigger 節點（B′ 單例）
```

**硬條件**：`GATEWAY_PUBLIC_URL` 必須公開 HTTPS。Telegram `setWebhook` 不收 localhost。

### 本機無 HTTPS 的替代（dev）

不跑 `setWebhook`，改常駐 poll：
```bash
GATEWAY_URL=http://localhost:8787 bash scripts/telegram_poll_forwarder.sh
# getUpdates → POST Gateway /telegram（自動帶 X-Telegram-Bot-Api-Secret-Token）
```

---

## 步驟 4 — 測

1. Telegram 打一則主題（純文字，例如「從腦科學與執行功能看 AI 教學焦慮…」）。
2. 應收：`已收到，生產中… run_id=…`。
3. 等 Gateway 預覽（圖 + Approve/Revise/Reject）。
4. 按 Approve → 進發文。

沒收到「生產中」→ 查：
- Gateway 是否在跑（步驟 2 的 403 測試）。
- webhook 是否指向 Gateway：`curl "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/getWebhookInfo"` → `url` 應為 `GATEWAY_PUBLIC_URL/telegram`。
- dev 模式 poll forwarder 是否常駐。
- 是否誤用「回覆」發訊息（reply → 當 feedback，不開新流程）。

---

## 注意事項

- **回覆 vs 新訊息**：直接發新訊息＝開新主題；回覆某則 Force Reply＝revise 意見。
- **整段文字當 topic**：文案與圖共用同一 topic，無法單獨指定圖的構想。
- **單例**：`enforce` 停用 n8n telegramTrigger，避免與 Gateway 搶 webhook。勿同時啟用 legacy forwarder 的 Telegram Trigger。
- **半遷移殘留**：`auto-media-happy-path` 仍含舊 n8n prereview/Telegram preview 節點（孤兒，無上游）。Gateway 路徑不會觸發它們，但圖較髒；清理見 PR「remove orphan stage1 prereview/preview chain」。

---

## 驗證清單

- [ ] `data/config/platform.runtime.json` 存在
- [ ] `curl -X POST localhost:8787/telegram -d '{}'` → 403
- [ ] `getWebhookInfo.url` 指向 Gateway（或 dev poll forwarder 常駐）
- [ ] Telegram 文字 → 收「生產中 run_id」
- [ ] `data/runs/<run_id>/TASK.md` 內 `topic:` 為你打的文字
- [ ] Telegram 收到預覽圖 + 三按鈕
- [ ] Approve → 主流程 resume → 發文
