```md
# Homelab Stack（Proxmox / Ubuntu VM / Docker Compose）

這個 Repo 用來在 Proxmox 上的 Ubuntu VM（Docker Host）以 Docker Compose 部署常用 Homelab 服務（Homepage / Nginx Proxy Manager / Portainer），並提供備份與還原腳本，方便把整套環境（含 named volumes）打包保存。

---

## 目錄

- [1. 服務總覽](#1-服務總覽)
- [2. 架構與網路](#2-架構與網路)
- [3. 目錄結構](#3-目錄結構)
- [4. 需求與前置條件](#4-需求與前置條件)
- [5. 安裝與部署](#5-安裝與部署)
- [6. Homepage 設定](#6-homepage-設定)
- [7. Nginx Proxy Manager（NPM）設定](#7-nginx-proxy-managernpm-設定)
- [8. 更新與維護](#8-更新與維護)
- [9. 備份（backup.sh）](#9-備份backupsh)
- [10. 還原（restore.sh）](#10-還原restoresh)
- [11. 常見問題與排錯](#11-常見問題與排錯)
- [12. 安全注意事項](#12-安全注意事項)
- [13. 快速指令小抄](#13-快速指令小抄)

---

## 1. 服務總覽

本 Stack 目前包含：

- **Homepage**（`ghcr.io/gethomepage/homepage`）
  - 建議透過 NPM 反代提供 `http://home.local`
- **Nginx Proxy Manager**（`jc21/nginx-proxy-manager`）
  - 管理入口：`http://<DOCKER_HOST_IP>:81`
- **Portainer CE**（`portainer/portainer-ce`）
  - 管理入口：`http://<DOCKER_HOST_IP>:9000`
  - 也可透過 NPM 反代 `http://portainer.local`

> 重要：如果你沒有在 NPM 配好 SSL 憑證，就不要把 `http://xxx.local` 改成 `https://xxx.local`，會直接連不上。

---

## 2. 架構與網路

- Proxmox：VM Host
- Ubuntu VM：Docker Host（例：`10.1.2.19`）
- Docker Compose：管理全部容器
- 對外入口：通常由 NPM（80/443）負責反代
- Homepage：通常不直接 publish 3000，改讓 NPM 反代到 `homepage:3000`

### 2.1 DNS / hosts 建議

如果你沒有內網 DNS（Pi-hole / AdGuard / Router DNS），可以先用 hosts：

- `home.local` → `10.1.2.19`
- `portainer.local` → `10.1.2.19`

---

## 3. 目錄結構

```

.
├─ docker-compose.yml
├─ deploy.sh
├─ backup.sh
├─ restore.sh
├─ .gitignore
└─ homepage-config/
├─ settings.yaml
├─ services.yaml
├─ widgets.yaml
├─ bookmarks.yaml
├─ docker.yaml
├─ kubernetes.yaml
├─ proxmox.yaml
├─ custom.css
├─ custom.js
└─ logs/                 # Homepage runtime logs（不建議進版控）

````

---

## 4. 需求與前置條件

Ubuntu VM 需要：

- Docker Engine
- Docker Compose v2（`docker compose ...`）
- git
- bash / tar

---

## 5. 安裝與部署

### 5.1 取得程式碼

```bash
git clone git@github.com:XiaoJunX1005/homelab-stack.git
cd homelab-stack
````

### 5.2 啟動

```bash
chmod +x deploy.sh backup.sh restore.sh
./deploy.sh
```

### 5.3 檢查

```bash
docker compose ps
```

---

## 6. Homepage 設定

Homepage 的設定檔用 bind mount：

* Host：`./homepage-config`
* Container：`/app/config`

你常改的檔案：

* `homepage-config/services.yaml`：卡片 / 服務清單
* `homepage-config/widgets.yaml`：上方 widget（資源、時間、docker…）
* `homepage-config/settings.yaml`：整體設定（title/theme/provider…）
* `homepage-config/bookmarks.yaml`：書籤列

