# Auto Media — Architecture (ADD summary)

Self-hosted social image/text pipeline: **n8n** orchestration, **file-based Skills** (open-design), **Hermes** Plan B supervisor.

## Layers

| Layer | Component |
|-------|-----------|
| Control | `config/platform.yaml` + `amctl.sh` |
| Orchestration | n8n (Docker, custom image) |
| Generation | Claude CLI + Codex CLI via `invoke-engine.sh` |
| Render | rsvg-convert → 1080 PNG |
| HITL | Telegram + n8n Wait |
| Plan A publish | Meta Graph API |
| Plan B | Hermes + Playwright (`api_dead.json`) |

## References

- [n8n](https://github.com/n8n-io/n8n)
- [Hermes Agent](https://github.com/nousresearch/hermes-agent)
- [open-design](https://github.com/nexu-io/open-design)

See [README.md](../README.md) for operations.
