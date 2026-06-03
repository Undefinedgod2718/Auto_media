# Dev Container 開發環境

對齊 [Claude Code 開發容器（官方 zh-TW）](https://code.claude.com/docs/zh-TW/devcontainer)。

## 用途

| 環境 | 職責 |
|------|------|
| **Dev Container**（本文件） | Skill 共創、`amctl`、Claude/Codex/Gemini 本機試跑、`docker compose` 啟動 n8n |
| **n8n 產線容器** | 排程、Execute Command、`invoke-engine.sh`（非互動 `-y`） |
| **Hermes（Linux 宿主）** | Plan B、`api_dead.json` |

## 快速開始

1. 安裝 [Docker Desktop](https://docs.docker.com/get-docker/) 與 Cursor/VS Code Dev Containers 擴充。
2. 命令面板：**Dev Containers: Reopen in Container**。
3. 等待 `post-create.sh`（`uv sync`、`amctl apply`）。
4. 終端執行 `claude` 完成 Claude Code 登入（`/login`）。見 **[CLAUDE_CLI.md](CLAUDE_CLI.md)**。
5. 執行 `codex` 完成 Codex CLI 登入（SVG 引擎用）。
6. （可選）執行 `gemini` 完成 Gemini CLI 登入，見 **[GEMINI_CLI.md](GEMINI_CLI.md)**。
7. 安裝檢查：`bash scripts/setup_wizard.sh --dry-run`；通過後可跑 `bash scripts/setup_wizard.sh`（見 **[INSTALL.md](INSTALL.md)**）。

登入後同步至 n8n 可讀目錄（Docker Desktop virtiofs 常需 inject）：

```bash
./scripts/sync_claude_oauth.sh   # Claude → data/secrets/claude
./scripts/sync_gemini_oauth.sh   # Gemini → data/secrets/gemini
./scripts/inject_n8n_secrets.sh  # copy into running n8n container if bind mount empty
docker compose restart n8n
VERIFY_CLAUDE_STRICT=1 ./scripts/verify_n8n_claude_engine.sh
```

產線建議：`GATEWAY_RUN_MODE=compose` + `docker compose up -d n8n gateway`（見 [HERMES_SETUP.md](HERMES_SETUP.md)）。`data/runs` 由 n8n 與 gateway 容器共用。本機 poll 用 compose `forwarder` profile 或 `forwarder_ctl.sh`（見 [INSTALL.md](INSTALL.md)）。

User console：`bash scripts/open_user_ui.sh`（port **8790**， uses `.venv/bin/python3` when present — see [VERIFY.md](VERIFY.md) § G）。

## 持久化 `~/.claude`、`~/.codex` 與 `~/.gemini`

| Volume | 路徑 | 用途 |
|--------|------|------|
| `claude-code-config-…` | `/home/vscode/.claude` | Claude Code OAuth |
| `codex-config-…` | `/home/vscode/.codex` | Codex CLI OAuth |
| `gemini-config-…` | `/home/vscode/.gemini` | Gemini CLI OAuth / `.env` |

Rebuild Container 後通常不必重新登入。

Claude 自訂路徑見 [`CLAUDE_CONFIG_DIR`](https://code.claude.com/zh-TW/env-vars)。Codex 設定檔為 `~/.codex/config.toml`。Gemini 可於 `~/.gemini/.env` 設定 `GEMINI_API_KEY`（見 [GEMINI_CLI.md](GEMINI_CLI.md)）。

### Codex 登入驗證

```bash
codex --version
codex auth status   # 若子命令可用；或執行 codex 依畫面登入
```

映像預設 `INSTALL_CODEX=true`（GitHub release 二進位 + post-create npm fallback）、`INSTALL_GEMINI=true`（post-create `npm install -g @google/gemini-cli`）。

### Gemini 登入驗證

```bash
gemini --version
gemini   # 首次：Login with Google 或設定 GEMINI_API_KEY
```

## Docker socket（開發用）

容器掛載宿主 `docker.sock`（`DOCKER_HOST=unix:///var/run/docker-host.sock`），可在 Dev Container 內執行：

```bash
sudo docker compose -f docker-compose.yml build n8n gateway
sudo docker compose up -d n8n gateway
bash scripts/post_docker_rebuild.sh   # apply + perms + secrets + verify（重建後首選）
```

**未 rebuild、只改 repo 腳本時**才需要：

```bash
bash scripts/sync_scripts_to_n8n.sh   # docker cp scripts → 運行中容器（腳本會自動用 sudo）
```

（`vscode` 透過 sudo 存取宿主 Docker socket；**勿**寫成 `bash docker compose ...`。見 `.devcontainer/Dockerfile` 的 sudoers 設定。）

**風險：** 等同授予容器操作宿主 Docker 的權限。僅在受信任開發機使用，勿用於生產。

## Skill 共創

1. 編輯 [`config/skills/`](config/skills/)（建議在 Dev Container 內用 `claude` 協作）。
2. 遵循 [`SKILL_AUTHORING.md`](SKILL_AUTHORING.md) 審核清單。
3. `amctl skill validate`
4. 設 `engines.*.status: active` 後 `amctl apply`。

## 安全

- **不要** bind mount `~/.ssh`、雲端憑證檔到容器。
- `managed-settings.json` 禁止 `--dangerously-skip-permissions` 繞過模式（見 `.devcontainer/managed-settings.json`）。
- 僅在受信任 repo 使用無人值守旗標。

## Windows 注意

請在 **Dev Container 內** 開發（workspace 在 container 檔案系統）。避免用 `/mnt/d/...` 作為生產 `data/` bind mount（權限與 I/O 問題）。詳見 [`CODEX_DOCKER.md`](CODEX_DOCKER.md)。

若在 Windows 宿主 bind mount `./scripts` 進 n8n 且出現 `bash\r: No such file or directory`，請確保 `*.sh` 為 **LF**（見 repo `.gitattributes`），或只在 Dev Container / Linux 上編輯腳本。

## n8n 產線（非工程師）

1. `sudo docker compose up -d`（Dev Container 內或宿主）。
2. 開啟 http://localhost:5678。
3. 依 **[N8N_WORKFLOW_SETUP.md](N8N_WORKFLOW_SETUP.md)** 在網頁上新增節點（**勿**以匯入 JSON 為主要步驟）。
4. 設定 Telegram credential 與 `.env` 密鑰。

工程師備份 JSON 見 [`workflows/README.md`](../workflows/README.md)。

## 參考

- [Anthropic 參考 devcontainer](https://github.com/anthropics/claude-code/tree/main/.devcontainer)
