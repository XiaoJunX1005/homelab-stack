#!/usr/bin/env bash
set -euo pipefail

TIMEOUT="${TIMEOUT:-60}"

echo "== 1) 列出目前 running containers =="
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Ports}}' || true
echo

echo "== 2) 嘗試停止所有 compose stacks（若有）=="
# docker compose ls 需要新版 compose plugin；失敗就略過
if docker compose ls >/dev/null 2>&1; then
  # 取出所有 project name
  mapfile -t projects < <(docker compose ls --format json | sed -n 's/.*"Name":"\([^"]*\)".*/\1/p' | sort -u)
  if ((${#projects[@]} > 0)); then
    for p in "${projects[@]}"; do
      echo "-- compose project: $p"
      # 需要在對應目錄才有 compose.yml；所以這裡用 container label 反查比較穩
      # 先把該 project 的容器停掉（依 compose 依賴順序）
      ids=$(docker ps -q --filter "label=com.docker.compose.project=$p" || true)
      if [[ -n "${ids}" ]]; then
        docker stop -t "$TIMEOUT" $ids || true
      fi
    done
  else
    echo "(no compose projects)"
  fi
else
  echo "(docker compose ls not available, skip)"
fi
echo

echo "== 3) 停掉所有剩餘 running containers（非 compose 或沒標籤者）=="
ids=$(docker ps -q || true)
if [[ -n "${ids}" ]]; then
  docker stop -t "$TIMEOUT" $ids || true
fi

echo
echo "== 4) 驗證是否已全停 =="
if [[ -n "$(docker ps -q)" ]]; then
  echo "!! 仍有 container 在跑，請檢查："
  docker ps
  exit 1
fi
echo "OK：所有 containers 已停止。"

echo
echo "== 5) reboot =="
sync
reboot
