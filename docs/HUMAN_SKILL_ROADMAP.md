# 人類協作：Skill 上線路線圖

工程骨架已完成；**內容品質**須由人類審核後才能視為 production。

## claude_copywriter

| 步驟 | 動作 | 完成 |
|------|------|------|
| 1 | 在 Dev Container 執行 `claude`，共編 `config/skills/claude_copywriter/*.md` | ☐ |
| 2 | `amctl skill validate claude_copywriter` | ☐ |
| 3 | `AUTO_MEDIA_MOCK=0` 試跑 3 次，檢查 `data/runs/*/post.md` 語氣一致 | ☐ |
| 4 | 人工簽核後維持 `engines.copy.status: active` | ☐ |

## codex_svg_artist

| 步驟 | 動作 | 完成 |
|------|------|------|
| 1 | 在 Dev Container 執行 `codex`，共編 `PALETTE.md`、`RULES.md` | ☐ |
| 2 | `amctl skill validate codex_svg_artist` | ☐ |
| 3 | 產出 SVG 通過 `xmllint` / `rsvg-convert`，預覽 1080×1080 | ☐ |
| 4 | 人工簽核後維持 `engines.svg.status: active` | ☐ |

## 暫停上線

若尚未審核，將 `config/platform.yaml` 改為：

```yaml
engines:
  copy:
    status: draft
  svg:
    status: draft
```

`invoke-engine.sh` 在 non-mock 模式下會拒絕 `draft` 引擎。

詳見 [SKILL_AUTHORING.md](SKILL_AUTHORING.md)。
