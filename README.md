# Homelab Stack (Proxmox / Ubuntu VM / Docker Compose)

這個 repo 用來在 Proxmox 上的 Ubuntu VM（Docker Host）以 Docker Compose 部署常用 Homelab 服務，並包含備份/還原與 systemd 排程。

## 目錄

- [1. 服務總覽](#1-服務總覽)
- [2. 架構與網路](#2-架構與網路)
- [3. 目錄結構](#3-目錄結構)
- [4. 需求與前置條件](#4-需求與前置條件)
- [5. 安裝與部署](#5-安裝與部署)
- [6. Homepage 設定](#6-homepage-設定)
- [7. Nginx Proxy Manager（NPM）設定](#7-nginx-proxy-managernpm-設定)
- [8. 更新策略（Watchtower）](#8-更新策略watchtower)
- [9. 通知（Kuma + Relay）](#9-通知kuma--relay)
- [10. 備份（systemd stack-backup）](#10-備份systemd-stack-backup)
- [11. 還原演練（低風險）](#11-還原演練低風險)
- [12. Docker prune（systemd）](#12-docker-prune-systemd)
- [13. 常見問題與排錯](#13-常見問題與排錯)
- [14. 安全注意事項](#14-安全注意事項)
- [15. 快速指令小抄](#15-快速指令小抄)

## 1. 服務總覽

以下以 `docker-compose.yml` 為準：

- **Homepage** (`ghcr.io/gethomepage/homepage`)
  - 建議透過 NPM 反代：`http://home.local`
- **Nginx Proxy Manager** (`jc21/nginx-proxy-manager`)
  - 管理介面：`http://<HOST_IP>:81`（目前 compose 綁定 `10.1.2.19:81`）
- **Portainer CE** (`portainer/portainer-ce`)
  - 目前沒有 publish `9000`，僅 docker network 內可達
  - 管理入口：透過 NPM 反代 `http://portainer.local`
- **Uptime Kuma** (`louislam/uptime-kuma:1`)
  - Compose publish：`http://<HOST_IP>:3001`（目前 `10.1.2.19:3001`）
  - 可透過 NPM 反代 `http://kuma.local`
- **Watchtower** (`containrrr/watchtower`)
  - 每日 04:00 依排程檢查更新（僅更新有 label 的容器）
- **kuma-push-relay** (`python:3.12-alpine`)
  - 本機 `127.0.0.1:18080` 提供 `/up` / `/down`，轉發到 Kuma push

> 注意：`<HOST_IP>` 目前在 compose 寫死 `10.1.2.19`，請改成你的 VM IP。
> 可選優化：把 compose 的 `10.1.2.19` 改成 `${HOST_IP}`，並在 `.env` 設定 `HOST_IP=你的IP`。

## 2. 架構與網路

### 2.1 流向（簡圖）

```
Client
  -> NPM (80/443)
     -> homepage:3000
     -> npm:81
     -> uptime-kuma:3001
     -> portainer (若有代理)

watchtower
  -> kuma-push-relay (/up, /down)
     -> uptime-kuma /api/push/<token>?status=...&msg=...
```

### 2.2 DNS / hosts 建議

- `home.local` -> `<HOST_IP>`
- `portainer.local` -> `<HOST_IP>`
- `kuma.local` -> `<HOST_IP>`

## 3. 目錄結構

```
.
├─ docker-compose.yml
├─ deploy.sh
├─ deploy-systemd-backup.sh
├─ deploy-systemd.sh
├─ backup.sh
├─ restore.sh
├─ .env.example
├─ .gitignore
├─ env/
│  ├─ watchtower.env.example
│  └─ kuma-relay.env.example
├─ docs/
│  └─ systemd-dropins.md
├─ scripts/
│  └─ stack-backup.sh
├─ systemd/
│  ├─ stack-backup.service
│  ├─ stack-backup.timer
│  └─ stack-backup.service.d.override.conf
│  ├─ docker-prune.service
│  └─ docker-prune.timer
├─ homepage-config/
│  ├─ settings.yaml
│  ├─ services.yaml
│  ├─ widgets.yaml
│  ├─ bookmarks.yaml
│  ├─ docker.yaml
│  ├─ kubernetes.yaml
│  ├─ proxmox.yaml
│  ├─ custom.css
│  ├─ custom.js
│  └─ logs/                 # Homepage runtime logs（不進版控）
└─ kuma-push-relay/
   └─ app.py
```

## 4. 需求與前置條件

- Docker Engine
- Docker Compose v2（`docker compose ...`）
- git / bash / tar

## 5. 安裝與部署

### 5.1 取得程式碼

```bash
git clone git@github.com:XiaoJunX1005/homelab-stack.git
cd homelab-stack
```

### 5.2 準備 env 檔（必填）

1) 複製 `.env.example` 到 `.env` 並改成你的 VM IP 與 CFG_DIR（若已有 `.env`，請補上 `HOST_IP` / `CFG_DIR`）：

```bash
cp .env.example .env
# 編輯 .env，改成你的 VM IP 與 CFG_DIR
```

> Docker Compose 會自動讀取 `.env`。請 **不要 commit** 真實 `.env`。
> 建議不要用 sudo 跑 `deploy.sh`，避免 `$HOME` 指到 `/root`；必要時請明確設定 `CFG_DIR=/home/<user>/.config`。

2) 以下兩個檔案必須存在，且**不要 commit**：

- `/home/test/.config/watchtower.env`
- `/home/test/.config/kuma-relay.env`

範例（repo 內提供模板，請複製到對應位置後再填值）：

```bash
mkdir -p "$CFG_DIR"
cp env/watchtower.env.example "$CFG_DIR/watchtower.env"
cp env/kuma-relay.env.example "$CFG_DIR/kuma-relay.env"
```

`$CFG_DIR/watchtower.env`
```
WATCHTOWER_NOTIFICATIONS=shoutrrr
WATCHTOWER_NOTIFICATION_URL=generic+http://kuma-push-relay:8080/up
WATCHTOWER_NOTIFICATION_URL_FAIL=generic+http://kuma-push-relay:8080/down
DOCKER_API_VERSION=1.53
```

`$CFG_DIR/kuma-relay.env`
```
KUMA_BASE_URL=http://uptime-kuma:3001/api/push/
KUMA_PUSH_TOKEN=<YOUR_KUMA_PUSH_TOKEN>
```

### 5.3 啟動

```bash
chmod +x deploy.sh
./deploy.sh
```

### 5.3.1 systemd timers（備份/清理）

```bash
sudo ./deploy-systemd.sh
```

安裝後請編輯 `/etc/default/homelab-stack`（必填：`HOST_IP` / `CFG_DIR` / `STACK_DIR`）。

### 5.4 檢查

```bash
docker compose ps
```

> 若不確定服務名稱，先用 `docker compose config --services` 查看。

## 6. Homepage 設定

Homepage 的設定檔用 bind mount：

- Host：`./homepage-config`
- Container：`/app/config`

常用檔案：

- `homepage-config/services.yaml`
- `homepage-config/widgets.yaml`
- `homepage-config/settings.yaml`
- `homepage-config/bookmarks.yaml`

### 6.1 Docker Provider（讓 Homepage 讀到容器狀態）

`homepage-config/widgets.yaml`

```yaml
- docker:
    host: unix:///var/run/docker.sock
```

`homepage-config/settings.yaml`

```yaml
providers:
  docker:
    host: unix:///var/run/docker.sock
```

並確保 `docker-compose.yml` 有掛 socket（唯讀）：

```yaml
- /var/run/docker.sock:/var/run/docker.sock:ro
```

### 6.2 group_add 984 的來源

`homepage` 需要讀 docker.sock，`group_add: "984"` 是 docker group 的 GID。請用下列方式查你的環境 GID：

```bash
stat -c %g /var/run/docker.sock
# 或
getent group docker
```

## 7. Nginx Proxy Manager（NPM）設定

### 7.1 Homepage

Proxy Host：

- Domain Names：`home.local`
- Scheme：`http`
- Forward Hostname / IP：`homepage`
- Forward Port：`3000`
- Websockets Support：建議開
- Block Common Exploits：建議開

### 7.2 Uptime Kuma

- Domain Names：`kuma.local`
- Forward Hostname / IP：`uptime-kuma`
- Forward Port：`3001`

### 7.3 Portainer

目前 `portainer` 沒 publish `9000`，所以只能透過 NPM 代理。完成後可用：

- `http://portainer.local`

> 注意：如果沒有 SSL 憑證，不要把 `http://xxx.local` 改成 `https://xxx.local`。

## 8. 更新策略（Watchtower）

- 以 **白名單模式** 運作（`--label-enable`）
- 只有帶 `com.centurylinklabs.watchtower.enable=true` 的容器會更新
- `--cleanup` 會清舊 image，回滾能力下降（請留意）
- 排程：`"0 0 4 * * *"`（每天 04:00）

常用檢查：

```bash
docker compose ps
docker logs watchtower --tail 80
```

### 8.1 Log Rotation

所有長跑服務皆使用 `json-file` log rotation：

- `max-size: "10m"`
- `max-file: "3"`

## 9. 通知（Kuma + Relay）

### 9.1 為什麼需要 relay

Watchtower 的 shoutrrr generic 預設 **POST + application/json**，但 Uptime Kuma push endpoint 主要採用 query 參數（`status/msg/ping`）的 **GET**，直接對接常會出錯。

### 9.2 目前方案

- Watchtower 通知打 `kuma-push-relay`：
  - `/up` / `/down`
- Relay 轉成 Kuma push：
  - `/api/push/<token>?status=...&msg=...`

### 9.3 驗證指令

```bash
# host 端（若只在 localhost 開 port）
curl http://127.0.0.1:18080/up

# 走 docker network
curl http://kuma-push-relay:8080/up

# 檢查 relay log
docker logs kuma-push-relay --tail 80
```

> Kuma push token 屬於敏感資訊，**不要 commit**。

## 10. 備份（systemd stack-backup）

### 10.1 正式備份方案

- systemd timer：`stack-backup.timer`
- 排程時間：每天 04:10（避開 watchtower 04:00）
- 產物目錄：`/opt/stack-backups/stack/`
- 內容：
  - `compose.tar.gz`
  - `volume-*.tar.gz`
  - `volumes.txt`

目前實際備份的 volumes：

- `portainer_data`
- `npm_data`
- `npm_letsencrypt`
- `uptimekuma_data`

> `homepage` 使用 bind mount（`./homepage-config`），已包含在 `compose.tar.gz`。

### 10.2 一鍵安裝

```bash
sudo ./deploy-systemd.sh
```

### 10.3 檢查

```bash
systemctl list-timers --all | rg 'stack-backup|docker-prune'
journalctl -u stack-backup.service -n 120 --no-pager
```

更多覆寫範本請見 `docs/systemd-dropins.md`。

### 10.4 嚴禁把備份進版控（非常重要）

NPM 的 `npm_letsencrypt` 內含私鑰/憑證，備份檔 commit 等同外洩。

### 10.5 關於 repo 內的 `backup.sh`

`backup.sh` 為舊版/手動使用的備份腳本；正式排程以 `stack-backup.timer` 為主。

## 11. 還原演練（低風險）

### 11.A Restore Drill（僅驗證資料，不啟動服務）

```bash
latest="$(ls -t /opt/stack-backups/stack/stack-*.tar.gz | head -1)"
restore_dir="/opt/stack-restoretest"
mkdir -p "$restore_dir"
tar xzf "$latest" -C "$restore_dir"

# 列出備份內容
tar tzf "$latest" | head -n 50

# 確認 volumes.txt 與實際 tar 一致
cat "$restore_dir/volumes.txt"
ls -lh "$restore_dir"/volume-*.tar.gz

# 可選：抽查檔案是否存在（不啟動容器）
# 例如 NPM 的 data、Kuma 的 sqlite（路徑依實際版本可能不同）
```

### 11.B Restore Drill（實際啟動，隔離現網）

> 原則：用不同 project name，並避免 ports 衝突（可改 ports 或不 publish）。

```bash
latest="$(ls -t /opt/stack-backups/stack/stack-*.tar.gz | head -1)"
restore_dir="/opt/stack-restoretest"
mkdir -p "$restore_dir"
tar xzf "$latest" -C "$restore_dir"

# 還原 compose
mkdir -p /opt/stack-restoretest/compose
tar xzf "$restore_dir/compose.tar.gz" -C /opt/stack-restoretest/compose
cd /opt/stack-restoretest/compose

# 建議：使用 override 檔把 ports 清掉或改成不衝突
# 例如建立 docker-compose.override.yml，把 ports 整段移除或改成 127.0.0.1:xxxxx

# 建立新 volumes（restoretest_*）
for f in "$restore_dir"/volume-*.tar.gz; do
  vol="$(basename "$f" | sed 's/^volume-//; s/\.tar\.gz$//')"
  new_vol="restoretest_${vol}"
  docker volume create "$new_vol" >/dev/null
  docker run --rm -v "${new_vol}:/data" -v "$restore_dir:/backup" alpine:3.19 \
    sh -c "rm -rf /data/* && tar xzf /backup/$(basename "$f") -C /data"
done

# 使用不同 project name 啟動
COMPOSE_PROJECT_NAME=restoretest docker compose up -d

# 驗證（可只驗證一個服務，如 Uptime Kuma）
# docker logs uptime-kuma --tail 80

# 清理
# COMPOSE_PROJECT_NAME=restoretest docker compose down -v
```

## 12. Docker prune（systemd）

本機有 `docker-prune.timer`，每週清除超過 7 天未使用的 image：

```bash
systemctl list-timers --all | rg 'stack-backup|docker-prune'
systemctl status docker-prune.timer --no-pager
```

### 12.1 systemd 預設值

系統級設定檔（可改）：

- `/etc/default/homelab-stack`

主要欄位（最少要改 `CFG_DIR` 與 `STACK_DIR`）：

- `CFG_DIR`
- `STACK_DIR`
- `BACKUP_DIR`
- `PROJECT_NAME`
- `KEEP_DAYS`
- `PRUNE_UNTIL_HOURS`

### 12.2 systemd 檢查指令

```bash
systemctl cat stack-backup.service
sudo cat /etc/default/homelab-stack
sudo systemctl start stack-backup.service
sudo journalctl -u stack-backup.service -n 120 --no-pager
```

## 13. 常見問題與排錯

### 13.1 服務名稱/容器名稱不一致

請先用以下指令確認名稱，再進行操作：

```bash
docker compose config --services
docker compose ps
```

若要看 log，可使用 container_name：

```bash
docker logs nginx-proxy-manager --tail 80
docker logs uptime-kuma --tail 80
docker logs watchtower --tail 80
```

### 13.2 Homepage 顯示 Host validation failed

log 會看到：

```
Host validation failed
```

在 `docker-compose.yml` 的 `HOMEPAGE_ALLOWED_HOSTS` 補上你常用的 hostname / IP。

## 14. 安全注意事項

- **不要 commit secrets**（token、API key、憑證）
- **不要 commit 備份檔**（`*.tgz` / `*.tar.gz`）
- NPM 的 `npm_letsencrypt` 內含私鑰/憑證

## 15. 快速指令小抄

```bash
# 啟動 / 更新
./deploy.sh

# 檢查容器
docker compose ps

# Watchtower log
docker logs watchtower --tail 80

# 備份
sudo systemctl start stack-backup.service

# 還原（會覆寫 volumes）
# 參考第 11 章
```
