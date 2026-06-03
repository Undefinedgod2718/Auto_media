> **Archived.** Current docs: [INSTALL.md](../INSTALL.md), [VERIFY.md](../VERIFY.md), or [README.md#architecture](../../README.md#architecture).

# Auto Media 測試計劃與上線啟動

本文件定義可在本機與容器執行的最小上線驗證路徑，目標是先確保產線「可跑、可回退、可觀測」。

## 1. 目標

- 驗證控制面可正確產出 runtime 設定。
- 驗證生成管線可完成一次端到端 smoke（mock 模式）。
- 驗證 n8n 服務可啟動且健康。
- 驗證失敗時可透過 circuit breaker 切換 Plan B。

## 2. 測試分層

### A. 設定層（Config Apply）

- 指令：`uv run auto-media-apply`
- 驗收：
  - 產生 `data/config/platform.runtime.json`
  - 產生 `config/hermes/CONTEXT.md`
  - 產生 `config/hermes/mcp.json`
- 失敗處理：
  - 本機未安裝 `codex` / `gemini` 時，使用 `AUTO_MEDIA_ALLOW_MISSING_CLI=1` 先完成配置驗證。

### B. Smoke 層（Mock End-to-End）

- 前提：`AUTO_MEDIA_MOCK=1`
- 流程：
  1. 建立 run：`write_task.sh`
  2. 生成文案：`generate_copy.sh`
  3. 生成 SVG：`generate_svg.sh`
  4. 渲染 PNG：`render_png.sh`
- 驗收：
  - `data/runs/{RUN_ID}/TASK.md`
  - `data/runs/{RUN_ID}/post.md`
  - `data/runs/{RUN_ID}/art.svg`
  - `data/runs/{RUN_ID}/post.png`

### C. 服務層（n8n）

- 指令：
  - `docker compose build`
  - `docker compose up -d`
- 驗收：
  - `docker compose ps` 顯示 `n8n` 為 running/healthy
  - `http://localhost:5678/healthz` 可回應

### D. 失敗切換層（Plan B）

- 建立信號：`write_circuit_breaker.sh RUN_ID STATUS BODY`
- 驗收：
  - `data/logs/api_dead.json` 存在且內容含 run 資訊
  - `scripts/hermes-plan-b.sh` 能讀到 signal 並嘗試啟動 Plan B

## 3. 上線前 Gate（必過）

- Gate 1：Config Apply 成功
- Gate 2：Mock Smoke 完整產物齊全
- Gate 3：n8n healthy
- Gate 4：Circuit breaker 檔案可正確產生

任一 Gate 失敗即不進入實發（Meta API）。

## 4. 啟動順序（建議）

1. 先跑 Gate 1 + Gate 2（零風險）
2. 再啟動 n8n（Gate 3）
3. 最後檢查 Plan B 信號機制（Gate 4）

## 5. 觀測與回滾

- 觀測重點：
  - `data/runs/*` 產物是否完整
  - `data/logs/api_dead.json` 是否被誤觸發
  - n8n healthz 是否穩定
- 回滾策略：
  - 將 `publish.mode` 維持 `auto`，先停留 mock 驗證
  - 出現 API 連續失敗時，直接走 Plan B，不阻斷產線
