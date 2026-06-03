# Auto Media User Guide (Non-Engineer)

This guide is for daily operation without editing code.

## 1) Open user interface

```bash
bash scripts/open_user_ui.sh
```

Or:

```bash
scripts/am-user open
```

If browser does not auto-open, open:

- `http://127.0.0.1:8790/user`
- Token settings: `http://127.0.0.1:8790/settings`

Settings page must show `port 8790` and `.env: .../Auto_media/.env`. Port **8788** was removed (old docker dashboard).

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
- `AUTO_MEDIA_DASHBOARD_WRITE_PIN` (Skill Manager unlock; min 8 characters)

## 6) Skill Manager (read-only by default)

1. Open **Token Settings** (`http://127.0.0.1:8790/settings`) and set **AUTO_MEDIA_DASHBOARD_WRITE_PIN** (at least 8 characters). Save.
2. Open **Skill Manager** (`http://127.0.0.1:8790/skills`).
3. Enter the same PIN and click **解鎖** (Unlock). Status shows **可寫入**.
4. Edit platform mapping or skill files, then **儲存對應** / **儲存檔案**.
5. Click **鎖定** when finished, or close the browser tab (unlock lasts about 8 hours on this machine).

Engineers only: `AUTO_MEDIA_DASHBOARD_WRITE=1` when starting the dashboard skips PIN (local dev).

## 7) Common issues

- **403 csrf failed**: open `/settings` from dashboard page directly and retry.
- **localhost only**: access from same machine only (`127.0.0.1` / `localhost`).
- **n8n test failed**: verify `N8N_API_URL` and whether n8n container is running.
- **Meta/Threads failed**: token may be expired; refresh token and save again.
