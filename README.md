# Homelab Stack

## 專案概覽
此專案部署於 Proxmox 上的 Ubuntu VM（`10.1.2.19`），透過 `docker-compose` 提供以下服務：
- Homepage
- Nginx Proxy Manager
- Portainer

## 目錄結構
- `docker-compose.yml`
- `deploy.sh`
- `homepage-config/`
  - `settings.yaml`
  - `services.yaml`
  - `widgets.yaml`
  - `docker.yaml`
  - `kubernetes.yaml`
  - `proxmox.yaml`
  - `bookmarks.yaml`
  - `custom.css`
  - `custom.js`
  - `logs/`

## 服務入口與網址
- Homepage: `http://home.local`
  - 若自建 DNS/hosts，請指到 `10.1.2.19`
- Nginx Proxy Manager: `http://10.1.2.19:81`
- Portainer: `http://10.1.2.19:9000`
  - 若使用反向代理可再掛 domain，例如 `http://portainer.local`（預設不是 https）

## 快速部署
```bash
./deploy.sh
```

## 更新方式
```bash
git pull && ./deploy.sh
```

## 常見問題
- `home.local` 的 Host validation
  - Homepage 預設會做 Host 驗證，若你用自訂網域或不同 IP，請調整 `HOMEPAGE_ALLOWED_HOSTS`。
  - 目前設定在 `docker-compose.yml` 的 `environment` 中，請確認包含你的網域/IP。

## 備份與還原
### 備份
```bash
./backup.sh
```
- 備份檔會輸出至 `./backups/`，檔名格式為 `homelab-stack_YYYYmmdd_HHMMSS.tgz`。
- 備份內容包含專案設定與 Docker named volumes（`portainer_data`、`npm_data`、`npm_letsencrypt`）。

### 還原
```bash
./restore.sh backups/xxx.tgz --force
```
- 還原會覆寫 Docker volumes 內容，需加上 `--force` 才會執行。
- 備份內的 `configs/` 會被複製到 `./_restore/<timestamp>/`，供人工比對，不會自動覆寫現有專案檔案。
