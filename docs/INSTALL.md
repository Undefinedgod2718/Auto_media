# Installation guide

Script-level setup for Auto Media. For day-to-day UI steps, see [USER.md](../USER.md).

## Choose a path

| Path | Command | When |
|------|---------|------|
| Guided (recommended) | `bash scripts/setup_wizard.sh` | First install, tokens, OAuth, HITL |
| Dry run | `bash scripts/setup_wizard.sh --dry-run` | Check deps and verify scripts; **no writes** |
| Non-interactive | `bash scripts/install.sh` | CI or repeat deploy; does not prompt for keys |

Dry run also accepts `WIZARD_DRY_RUN=1`.

## Flow (guided wizard)

```text
preflight (env-check)
  → uv sync (when uv present)
  → seed .env → prompt n8n / telegram / gateway
  → amctl apply + fix-data-perms
  → stop_old_dashboard + compose build/up n8n+gateway (--remove-orphans)
  → prompt llm / meta / threads
  → OAuth sync → conditional inject_n8n_secrets + n8n health wait
  → verify CLI (strict) → verify Telegram (strict) → verify Meta (warn; Meta OK does not mean THREADS was tested)
  → HITL ingress (webhook or forwarder profile)
  → wizard_finalize OR post_docker_rebuild (FORCE_REBUILD only)
  → doctor → data/state/install.json
```

| Path | When to use |
|------|-------------|
| `bash scripts/setup_wizard.sh` | First install, interactive tokens |
| `bash scripts/install.sh` | CI / non-interactive |
| `bash scripts/post_docker_rebuild.sh` | After `docker compose build` (not wizard’s default finale) |
| `bash scripts/wizard_finalize.sh` | Orphan cleanup + n8n/dashboard check without second `apply` |

Re-run is idempotent: reads `data/state/install.json`; skips image rebuild when `stack_built` and n8n is already up. Force rebuild: `WIZARD_FORCE_REBUILD=1` (runs full `post_docker_rebuild` at end).

If `install.json` `git_sha` differs from current `git rev-parse`, wizard warns to rebuild (`post_docker_rebuild` or `WIZARD_FORCE_REBUILD=1`).

## Preflight

```bash
bash scripts/env-check.sh
```

Requires Docker, Python 3, **curl**, jq, and CLI tools as listed. Fix failures before continuing.

## `.env` and secrets

- Wizard and dashboard write `.env` through [`scripts/lib/env_store.py`](../scripts/lib/env_store.py) (whitelist, no bash `source` for tokens with `$`).
- Interactive prompts: `PYTHONPATH=scripts/lib python3 scripts/lib/wizard_prompt.py --env .env --group telegram --apply`.
- Do not hand-edit tokens in a shell that `source`s `.env`; use Settings UI or wizard.

## Docker stack

```bash
docker compose build n8n gateway
docker compose up -d n8n gateway
```

Wizard runs this automatically. Gateway listens on **8787** (host / docker network). User console is **not** in compose; it runs on the host at **8790** via `open_user_ui.sh`.

## OAuth (interactive handoff)

Wizard cannot log in headless. On failure it asks you to:

1. Run `claude` / `codex` / `gemini` login on the host (or Dev Container).
2. Run `bash scripts/sync_claude_oauth.sh` (and codex / gemini equivalents).
3. Retry sync from the wizard prompt.

Then `ensure_n8n_oauth.sh` and `inject_n8n_secrets.sh` mirror credentials into the n8n container.

## HITL ingress (Telegram)

After stack is up, wizard calls `setup_production_hitl.sh`:

| `WEBHOOK_URL` in `.env` | Behavior |
|-------------------------|----------|
| Set (HTTPS) | Production webhook path; n8n may register Telegram trigger |
| Empty (local dev) | `deleteWebhook` + poll forwarder daemon |

**Poll mode (no public HTTPS):**

```bash
# Preferred (wizard does this automatically):
docker compose --profile forwarder up -d forwarder

# Host fallback:
bash scripts/forwarder_ctl.sh start
```

Do not run n8n Telegram Trigger and poll forwarder together. See [GATEWAY_DEPLOY.md](GATEWAY_DEPLOY.md) for production HTTPS.

## User console (8790)

```bash
bash scripts/open_user_ui.sh
```

