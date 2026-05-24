# 多可（Talking2Win）內容 Skill 使用說明

## 技能目錄


| 目錄                            | 用途                                               | 產出        |
| ----------------------------- | ------------------------------------------------ | --------- |
| `duoke_threads_copywriter`    | Threads 5 則 + Carousel 文案與圖像 Prompt 摘要           | `post.md` |
| `**duoke_ig_carousel_image**` | **IG Carousel 全頁圖像生成 Prompt（VISUAL_BASE + A–F）** | `post.md` |
| `duoke_carousel_svg`          | 單張編輯風海報（向量 SVG，可轉 PNG）                           | `art.svg` |


## 只產 Carousel 圖文 Prompt（推薦）

```bash
./scripts/amctl.sh skill use copy duoke_ig_carousel_image
./scripts/amctl.sh apply
```

```bash
RUN_ID="ig-$(date +%Y%m%d-%H%M%S)"
./scripts/write_task.sh --run-id "$RUN_ID" \
  --topic "孩子寫功課五分鐘就開始晃" \
  --audience "幼兒園大班焦慮家長" \
  --action generate_carousel_images \
  --carousel-total 8

AUTO_MEDIA_MOCK=0 ./scripts/lib/invoke-engine.sh --run-id "$RUN_ID" --engine copywriter
```

開啟 `data/runs/<RUN_ID>/post.md`，每頁有一段**可直接複製**到 Canva AI / 圖像模型的完整 Prompt。

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
- **Write TASK.md**：`action` 設 `generate_carousel_images`；可選 `carousel_total: 8`
- **Invoke copywriter**：使用已掛載的 `duoke_ig_carousel_image` skill

## 人類簽核

各目錄 `HUMAN_TODO.md` · [HUMAN_SKILL_ROADMAP.md](HUMAN_SKILL_ROADMAP.md)