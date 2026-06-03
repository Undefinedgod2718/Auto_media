# Codex 與 Docker 策略

## 為何不做 Docker-in-Docker（DinD）

依 [OpenAI 社群討論](https://community.openai.com/t/codex-docker-in-docker-in-environment-setup/1272369)：

- Codex **雲端 Environment** 內可嘗試啟動 `dockerd`，但常見 **`unshare: operation not permitted`**，無法 `docker load` / `docker run`。
- 在 n8n 產線容器內再跑 `dockerd` 會增加 RAM、複雜度與安全面，**本專案明確禁止**。

## 三層執行邊界

```text
┌─────────────────────────────────────────────────────────┐
│ Dev Container（開發）                                    │
│  Claude Code Feature | amctl | docker compose (socket)  │
│  Codex CLI（預設 INSTALL_CODEX=true，ChatGPT OAuth）     │
└───────────────────────────┬─────────────────────────────┘
                            │ docker compose up
                            ▼
┌─────────────────────────────────────────────────────────┐
│ n8n 產線容器（docker/n8n/Dockerfile）                      │
│  bash + jq + rsvg + codex + claude-code + gemini-cli       │
│  無 dockerd | 無 DinD                                    │
└───────────────────────────┬─────────────────────────────┘
                            │ api_dead.json
                            ▼
┌─────────────────────────────────────────────────────────┐
│ Hermes（Linux 宿主，非容器內）                           │
│  Playwright Plan B                                       │
└─────────────────────────────────────────────────────────┘
```

## Codex CLI 安裝位置

| 位置 | 用途 |
|------|------|
| Dev Container | 本機試跑 SVG、`amctl engine svg codex_cli` 開發 |
| n8n 產線映像 | 預設 `INSTALL_CODEX=true` 烘焙；`invoke-engine.sh` 優先 `codex_cli` |
| Codex 雲端環境 | **不** 依賴 Docker；用原生依賴或 mock |

`amctl apply` 在 `engines.svg.provider=codex_cli` 時會檢查 `codex` 是否在 PATH（除非 `AUTO_MEDIA_MOCK=1` 或 `AUTO_MEDIA_ALLOW_MISSING_CLI=1`）。

### Dev Container 安裝（預設已開）

- [`devcontainer.json`](../.devcontainer/devcontainer.json)：`INSTALL_CODEX=true`，`~/.codex` named volume。
- [`Dockerfile`](../.devcontainer/Dockerfile)：從 [OpenAI Codex releases](https://github.com/openai/codex/releases) 安裝 linux musl 二進位。
- [`post-create.sh`](../.devcontainer/post-create.sh)：若無 `codex` 則 `npm install -g @openai/codex`。

登入：容器內執行 `codex`，使用 **ChatGPT OAuth**（與官方 CLI 相同）。詳見 [DEVCONTAINER.md](DEVCONTAINER.md)。

### n8n 產線映像（預設已烘焙）

```bash
# 重建並重啟（INSTALL_CODEX 預設 true）
docker compose build n8n && docker compose up -d n8n
docker exec auto_media-n8n-1 codex --version

# OAuth：在 Dev Container 或宿主執行 codex 登入後，憑證寫入 data/secrets/codex
# compose 已掛載至 /home/node/.codex
```

關閉 Codex：`INSTALL_CODEX=false docker compose build n8n`。

## 整合測試

若未來需要 Postgres/Redis 等：

- 在 **宿主** 用 `docker-compose.yml` 增加 **sidecar 服務**。
- **不要** 在 n8n 容器內啟動 dockerd。

受限環境可參考社群做法：將依賴改為原生安裝並寫入 `AGENTS.md`（[gist 範例](https://gist.github.com/juanpabloaj/89d615f882c4452e7b48ed19f64b1057)）。

## 開發 fallback

```bash
export AUTO_MEDIA_MOCK=1
./scripts/amctl.sh apply
# 完整 mock 管線見 README「Smoke test」
```

## 與官方 n8n 映像的差異

官方 `n8nio/n8n` 為 **distroless**（無 shell），無法跑 Execute Command。本 repo 使用 [`docker/n8n/Dockerfile`](../docker/n8n/Dockerfile)（`node:bookworm-slim` + `n8n` CLI），**仍不** 安裝 `dockerd`。
