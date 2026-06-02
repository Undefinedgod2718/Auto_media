# 多可（Talking2Win）內容 Skill 使用說明

## 技能目錄


| 目錄                            | 用途                                               | 產出        |
| ----------------------------- | ------------------------------------------------ | --------- |
| `duoke_threads_copywriter`    | Threads 5 則 + Carousel 文案與圖像 Prompt 摘要           | `post.md` |
| `**duoke_ig_carousel_image**` | **IG Carousel 全頁圖像生成 Prompt（VISUAL_BASE + A–F）** | `post.md` |
| `codex_svg_artist`            | **直接產 PNG**（含 VISUAL_BASE + A–F）；單張 `post.png` 或 `generate_carousel_images.sh` | `post.png` / `carousel/*.png` |
| `duoke_carousel_svg`          | （舊）向量 SVG，已由 PNG 流程取代                              | `art.svg` |


## 產 IG Carousel **圖片**（PNG，Editorial 風格）

Skill 目錄：`config/skills/codex_svg_artist/`（內含你提供的 **VISUAL_BASE**、**PAGE_TYPES A–F**、**BRAND**）

```bash
RUN_ID="ig-$(date +%Y%m%d-%H%M%S)"
./scripts/write_task.sh --run-id "$RUN_ID" \
  --topic "孩子寫功課五分鐘就開始晃" \
  --audience "幼兒園大班焦慮家長" \
  --action generate_carousel_images \
  --carousel-total 8

# 可選：先產文案 + 各頁 Prompt 到 post.md（copywriter + duoke_threads_copywriter）
# AUTO_MEDIA_MOCK=0 ./scripts/lib/invoke-engine.sh --run-id "$RUN_ID" --engine copywriter

# 批次產 8 張 PNG（codex → gemini → claude failover）
AUTO_MEDIA_MOCK=0 ./scripts/generate_carousel_images.sh --run-id "$RUN_ID"
```

產物：`data/runs/<RUN_ID>/carousel/01.png` … `08.png`，並複製 `01.png` → `post.png`（Telegram / Threads 預覽用）。

## 只產 Carousel **Prompt 文字**（手動貼 Canva / Gemini）

```bash
./scripts/amctl.sh skill use copy duoke_ig_carousel_image
./scripts/amctl.sh apply
AUTO_MEDIA_MOCK=0 ./scripts/lib/invoke-engine.sh --run-id "$RUN_ID" --engine copywriter
```

開啟 `data/runs/<RUN_ID>/post.md`，每頁有一段**可直接複製**到圖像工具的完整 Prompt。

### 只產單頁（例如封面）

```bash
./scripts/write_task.sh --run-id "$RUN_ID" \
  --topic "孩子不是故意不聽話" \
  --action single_page \
  --page-type A \
  --carousel-total 8
```

## 文案 + 圖 Prompt + SVG 預覽（完整流程）

```bash
./scripts/amctl.sh skill use copy duoke_threads_copywriter
./scripts/amctl.sh skill use svg duoke_carousel_svg
./scripts/amctl.sh apply

# … write_task + invoke copywriter + invoke svg_artist + render_png.sh
```

## Skill 檔案說明（圖像生成）


| 檔案               | 內容                |
| ---------------- | ----------------- |
| `VISUAL_BASE.md` | 固定基礎風格模組（每頁必含）    |
| `PAGE_TYPES.md`  | 類型 A–F 模板         |
| `BRAND.md`       | 色調一致、Accent 上限、禁語 |
| `TEMPLATE.md`    | `post.md` 輸出結構    |


## n8n

- **Set run context**：`topic`、`audience`
- **Write TASK.md**：`--carousel-total`（預設 8，Webhook 可傳 `carousel_total`）
- **Invoke copywriter** → **Sync carousel total**（從 `post.md` 總頁數回寫 TASK）→ **Invoke carousel images**
- **核准後**：`upload_carousel_catbox.sh` → Threads（`first_url`）／IG（全部 URL）／FB Page（選用）

## 人類簽核

各目錄 `HUMAN_TODO.md` · [HUMAN_SKILL_ROADMAP.md](HUMAN_SKILL_ROADMAP.md)