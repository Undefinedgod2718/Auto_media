# data/ 目錄權限策略

## 生產（Linux VPS / ext4）

- `docker-compose.yml` 使用 `user: "1000:1000"`，與 n8n 容器內 `node` 使用者一致。
- 每次 `amctl apply` 會執行 `scripts/fix-data-perms.sh`，確保 `data/runs/`、`data/logs/` 可寫。
- Repo 應位於 **ext4**（例如 `/opt/auto_media` 或 `~/Auto_media`）。

## 開發（單人本機）

可選粗暴模式（**僅開發**）：

```bash
export AUTO_MEDIA_DEV_PERMS=1
./scripts/amctl.sh apply
```

等同 `chmod -R a+rwX ./data`。**勿用於生產。**

## Windows + WSL2

| 做法 | 建議 |
|------|------|
| 在 `D:\...` bind mount 跑 n8n 生產 | **禁止**（NTFS 權限、I/O、`bash\r`） |
| 在 WSL2 `~/Auto_media`（ext4）跑 Docker | **建議** |
| 用 Dev Container 編輯與 `docker compose` | **建議** |

## 常見錯誤

**Execute Command 寫入 `/data/runs` 失敗（EACCES）**

1. 在 Linux 內執行：`./scripts/fix-data-perms.sh`
2. 確認 `data/runs` 擁有者為 UID 1000
3. 勿在 Windows 檔案總管手動建 run 目錄後指望容器可寫

**`bash\r: No such file or directory`**

`scripts/*.sh` 必須為 **LF** 換行（見 `.gitattributes`）。
