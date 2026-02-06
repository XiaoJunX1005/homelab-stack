# homelab-stack

這個 repo 用來管理我的 HomeLab Docker Stack（VM 上的 Ubuntu），目前包含：

- **Homepage**：Lab 首頁 / Dashboard（`home.local`）
- **Portainer**：容器管理（建議透過 Nginx Proxy Manager 轉發成 `portainer.local`）
- **Nginx Proxy Manager (NPM)**：反向代理管理（`10.1.2.19:81`）

並提供：
- `backup.sh`：備份（支援 `--stop`、`--encrypt`）
- `restore.sh`：還原（支援還原 `.tgz` 或 `.tgz.age`）

> ⚠️ 注意：Homepage/Portainer 掛載 `docker.sock` 代表容器具備「幾乎等同 root」的主機控制能力。請只在內網使用、不要對外開放，並妥善控管 VM 存取。

---

## 目錄結構



.
├─ docker-compose.yml
├─ homepage-config/
│ ├─ bookmarks.yaml
│ ├─ custom.css
│ ├─ custom.js
│ ├─ docker.yaml
│ ├─ kubernetes.yaml
│ ├─ proxmox.yaml
│ ├─ services.yaml
│ ├─ settings.yaml
│ ├─ widgets.yaml
│ └─ logs/ (可選：建議不 commit)
├─ backup.sh
├─ restore.sh
└─ backups/ (不 commit)


---

## 需求

- Ubuntu（VM）
- Docker Engine + Docker Compose plugin
- （可選，若要加密備份）`age`
  ```bash
  sudo apt update
  sudo apt install -y age

啟動服務

在 repo 根目錄：

docker compose up -d
docker compose ps

內網存取與網域
方式 A：直接用 IP:Port

NPM：http://10.1.2.19:81

Portainer：若你有暴露 port，依 compose 設定存取

Homepage：若你有做 proxy host，通常走 home.local

方式 B：使用 .local（搭配 DNS/hosts + NPM 反代）

建議把：

home.local → NPM → Homepage（container 3000）

portainer.local → NPM → Portainer（通常 9000 或 9443）

若你把連結都改成 https://xxx.local 但 NPM 沒替該 host 配好 SSL，就會「連不上」或瀏覽器拒絕連線。
原則：沒簽憑證就用 http；有 SSL 才改 https。

Homepage 設定檔

Homepage config 位置在：

./homepage-config/（此 repo 追蹤的設定檔）

常用檔案：

settings.yaml：標題、主題、providers 等

services.yaml：你的卡片/群組（Infra/Containers/…）

widgets.yaml：資源監控、datetime、docker widget 等

修改完通常不需要重啟；若沒有即時生效，可：

docker compose restart homepage
docker logs --tail 80 homepage

反向代理（Nginx Proxy Manager）注意事項
Homepage Host validation（你之前遇到的 Host validation failed）

Homepage 可能會拒絕不在允許清單內的 Host Header（例如 home.local），log 會看到：

Host validation failed for: home.local

做法是在 docker-compose.yml 的 homepage service 加環境變數（範例）：

services:
  homepage:
    environment:
      - HOMEPAGE_ALLOWED_HOSTS=home.local,10.1.2.19


改完後：

docker compose up -d --force-recreate homepage

備份 / 還原
備份內容包含

docker-compose.yml / .env（如果存在）/ deploy.sh（如果存在）

homepage-config/（會排除 homepage-config/logs/）

Docker volumes（若存在）：

<project>_portainer_data

<project>_npm_data

<project>_npm_letsencrypt

<project>_homepage_data

<project> 預設是目前資料夾名稱（例如 stack），或你有設定 COMPOSE_PROJECT_NAME。

1) 一般備份（不中斷）
./backup.sh


輸出在 ./backups/，產生 .tgz。

2) 停機備份（更一致）
./backup.sh --stop

3) 加密備份（推薦：適合雲端/私庫）
./backup.sh --stop --encrypt


加密模式：

若有設定 AGE_RECIPIENT：用 recipient 加密

否則走 age -p（互動式密碼）

例：使用 recipient（建議做法）

export AGE_RECIPIENT="age1...."
./backup.sh --encrypt

還原（支援 .tgz 或 .tgz.age）
./restore.sh backups/<檔名>.tgz.age --force


還原流程：

docker compose down

還原 volumes

設定檔不會直接覆蓋，會先放到 ./_restore/<timestamp>/config（避免誤蓋）

docker compose up -d

你確認 staged config 沒問題後，再手動 copy 覆蓋 repo 內設定檔。

Git / 雲端備份策略（建議）

repo 只放「設定檔 + 腳本」

backups/、_restore/、.tgz、.tgz.age 一律不 commit（已在 .gitignore）

要做雲端備份：

用 ./backup.sh --stop --encrypt 產生 .tgz.age

把 .tgz.age 另外上傳到雲端（Google Drive / NAS / 私有物件儲存），或放 GitHub 私庫 但不建議把備份檔跟設定 repo 混在一起

Troubleshooting
1) Permission denied 讀 /var/lib/docker/volumes/...

正常，Docker volumes 目錄通常需要 root：

sudo ls -la /var/lib/docker/volumes/<name>/_data


但建議用 bind mount（例如 ./homepage-config:/app/config），比較好用 VSCode 直接編輯。

2) 容器內沒有 curl

Homepage container 可能沒有 curl（你遇過 sh: curl: not found），這不是錯。
要測 docker.sock 可以：

在主機上用 curl --unix-socket ...

或用 node/http 的方式（Homepage 內本來就有 node）

3) https://xxx.local 連不上

通常是 NPM 沒配置 SSL 或 Host 沒對到 Proxy Host。
先用 http:// 確認可用，再上 SSL。
