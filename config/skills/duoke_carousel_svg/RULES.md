# 多可 Carousel SVG 規則

## 畫布

- `width="1080"` `height="1080"` `viewBox="0 0 1080 1080"`。
- 單一根元素 `<svg>`，無 script、動畫、外部 `href`。

## 字體

- 僅 `font-family="sans-serif"`。
- 主標 `font-weight="bold"` `font-size` 約 56–72。
- 內文 `font-size` 約 28–36，`fill` 用 text_primary 或 text_on_dark。
- 角落英文標 `font-size` 約 18–22，`letter-spacing` 用較大字距模擬（可用空格或 `textLength`）。

## 版面（Swiss / Editorial）

- 左上：頁碼 `01 / 08` 格式。
- 右上：細框矩形 + 系列名（如 `words.` 或 `Talking2Win`）。
- 左緣：垂直文字（`transform="rotate(-90 ...)"`）系列主題。
- 中央偏左：主標 + `[INSIGHT]` 等方括號標籤。
- 底：0.5–1px 橫線（`<line>`）+ 引言雙引號。
- 右下：▼ 小三角（`<polygon>` 或 path）。

## Visual 頁

- 右側 40–55% 寬矩形占位，`fill` photo_placeholder，可疊 1–2 行「低飽和照片區」小字。
- 左側文字區與矩形 overlap（文字 z-index 在上）。

## Accent 頁

- 全頁 charcoal 底；主引言置中偏上，字級 48–64。

## 裝飾

- 僅細線、▼、淡色大數字；**禁止**漸層、filter 陰影、發光。

## 無障礙

- 深底淺字、淺底深字對比足夠；主標與內文分明。
