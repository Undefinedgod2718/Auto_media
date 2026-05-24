# Browser profile (Meta Plan B)

1. On Linux host with display (or VNC), launch Chromium once with:
  `--user-data-dir=/path/to/Auto_media/data/browser_profiles/meta`
2. Log in to Meta Business Suite manually (CAPTCHA if any).
3. Verify session persists after browser restart.
4. Playwright MCP / Hermes skill uses the same directory.

Do not commit `browser_profiles/` contents to git.