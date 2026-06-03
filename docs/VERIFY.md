# Verification guide

Minimal checks so the pipeline is runnable, observable, and safe to roll back. Install steps: [INSTALL.md](INSTALL.md).

## Goals

- Control plane produces correct runtime config.
- Mock pipeline completes one end-to-end run.
- n8n and gateway services are healthy.
- Installer and strict checks pass before production tokens.
- Plan B circuit breaker signal works.

## Test layers

### A. Config apply

```bash
uv sync
./scripts/amctl.sh apply
# or: uv run auto-media-apply
```

**Pass when:**

- `data/config/platform.runtime.json` exists
- `config/hermes/CONTEXT.md` and `config/hermes/mcp.json` updated

**If host lacks codex/gemini:**

```bash
AUTO_MEDIA_ALLOW_MISSING_CLI=1 ./scripts/amctl.sh apply
```

### B. Mock smoke (end-to-end)

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
```

**Pass when** all exist: `TASK.md`, `post.md`, `post.png`. `art.svg` is **optional** (legacy SVG skill path; PNG-first mock may skip it).

### C. Services (n8n + gateway)

```bash
docker compose build n8n gateway
docker compose up -d n8n gateway
docker compose ps
curl -fsS http://127.0.0.1:5678/healthz   # n8n
# gateway: use scripts/lib/gateway_url.sh or curl discovered base /healthz
```

**Pass when** n8n and gateway containers are running/healthy.

### D. Installer dry-run

```bash
bash scripts/setup_wizard.sh --dry-run
```

**Pass when:** exit code 0; **no** changes to `.env` or `data/state/install.json`; JSON from verify scripts printed.

Runs env-check, lists missing env keys (`n8n`, `telegram`, `gateway`, `llm`, `meta`, `threads`), runs CLI/Telegram verify (warn-only), Meta verify (report only), then doctor. Meta verify passing does not mean THREADS tokens were tested (see `skip THREADS` in output). After a real wizard run: `bash scripts/open_user_ui.sh` and `bash scripts/check_dashboard.sh`.

### D2. Release guard (GHCR / SemVer)

```bash
bash scripts/lib/release_guard.sh
```

**Pass when:** command exits 0; prints installed `release_tag` (if `data/state/install.json` exists) and GitHub latest tag when API reachable.

**Offline:** must not fail wizard dry-run; uses `AUTO_MEDIA_VERSION` from `.env` only.

**Pull-first stack** (after a published tag exists on GHCR):

```bash
# .env: AUTO_MEDIA_VERSION=v0.1.0
docker compose pull n8n gateway
docker compose up -d n8n gateway
bash scripts/post_docker_rebuild.sh
bash scripts/verify_mcp_evidence.sh
```

Align git tree with the same tag before pull. See [RELEASE.md](RELEASE.md).

### E. Strict verify (wizard completion)

After stack is up and `.env` is filled:

```bash
VERIFY_CLI_STRICT=1 bash scripts/verify_n8n_cli_auth.sh
VERIFY_TELEGRAM_STRICT=1 bash scripts/verify_telegram.sh
bash scripts/verify_meta_tokens.sh
```

A passing Meta verify does not mean THREADS was tested (unset `THREADS_*` yields `skip THREADS`).

Wizard retries failed groups (CLI OAuth, Telegram keys, Meta keys) up to `WIZARD_VERIFY_RETRIES` (default 3).

Optional deep check: `bash scripts/verify_n8n_claude_engine.sh` (copy runtime; does not replace the three-provider check).

### F. Doctor

```bash
bash scripts/amctl.sh doctor
```

Includes env-check, meta/gateway flow scripts, `ensure_n8n_oauth`, and:

- `verify_n8n_cli_auth.sh` with **VERIFY_CLI_STRICT=0** (warn if n8n down)
- `verify_telegram.sh` with **VERIFY_TELEGRAM_STRICT=0**

Wizard uses strict mode for E; doctor is looser for daily ops.

### G. Dashboard API (8790)

Start and verify (PyYAML via project venv — see [INSTALL.md](INSTALL.md) § User console):

```bash
bash scripts/open_user_ui.sh
bash scripts/check_dashboard.sh
```

**Pass when** `check_dashboard.sh` exits 0 (canonical :8790, `instance_rev` matches code, `/engines` up, :8788 not serving). Skill/engines unlock: default PIN `12345678` if `.env` has no `AUTO_MEDIA_DASHBOARD_WRITE_PIN` (override in Settings).

Optional manual checks after start:

| URL | Expect |
|-----|--------|
| `http://127.0.0.1:8790/api/engines/schema` | JSON `ok: true`, `engines.copy` / `engines.svg` |
| `http://127.0.0.1:8790/api/check/cli-auth` | `ok: true` when CLIs ready |
| `http://127.0.0.1:8790/api/check/telegram` | `ok: true` when bot + gateway ready |
| `http://127.0.0.1:8790/engines` | HTML engine priority page |