`open_user_ui.sh` stops legacy dashboard ports (8788/8798/8799), frees **8790**, then starts `scripts/am_dashboard.py` with `.venv/bin/python3` when present. It verifies `/healthz` and `/api/instance` (prints `instance_rev`). To skip restart when already healthy: `DASHBOARD_NO_RESTART=1 bash scripts/open_user_ui.sh`.

Diagnose stale UI or wrong port:

```bash
bash scripts/check_dashboard.sh
```

- User hub: `http://127.0.0.1:8790/user`
- Tokens: `/settings` (masked display, PIN for writes)
- Skills: `/skills` (skill_mount mapping only)
- **Engine priority**: `/engines` — edits global `engines.copy` and `engines.svg` in `config/platform.yaml`

Per-platform `engines.platforms.*.provider` / `fallback` in YAML are **not** read by `invoke-engine.sh` (skill_mount only). See [ENGINE_FAILOVER.md](ENGINE_FAILOVER.md).

Unlock writes: default PIN `12345678` when `.env` has no `AUTO_MEDIA_DASHBOARD_WRITE_PIN`; change it in Settings (≥8 chars), then unlock on `/skills` or `/engines`. Avoid `AUTO_MEDIA_DASHBOARD_WRITE=1` except local dev.

**Do not use port 8788** (removed legacy dashboard). If the browser shows an old menu (no `/engines`), run `open_user_ui.sh` again or `check_dashboard.sh`.

## Config version history

Before console or wizard writes `platform.yaml`, `.env`, or skill files, snapshots go to `data/versions/` with a redacted `.env` copy. Rollback: dashboard `POST /api/versions/rollback` (PIN + CSRF). Details in [VERIFY.md](VERIFY.md).

## Align strict stage

Wizard sets `.env` `AUTO_MEDIA_STRICT_STAGE=0` to match compose default, avoiding drift with in-flight runs.

## After Docker rebuild

When you run `docker compose build n8n gateway` (or `WIZARD_FORCE_REBUILD=1`), refresh runtime config and verify the stack:

```bash
bash scripts/post_docker_rebuild.sh
```

This runs `amctl apply`, `fix-data-perms.sh`, optional `inject_n8n_secrets.sh` + n8n restart, n8n healthz, `verify_mcp_evidence.sh`, and optional `check_dashboard.sh`.

- **Usually skip** [`scripts/sync_scripts_to_n8n.sh`](../scripts/sync_scripts_to_n8n.sh) after a full image rebuild (scripts are COPY’d into the image at build time).
- Use `sync_scripts_to_n8n.sh` only when you changed repo `scripts/` **without** rebuilding the image.
- Flags: `--skip-secrets` (no n8n restart), `--skip-dashboard` (faster local pass).
- Removes orphan **`auto_media-dashboard-1`** (old :8788 compose service) via `--remove-orphans` + [`scripts/stop_old_dashboard.sh`](../scripts/stop_old_dashboard.sh). User UI is **host :8790** (`open_user_ui.sh`), not in compose.

## Related docs

- [VERIFY.md](VERIFY.md) — smoke, doctor, verify scripts
- [DEVCONTAINER.md](DEVCONTAINER.md) — Claude/Codex login in container
- [CLAUDE_CLI.md](CLAUDE_CLI.md) · [GEMINI_CLI.md](GEMINI_CLI.md) · [CODEX_DOCKER.md](CODEX_DOCKER.md)
- [N8N_WORKFLOW_SETUP.md](N8N_WORKFLOW_SETUP.md) — workflow in n8n UI
- [GATEWAY_DEPLOY.md](GATEWAY_DEPLOY.md) — Telegram → Gateway → n8n

## Appendix: contributor Git workflow

Use a feature branch (e.g. `feat/executive-installer`) and land changes in separate commits:

1. `feat(installer): interactive setup_wizard + env-check curl`
2. `feat(forwarder): compose forwarder service + forwarder_ctl`
3. `feat(console): global engine priority editor (engines.copy/svg)`
4. `feat(vc): config version history + rollback`
5. `fix(consistency): strict-stage drift, dashboard port docs, dead-config note`

Run `bash scripts/amctl.sh doctor` before each commit. Do not force-push `main`.
