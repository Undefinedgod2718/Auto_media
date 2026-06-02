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

If browser does not auto-open, open this URL manually:

- `http://127.0.0.1:8788/user`

## 2) Fill tokens safely

1. Open **Token Settings** from `/user`.
2. Enter only fields you want to update.
3. Leave other fields empty (empty means no change).
4. Click **Save updates**.

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

## 6) Common issues

- **403 csrf failed**: open `/settings` from dashboard page directly and retry.
- **localhost only**: access from same machine only (`127.0.0.1` / `localhost`).
- **n8n test failed**: verify `N8N_API_URL` and whether n8n container is running.
- **Meta/Threads failed**: token may be expired; refresh token and save again.
