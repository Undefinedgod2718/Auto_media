# Auto Media User Guide (Non-Engineer)

This guide is for daily operation without editing code.

## 0) First-time install (guided)

```bash
bash scripts/setup_wizard.sh --dry-run   # check only, no file changes
bash scripts/setup_wizard.sh             # full install
```

Script details (OAuth, HITL, forwarder): [docs/INSTALL.md](docs/INSTALL.md). Verification checklist: [docs/VERIFY.md](docs/VERIFY.md).

## 1) Open user interface

Use dashboard **8790** only; port **8788** is obsolete. Start, restart, and diagnose: [docs/INSTALL.md](docs/INSTALL.md) § User console (`bash scripts/open_user_ui.sh`, `bash scripts/check_dashboard.sh`).

## 2) Fill tokens safely

1. Open **Token Settings** from `/user`.
2. Enter only fields you want to update.
3. Leave other fields empty (empty means no change).
4. Click **Save updates** — dashboard writes `.env`, runs `docker compose up -d n8n`, then `verify_meta_tokens.sh` (results in the black box under `apply`).

The page never returns token plaintext. It only shows masked values or set/unset.

## 3) Test connection

Use these buttons in `/settings`:

- `Test telegram`
- `Test n8n`
- `Test meta`
- `Test threads`
- `Test all`

Read the result box. `ok: true` means that check passed.

## 4) Health check (safe output)

```bash
scripts/am-user doctor-lite
```

This prints environment checks with sensitive key-style patterns redacted.

## 5) Allowed fields in settings page

- `N8N_ENCRYPTION_KEY`
- `N8N_API_URL`
- `N8N_API_KEY`
- `WEBHOOK_URL`
- `TELEGRAM_BOT_TOKEN`
- `TELEGRAM_CHAT_ID`
- `TELEGRAM_WEBHOOK_SECRET`
- `GATEWAY_INTERNAL_SECRET`
- `META_PAGE_ID`
- `META_PAGE_ACCESS_TOKEN`
- `META_GRAPH_API_VERSION`
- `IG_USER_ID`
- `THREADS_USER_ID`
- `THREADS_ACCESS_TOKEN`
- `ANTHROPIC_API_KEY`
- `CLAUDE_CODE_OAUTH_TOKEN`
- `GEMINI_API_KEY`
- `AUTO_MEDIA_DASHBOARD_WRITE_PIN` (optional; default unlock `12345678` if unset)

## 6) Skill Manager (read-only by default)

1. Open **Skill Manager** (`http://127.0.0.1:8790/skills`) or **引擎優先權** (`/engines`).
2. Enter PIN (default **`12345678`** until you save a custom PIN in Settings) and click **解鎖**. Status shows **可寫入**.
3. Edit mapping or files, then **儲存** — the page reloads automatically on success.
4. To change PIN: **權杖設定** → `AUTO_MEDIA_DASHBOARD_WRITE_PIN` (≥8 chars) → Save → unlock again with the new PIN.

Engineers only: `AUTO_MEDIA_DASHBOARD_WRITE=1` when starting the dashboard skips PIN (local dev).

## 6b) Engine priority (copy / svg)

Open **引擎優先權** (`http://127.0.0.1:8790/engines`). Unlock with the same PIN as Skill Manager, set **文案** / **圖像** provider order, **儲存**. Failover: [docs/ENGINE_FAILOVER.md](docs/ENGINE_FAILOVER.md).

## 7) Common issues

- **403 csrf failed**: open `/settings` from dashboard page directly and retry.
- **localhost only**: access from same machine only (`127.0.0.1` / `localhost`).
- **n8n test failed**: verify `N8N_API_URL` and whether n8n container is running.
- **Meta/Threads failed**: token may be expired; refresh token and save again.
