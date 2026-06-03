# n8n-mcp (Cursor debug bridge)

Upstream MCP server started by Cursor via `npx -y n8n-mcp`. It talks to the **n8n REST API**, not `data/runs` directly. Orthogonal to [automedia MCP](MCP_AUTOMEDIA.md) and the **8790 dashboard** (HTTP, not MCP).

## Setup (local only)

1. Copy the template into repo root (gitignored):

   ```bash
   cp .mcp.json.example .mcp.json
   ```

2. Set `N8N_API_KEY` in `.mcp.json` `env` from n8n UI (Settings → n8n API). **Do not commit** `.mcp.json`.

3. Set `N8N_API_URL` to a URL that answers `/healthz` from your environment:

   | Environment | Typical URL |
   |-------------|-------------|
   | Dev Container, n8n on host Docker | `http://host.docker.internal:5678` |
   | Linux host, n8n on same machine | `http://127.0.0.1:5678` or `http://localhost:5678` |
   | Scripts / gateway | Same as `.env` — see `GATEWAY_N8N_API_URL` and [`scripts/lib/n8n_api_url.sh`](../scripts/lib/n8n_api_url.sh) |

   Quick check:

   ```bash
   source scripts/lib/n8n_api_url.sh
   n8n_api_url_resolve_reachable
   curl -fsS "$(n8n_api_url_resolve_reachable | cut -d'|' -f1)/healthz"
   ```

4. In Cursor, enable MCP servers from `.mcp.json` (project root). Also use committed [`config/mcp/automedia.json`](../config/mcp/automedia.json) for run state — **two servers**, not one file.

## Offline bundle (no live API)

When n8n is down or MCP cannot connect:

```bash
bash scripts/capture_n8n_logs.sh --execution-id <ID> --run-id <RUN_ID>
```

Output under `data/logs/n8n-mcp/capture-*/` (`summary.json`, execution JSON, run artifacts).

## Manual verification (E3f / E6)

Repo automation cannot prove Cursor or Hermes loaded MCP. Record evidence yourself:

| ID | What to verify | How |
|----|----------------|-----|
| **E3f** | `n8n-mcp` stdio works in Cursor | Enable server in Cursor MCP panel; confirm no auth/URL errors; try a tool that lists workflows/executions (per upstream package). |
| **E6** | Hermes loads `config/hermes/mcp.json` | On Linux host: `cd ~/Auto_media && amctl apply`, start `hermes`, confirm automedia/playwright MCP appear in Hermes MCP UI or logs. Paths must match host repo after apply (see [HERMES_SETUP.md](HERMES_SETUP.md)). |

## Risks

- `npx -y` may pull different package versions over time; pin in `.mcp.json` if you need reproducibility.
- API keys with write scope may allow workflow changes via upstream tools — review before enabling in production n8n.

## Related

- [MCP_AUTOMEDIA.md](MCP_AUTOMEDIA.md) — run state MCP + empirical E1–E7 table
- [VERIFY.md](VERIFY.md) — `scripts/verify_mcp_evidence.sh`
- [MCP_AUTOMEDIA ADR](adr/automedia-mcp.md)
