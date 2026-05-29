# Claude Code CLI 整合

[Claude Code](https://code.claude.com/) 作為 `claude_cli` provider（文案引擎，可與 `gemini_cli` 切換）。

## 認證方式（擇一）

1. **OAuth（建議）**：在 Dev Container 執行 `claude` → `/login`（ChatGPT / Claude 訂閱）
2. **API Key**：`.env` 設 `ANTHROPIC_API_KEY`
3. **CI / headless token**：`claude setup-token` 後設 `CLAUDE_CODE_OAUTH_TOKEN`

憑證檔（Linux）：`~/.claude/.credentials.json`（mode 600）。可用 `CLAUDE_CONFIG_DIR` 覆寫路徑。

## n8n 必做（與 Gemini 相同問題）

OAuth 登入在 **`~/.claude`**，n8n 讀 **`data/secrets/claude`**（`CLAUDE_CONFIG_DIR=/data/secrets/claude`）。

```bash
claude                    # 完成 /login
./scripts/sync_claude_oauth.sh
docker compose restart n8n
```

## 切換引擎

```bash
./scripts/amctl.sh engine copy claude_cli
./scripts/amctl.sh apply
```

## 產線呼叫

[`scripts/lib/invoke-engine.sh`](../scripts/lib/invoke-engine.sh) 使用：

- `claude -p "<prompt>" --permission-mode acceptEdits`（**不用** `-y`，那是 Gemini 旗標）
- 執行前設 `CLAUDE_CONFIG_DIR` 指向 `/data/secrets/claude`

## 驗證

```bash
claude auth status
./scripts/env-check.sh
export CLAUDE_CONFIG_DIR=$PWD/data/secrets/claude
claude -p "ping" --permission-mode acceptEdits
```

## 參考

- [Authentication](https://code.claude.com/docs/en/authentication)
- [CLAUDE_CONFIG_DIR](https://code.claude.com/docs/en/env-vars)
- [Dev Container](DEVCONTAINER.md)