Stale UI or wrong port: [INSTALL.md](INSTALL.md) § User console — not bare `python3` without PyYAML.

### H. Plan B (circuit breaker)

```bash
# Example: write breaker signal (see script --help)
bash scripts/write_circuit_breaker.sh <RUN_ID> <STATUS> <BODY>
```

**Pass when:**

- `data/logs/api_dead.json` exists with run info
- `scripts/hermes-plan-b.sh` can read the signal (Hermes on Linux host)

See [HERMES_SETUP.md](HERMES_SETUP.md).

### I. MCP bridge evidence

After **docker compose build** n8n/gateway, prefer the all-in-one hook (apply + perms + secrets + MCP evidence):

```bash
bash scripts/post_docker_rebuild.sh
```

Or manually:

```bash
./scripts/amctl.sh apply    # refresh config/hermes/mcp.json (host repo paths)
bash scripts/verify_mcp_evidence.sh
```

**Pass when** script exits 0. **Warn-only** if dashboard `:8790` is down or `N8N_API_KEY` is unset.

| Item | Expect |
|------|--------|
| `config/mcp/automedia.json` | Repo paths for Cursor |
| `config/hermes/mcp.json` | Same repo root as `platform.runtime.json` `paths.repo_root_host` |
| n8n | `/healthz` on URL from `n8n_api_url_resolve_reachable` |
| Cursor n8n-mcp | Copy [`.mcp.json.example`](../.mcp.json.example) → `.mcp.json`, set key + URL — see [N8N_MCP.md](N8N_MCP.md) |

Full E1–E7 table: [MCP_AUTOMEDIA.md](MCP_AUTOMEDIA.md) § Empirical verification.

## Production gates

Do not publish via Meta API until all pass:

| Gate | Layer |
|------|--------|
| 1 | A — config apply |
| 2 | B — mock smoke artifacts |
| 3 | C — n8n healthy |
| 4 | H — circuit breaker file writable |
| 5 (production) | D dry-run + E strict + Meta tokens valid |

**Suggested order:** 1 → 2 → 3 → 4, then guided install (D/E) before live publish.

## Observability and rollback

- Watch `data/runs/*` for complete artifacts per stage.
- Watch `data/logs/api_dead.json` for accidental Plan B triggers.
- Watch n8n `healthz` after `.env` changes.
- Keep `publish.mode` on mock until gates pass; use Plan B on API failure instead of blocking the line.
- Config rollback: dashboard version API or restore from `data/versions/` snapshots.

## Related

- [INSTALL.md](INSTALL.md) — wizard, HITL, forwarder
- [N8N_WORKFLOW_SETUP.md](N8N_WORKFLOW_SETUP.md) — workflow UI setup
- [MCP_AUTOMEDIA.md](MCP_AUTOMEDIA.md) — MCP tools and E1–E7 evidence
- [N8N_MCP.md](N8N_MCP.md) — Cursor n8n-mcp `.mcp.json`
- [USER.md](../USER.md) — token settings and tests in browser
