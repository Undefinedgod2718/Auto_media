# ADR: Auto Media MCP Server

## Status

Accepted

## Decision

Provide `scripts/mcp_automedia.py` as stdio MCP server for external LLM tools.

Scope:

- Read run status (`state.json`)
- Stage gate checks
- Optional stage writes (disabled by default)
- Doctor command wrapper

Safety:

- Writes are disabled unless `AUTO_MEDIA_MCP_WRITE=1`.
