# Gemini CLI 整合

[Google Gemini CLI](https://github.com/google-gemini/gemini-cli) 作為 `gemini_cli` provider，可切換 **文案** 與 **SVG** 引擎（預設仍為 `claude_cli` + `codex_cli`）。

## 安裝位置

| 位置 | 安裝方式 |
|------|----------|
| Dev Container | `post-create.sh`：`npm install -g @google/gemini-cli@0.44.1`（`INSTALL_GEMINI=true`） |
| n8n 產線映像 | [`docker/n8n/Dockerfile`](../docker/n8n/Dockerfile) 已 bake `@google/gemini-cli` |

變更 n8n Dockerfile 後需 **rebuild**：

```bash
sudo docker compose -f docker-compose.yml build n8n
sudo docker compose up -d
```

## 認證（勿經 Telegram）

1. **建議**：在 Dev Container 或 n8n 容器內執行 `gemini`，選 **Login with Google**（瀏覽器 OAuth，憑證快取於 `~/.gemini`）。
2. **可選**：在 `~/.gemini/.env` 或專案 `.env` 設定 `GEMINI_API_KEY`（[Google AI Studio](https://aistudio.google.com/app/apikey)）。
3. **禁止**在 Hermes / Telegram 對話中貼 API Key；僅手動編輯 `.env` 後執行 `amctl apply`。

非互動（`invoke-engine.sh`）需已有快取憑證或環境變數，否則 headless 會失敗。見 [Gemini CLI Authentication](https://google-gemini.github.io/gemini-cli/docs/get-started/authentication.html)。

### n8n 容器內一次性登入

```bash
docker compose exec n8n bash
gemini   # 依畫面登入
exit
```

或掛載宿主/秘密目錄至 `~/.gemini`（勿把 token 寫進映像 layer）。

**n8n 必做**：OAuth 登入在 Dev Container 的 `~/.gemini`，容器讀的是 `data/secrets/gemini`。登入後執行：

```bash
./scripts/sync_gemini_oauth.sh
docker compose restart n8n
```

## 切換引擎

```bash
./scripts/amctl.sh engine copy gemini_cli   # 文案 → gemini
./scripts/amctl.sh engine svg gemini_cli    # SVG → gemini
./scripts/amctl.sh engine copy claude_cli   # 還原預設
./scripts/amctl.sh apply
```

`amctl engine` 會同步寫入 `binary: gemini`。

## 產線呼叫方式

[`scripts/lib/invoke-engine.sh`](../scripts/lib/invoke-engine.sh) 使用 headless 旗標：

- `invoke-engine.sh` 使用：`cd $RUN_DIR` + `gemini -p "..." -y --skip-trust --include-directories /data/runs,...`
- headless 需 `GEMINI_CLI_TRUST_WORKSPACE=true`（`.env` 預設已開）
- `-y` 即 YOLO（自動核准 write_file）；勿讓 agent 呼叫 `activate_skill`（prompt 已禁止）
- 若未落檔，fallback：stdout 重導至輸出檔

Skill 目錄沿用 `claude_copywriter`（文案）與 `codex_svg_artist`（SVG），無需另建 gemini skill 樹。

## 驗證

```bash
gemini --version
./scripts/env-check.sh
./scripts/amctl.sh status

# 試跑（需已登入且 MOCK=0）
export AUTO_MEDIA_MOCK=0
./scripts/amctl.sh engine copy gemini_cli
# 準備 data/runs/<id>/TASK.md 後：
./scripts/lib/invoke-engine.sh --run-id <id> --engine copywriter
```

## 參考

- [Headless mode](https://google-gemini.github.io/gemini-cli/docs/cli/headless.html)
- [Dev Container](DEVCONTAINER.md)
