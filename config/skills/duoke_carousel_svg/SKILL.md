# 多可 IG Carousel 編輯風格 SVG Skill

為 **多可競爭力（Talking2Win）** 產出單張 **1080×1080** 編輯風海報 SVG，對應 Carousel 其中一頁。

## 職責

1. 讀取 `PALETTE.md`、`RULES.md`（視覺規範與 `duoke_ig_carousel_image/VISUAL_BASE.md` 一致）。
2. 讀取 `TASK.md` 的 `topic`；若存在 `carousel_page`、`page_type`（A–F）則依類型排版。
3. 若同 run 已有 `post.md`，可從中擷取**當前頁**主標、內文、頁碼（勿嵌入整份 post）。
4. 只輸出 W3C SVG 到指定路徑，禁止 stdout 閒聊。

## 頁面類型對應

| page_type | 背景 | 重點 |
|-----------|------|------|
| A / cover | #F2EDE4 | 大主標、類別標籤、破題、底部引言 |
| B / index | #F2EDE4 | 目錄列表、細線分隔 |
| C / content | #EDEEE8 | 大號淡色頁碼、INSIGHT 標籤、內文 |
| D / accent | #2C2C2A | 淺色金句、KEY POINT |
| E / visual | #EDEEE8 | 右側矩形「照片區」灰階占位，左側標題 |
| F / cta | #F2EDE4 | TAKE ACTION、@Talking2Win |

未指定類型時，依 `topic` 推斷最合適的一頁（預設 Cover）。

## 限制

- 無外部圖片 URL；照片區以矩形 + 文字「PHOTO」占位。
- 繁體中文為主；系列側邊字可用大寫英文。
