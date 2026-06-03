# Auto Media

Low-cost, self-hosted pipeline for social posts: Markdown copy + SVG → PNG, human approval, Meta API with DOM fallback.

## Quick start

### 1. Install (guided)

```bash
bash scripts/setup_wizard.sh --dry-run   # no writes; see docs/VERIFY.md
bash scripts/setup_wizard.sh             # interactive install
```

Non-interactive: `bash scripts/install.sh`. After `docker compose build`: `bash scripts/post_docker_rebuild.sh`. Details: [docs/INSTALL.md](docs/INSTALL.md).

### 2. Environment check

```bash
./scripts/env-check.sh
./scripts/amctl.sh env
```

Install missing tools:


| Tool        | Purpose                      | Install                                                        |
| ----------- | ---------------------------- | -------------------------------------------------------------- |
| Docker      | n8n                          | [Docker Desktop](https://docs.docker.com/get-docker/)          |
| uv          | Python tooling (UTF-8 apply) | `curl -LsSf https://astral.sh/uv/install.sh | sh`              |
| Claude Code | Copy engine (in container)   | `npm i -g @anthropic-ai/claude-code`                           |
| Codex       | SVG engine                   | Your subscription channel / n8n image                          |
| Hermes      | Plan B (Linux host)          | [Hermes install](https://github.com/nousresearch/hermes-agent) |


**Windows:** prefer **Dev Container** (see below) or WSL2 with repo at `~/Auto_media` (not `/mnt/d/...`).

### Dev Container (recommended for Skill + Claude login)

1. **Dev Containers: Reopen in Container** in Cursor/VS Code.
2. First run: `claude` then `codex` to log in (OAuth; `~/.claude` / `~/.codex` volumes).
3. `sudo docker compose up -d` from inside the container (uses host Docker socket).

See [DEVCONTAINER.md](docs/DEVCONTAINER.md) and [CODEX_DOCKER.md](docs/CODEX_DOCKER.md) (no DinD in n8n/Codex cloud).

### 3. Configure (manual alternative)

```bash
cp .env.example .env
# Edit secrets (UTF-8). For pipeline mock without CLIs: AUTO_MEDIA_MOCK=1

uv sync
./scripts/amctl.sh apply
```

### 4. Build and run n8n

```bash
docker compose build
docker compose up -d
```

Open [http://localhost:5678](http://localhost:5678) — follow **[N8N_WORKFLOW_SETUP.md](docs/N8N_WORKFLOW_SETUP.md)** to build the workflow in the web UI (no JSON import required). Configure Telegram credentials in n8n and `.env`.

**Telegram Webhook (HTTPS):** n8n Wait/resume 需要公開 URL。開發機可用 [n8n tunnel](https://docs.n8n.io/hosting/installation/docker/) 或將 `WEBHOOK_URL` 設為你的 reverse proxy 網址（見 `.env.example`）。

**資源：** n8n 容器 `mem_limit: 512m`；Playwright/Chromium 僅在 Plan B 熔斷時由 Hermes 啟動，不常駐。

### 5. Smoke test (mock)

```bash
export AUTO_MEDIA_MOCK=1 DATA_ROOT=./data
mkdir -p data/config
./scripts/amctl.sh apply
RUN_ID=test-001
./scripts/write_task.sh --run-id "$RUN_ID" --topic "Smoke test"
./scripts/generate_copy.sh --run-id "$RUN_ID"
./scripts/generate_image.sh --run-id "$RUN_ID"
./scripts/render_png.sh --run-id "$RUN_ID"
ls -la "data/runs/$RUN_ID"
# Expect: TASK.md, post.md, post.png (art.svg optional)
```

### Non-engineer local UI

```bash
bash scripts/open_user_ui.sh
# or
scripts/am-user open
```

User guide: [`USER.md`](USER.md)

## amctl


| Command                          | Description                                         |
| -------------------------------- | --------------------------------------------------- |
| `amctl apply`                    | Sync YAML → `platform.runtime.json`, Hermes context |
| `amctl status`                   | Runtime + docker + env                              |
| `amctl ui n8n|hermes|dual`       | Switch operator UI                                  |
| `amctl skill list|validate|use`  | Skill mounts                                        |
| `amctl publish api|dom|auto`     | Publish mode                                        |
| `amctl engine copy|svg PROVIDER` | Engine provider (CLI)                               |
| `amctl supervisor`               | Check `api_dead.json` / Plan B hint                 |

Engine priority UI (copy/svg order): `http://127.0.0.1:8790/engines` — see [USER.md](USER.md).

## Architecture

Self-hosted pipeline: **n8n** orchestration, file-based **Skills** (open-design), **Hermes** Plan B supervisor.

| Layer | Component |
|-------|-----------|
| Control | `config/platform.yaml` + `amctl.sh` |
| Orchestration | n8n (Docker, custom image) |
| Generation | Claude / Codex / Gemini CLI via `invoke-engine.sh` |
| Render | rsvg-convert → PNG |
| HITL | Telegram + Gateway + n8n Wait |
| Plan A publish | Meta Graph API |
| Plan B | Hermes + Playwright (`api_dead.json`) |

References: [n8n](https://github.com/n8n-io/n8n) · [Hermes Agent](https://github.com/nousresearch/hermes-agent) · [open-design](https://github.com/nexu-io/open-design)

## Encoding

- Repository: **UTF-8** (`.editorconfig`, `.gitattributes` LF).
- Containers: `LANG=C.UTF-8`, `LC_ALL=C.UTF-8`.
- Python: managed with **uv** (`pyproject.toml`).

## Docs

**Install / verify**

- [INSTALL.md](docs/INSTALL.md) — setup wizard, HITL, forwarder, 8790 console
- [VERIFY.md](docs/VERIFY.md) — smoke, doctor, strict verify, production gates
- [USER.md](USER.md) — non-engineer UI and tokens

**Operations**

- [N8N_WORKFLOW_SETUP.md](docs/N8N_WORKFLOW_SETUP.md) — build workflow in n8n UI
- [GATEWAY_DEPLOY.md](docs/GATEWAY_DEPLOY.md) — Telegram → Gateway (HTTPS / poll dev)
- [ENGINE_FAILOVER.md](docs/ENGINE_FAILOVER.md) — copy/svg provider chain

**Environment**

- [DEVCONTAINER.md](docs/DEVCONTAINER.md) — Dev Container + OAuth
- [CODEX_DOCKER.md](docs/CODEX_DOCKER.md) — Codex / Docker boundaries
- [CLAUDE_CLI.md](docs/CLAUDE_CLI.md) · [GEMINI_CLI.md](docs/GEMINI_CLI.md)

**Skills / Plan B**

- [SKILL_AUTHORING.md](docs/SKILL_AUTHORING.md) · [HUMAN_SKILL_ROADMAP.md](docs/HUMAN_SKILL_ROADMAP.md)
- [DUOKE_CONTENT_SKILL.md](docs/DUOKE_CONTENT_SKILL.md)
- [HERMES_SETUP.md](docs/HERMES_SETUP.md) · [BROWSER_PROFILE.md](docs/BROWSER_PROFILE.md)
- [DATA_PERMISSIONS.md](docs/DATA_PERMISSIONS.md) · [MCP_AUTOMEDIA.md](docs/MCP_AUTOMEDIA.md) · [N8N_MCP.md](docs/N8N_MCP.md)

**ADR:** [docs/adr/](docs/adr/)

## Layout

```
config/platform.yaml    # SSOT
config/skills/          # open-design skill trees
scripts/                # bash pipeline
docker/n8n/             # custom image
data/                   # runs, logs, secrets (gitignored outputs)
workflows/              # n8n export
```

