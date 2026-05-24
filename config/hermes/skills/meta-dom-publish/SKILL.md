# Meta DOM Publish (Plan B)

Triggered when `/data/logs/api_dead.json` exists (Graph API circuit breaker).

## Steps

1. Read `api_dead.json` for `png_path`, `caption_path`, `run_id`.
2. Launch Playwright with `--user-data-dir=/data/browser_profiles/meta`.
3. Open Meta Business Suite, upload image, paste caption, publish.
4. On success: archive learnings to Hermes skill memory; delete or rename `api_dead.json`.
5. Always: `browser.close()` and ensure no stray chromium processes (`pkill -f chromium` if needed).

## Safety

- Low frequency only (circuit breaker).
- Never automate login; use persisted profile from manual first login.
