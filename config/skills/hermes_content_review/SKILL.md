# Hermes 內容審閱（規則層）

本 skill 對應腳本 `scripts/hermes_content_review.sh`：依 `post.md`、`TASK.md` 的 `publish_targets` 與 `platform_limits.json` 產出 `hermes_plan.json`。

- **不重寫** `post.md`；僅輸出斷句建議、IG Caption 策略、圖張數與上限對照。
- Telegram Gateway 在 HITL 預覽前發送格式化說明。