### 6.1 Docker Provider（讓 Homepage 讀到容器狀態）

建議設定（你目前已完成）：

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

---

## 7. Nginx Proxy Manager（NPM）設定

### 7.1 Homepage（建議）

新增 Proxy Host：

* Domain Names：`home.local`
* Scheme：`http`
* Forward Hostname / IP：`homepage`
* Forward Port：`3000`
* Websockets Support：建議開
* Block Common Exploits：建議開

> 前提：NPM 與 Homepage 在同一個 compose network（同一份 `docker-compose.yml` 通常就 OK）。

### 7.2 Portainer（無 TLS 先用 http）

如果 NPM 沒有憑證，就先用：

* `http://portainer.local`

等你把 NPM 的 SSL（Let’s Encrypt / 自簽）搞定再切：

* `https://portainer.local`

---

## 8. 更新與維護

### 8.1 拉最新版本並重新部署

```bash
git pull
./deploy.sh
```

### 8.2 只重啟某個服務

```bash
docker compose restart homepage
docker compose restart npm
docker compose restart portainer
```

---

## 9. 備份（backup.sh）

`backup.sh` 會把：

* Repo 重要設定檔（docker-compose / homepage-config 等）
* 以及指定的 Docker named volumes（例如 `*_npm_data`, `*_npm_letsencrypt`, `*_portainer_data`）

打包成單一 `.tgz`，放在 `./backups/`。

### 9.1 執行

```bash
./backup.sh
```

---

## 10. 還原（restore.sh）

`restore.sh` 用來從備份檔還原：

* 會停止現有服務
* 解壓備份
* 覆寫並還原 volumes
* 重新 `docker compose up -d`

### 10.1 執行（需要 --force）

```bash
./restore.sh backups/<YOUR_BACKUP>.tgz --force
```

> 重要：還原會覆寫 volumes，請確認目標環境可接受被覆蓋。

---

## 11. 常見問題與排錯

### 11.1 Homepage 顯示 Host validation failed

log 會看到：

```
Host validation failed for: home.local
Hint: Set the HOMEPAGE_ALLOWED_HOSTS environment variable ...
```

解法：在 `docker-compose.yml` 的 homepage 增加（依你使用的 domain/IP 調整）：

```yaml
environment:
  - HOMEPAGE_ALLOWED_HOSTS=home.local,10.1.2.19
```

然後重建：

```bash
docker compose up -d --force-recreate homepage
```

### 11.2 容器內沒有 curl / wget 不支援 unix-socket

Homepage 容器可能沒有 `curl`，`wget` 也可能是 BusyBox 版不支援 `--unix-socket`，屬於正常。

你可以用宿主機測：

```bash
sudo curl --unix-socket /var/run/docker.sock http://localhost/_ping
sudo curl --unix-socket /var/run/docker.sock http://localhost/containers/json | head -c 200 && echo
```

或用容器內的 node 測（你已成功）：

* GET `/_ping` 回 `OK`
* GET `/containers/json` 拿到容器清單

### 11.3 直接進 /var/lib/docker/volumes/.../_data 權限不足

那是 Docker volumes 的 root 路徑，沒 sudo 會被擋。也不建議直接去那邊改。

本 repo 改成 `./homepage-config:/app/config` 後，建議都在 repo 內改設定檔。

---

## 12. 安全注意事項

* 不要把 API Key / Token 直接 commit
* NPM 的資料（含憑證）在 volumes：`npm_data`、`npm_letsencrypt`
* Docker socket 是高權限介面，掛載代表容器可讀 Docker 狀態；若要更嚴格可改 socket-proxy 做權限控管

---

## 13. 快速指令小抄

```bash
# 啟動 / 更新
./deploy.sh

# 查看狀態
docker compose ps

# 看 log
docker logs --tail 200 homepage
docker logs --tail 200 nginx-proxy-manager
docker logs --tail 200 portainer

# 備份
./backup.sh

# 還原（會覆寫 volumes）
./restore.sh backups/<YOUR_BACKUP>.tgz --force
```