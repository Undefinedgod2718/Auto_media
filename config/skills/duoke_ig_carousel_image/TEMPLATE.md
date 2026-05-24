# 輸出模板（寫入 post.md）

檔案開頭標題：

```markdown
# IG Carousel 圖像生成 Prompt — 多可競爭力
```

---

## 規劃摘要

- **主題：** {topic}
- **受眾：** {audience}
- **總頁數：** {N}
- **色調策略：** {一句話，如：1–2–6–8 暖米白；3–4–7 冷石灰；5 Accent 深炭黑}

### 頁面配置表

| 頁碼 | 類型 | 功能 | 主標／章節摘要 |
|------|------|------|----------------|
| 01 | A | Cover | … |
| 02 | B | Index | … |
| … | … | … | … |

---

## 各頁完整 Prompt（可直接複製）

> 每一區塊 = **VISUAL_BASE 全文** + **該頁已填模板** + 最後一行 `1080x1080 Instagram carousel slide`

### 頁 01 — Cover

```text
（在此貼上 VISUAL_BASE.md 的完整【視覺風格】～【整體氛圍關鍵字】區塊）

（在此貼上已填寫的 Cover 模板）

1080x1080 Instagram carousel slide, Editorial Minimalism, Talking2Win
```

### 頁 02 — Index

```text
…
```

（依總頁數重複至最後一頁 CTA）

---

## Instagram Caption（選填，供發文用）

{caption：Carousel 未涵蓋的補充論述，繁體中文，不推銷}

---

## 製作備註

- Step：依序貼入圖像工具 → 生成 → 微調 → 上傳 Carousel 順序。
- 若僅 `single_page`：只輸出對應一個「各頁完整 Prompt」小節。
