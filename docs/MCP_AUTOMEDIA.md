# Auto Media MCP

`automedia-mcp` exposes a small MCP stdio server for external LLM hosts.

Server script:

- `scripts/mcp_automedia.py`

Config template:

- `config/mcp/automedia.json`

## Tools

- `run_get_status` (read run `state.json`)
- `run_require_stage` (check `stage_seq` threshold)
- `run_mark_stage` (write-enabled only)
- `doctor` (runs `scripts/env-check.sh`)

## Safety

Write operations are disabled by default.  
Enable only when needed:

```bash
AUTO_MEDIA_MCP_WRITE=1 python3 scripts/mcp_automedia.py
```

## Integration

For Cursor or other MCP clients, copy `config/mcp/automedia.json` and adjust absolute paths.
