# Carousel 快速流程

1. 確認總頁數（建議 6–8）
2. 決定每張類型（A / B / C / D / E / F）— 見 `PAGE_TYPES.md` 建議 8 頁表
3. 依字數限制分配文案
4. 每張 = `VISUAL_BASE` 全文 + 類型模板（已填）+ 行尾 `1080x1080 Instagram carousel slide`

## 自動化（本 repo）

```bash
python3 scripts/lib/task_md.py --run-id "$RUN_ID" --topic "…" --audience "…" \
  --action generate_carousel_images --carousel-total 8
./scripts/generate_carousel_images.sh --run-id "$RUN_ID"
```

產物：`data/runs/<RUN_ID>/carousel/01.png` … `08.png`，並複製 `01.png` → `post.png` 供 Telegram / Threads 預覽。

手動只產 Prompt 文字（不畫圖）：改用 skill `duoke_ig_carousel_image` + copywriter 引擎。
