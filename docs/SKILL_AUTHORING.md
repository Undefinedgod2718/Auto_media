# Skill authoring checklist (human co-creation)

Skills live under `config/skills/` and mount to `/data/config/skills/` in the n8n container.

上線簽核流程見 [HUMAN_SKILL_ROADMAP.md](HUMAN_SKILL_ROADMAP.md)。各技能目錄內有 `HUMAN_TODO.md` 勾選表。

## Required files

| Skill type | Files |
|------------|-------|
| Copywriter | `SKILL.md`, `BRAND.md`, `TEMPLATE.md` |
| SVG artist | `SKILL.md`, `PALETTE.md`, `RULES.md` |

## Review checklist

- [ ] No external URLs in SVG rules output
- [ ] Banned words listed in BRAND.md
- [ ] Output path instructions say "write only to file", not stdout
- [ ] `amctl skill validate <name>` passes
- [ ] Trial run with `AUTO_MEDIA_MOCK=0` produces acceptable `post.md` / `art.svg`
- [ ] Human approves 3 trial posts before `engines.*.status: active`

## Workflow

1. Copy `config/skills/_template/`.
2. Co-edit in **Dev Container** with `claude` (see [`DEVCONTAINER.md`](DEVCONTAINER.md)), or Hermes (`amctl ui hermes`), or your editor.
3. `git diff` + human sign-off.
4. `amctl skill use copy <name>` if using alternate mount.
5. Set `status: active` in `config/platform.yaml`.
6. `amctl apply`.

## Encoding

All skill files must be **UTF-8** (see repo `.editorconfig`).
