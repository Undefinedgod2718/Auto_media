# Meta limits (SSOT)

This folder stores platform API limits and quota defaults used by:

- `scripts/lib/platform_limits.py`
- `scripts/check_platform_limits.sh`
- `scripts/notify_platform_limit.sh`
- dashboard and MCP tools

Files:

- `limits.json`: hard limits (characters, caption, carousel items, image size)
- `quotas.json`: per-window quota defaults for operational dashboards
- `schema.json`: JSON schema for validation/edit UI

Compatibility:

- Legacy path `data/config/platform_limits.json` is still supported as fallback.
- New code should read from `config/meta/limits.json`.
