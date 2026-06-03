# Engine failover (invoke-engine.sh)

Runtime uses **global** `engines.copy` and `engines.svg` in `config/platform.yaml` (after `amctl apply`). Change order in the console: `http://127.0.0.1:8790/engines`. Per-platform `engines.platforms.*.provider` / `fallback` are **not** consumed by `invoke-engine.sh` (skill_mount only).

## Chain (hardcoded default)

| Engine | Primary (platform.yaml) | Fallback order |
|--------|-------------------------|----------------|
| copywriter | `claude_cli` | `gemini_cli` → `codex_cli` |
| svg_artist | `codex_cli` | `gemini_cli` → `claude_cli` |

Override via `engines.copy.fallback` / `engines.svg.fallback` in [`config/platform.yaml`](../config/platform.yaml) after `amctl apply` → `data/config/platform.runtime.json`.

## Logs

Each attempt appends one JSON line to `data/logs/engine_failover.jsonl`:

```json
{"ts":"ISO8601Z","log":"engine_failover","run_id":"","engine":"copywriter","provider":"claude_cli","attempt":1,"ok":false,"error":""}
```

Success lines include `"ok": true` and stdout from invoke includes `"provider_used"`.

## PR-1 note

`invoke_codex_cli` no longer falls back to Gemini internally; all failover is via `invoke_with_failover`.
