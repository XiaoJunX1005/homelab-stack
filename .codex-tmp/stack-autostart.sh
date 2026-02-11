#!/usr/bin/env bash
set -euo pipefail

# 你可以在 /etc/stack-autostart/override-order.conf 指定「絕對路徑」的 compose 檔案列表（每行一個）
OVERRIDE="/etc/stack-autostart/override-order.conf"

# 搜尋範圍（可依你實際堆疊調整）
SEARCH_DIRS=(
  "/opt"
  "/srv"
  "/etc"
  "/home"
  "/root"
)

COMPOSE_NAMES=("compose.yml" "compose.yaml" "docker-compose.yml" "docker-compose.yaml")

INFRA_RE='(adguard|pihole|unbound|dns|traefik|nginx|caddy|npm|proxy|haproxy|portainer)'
DATA_RE='(postgres|mysql|mariadb|redis|mongo|influx|mssql|elastic|opensearch|rabbitmq|kafka)'
APP_RE='(homepage|kuma|uptime|watchtower|grafana|prometheus|loki|dash|monitor)'

log() { echo "[$(date -Is)] $*"; }

wait_docker() {
  # 等 docker daemon ready（最多 60 秒）
  for i in {1..60}; do
    if docker info >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

compose_up() {
  local file="$1"
  local dir
  dir="$(dirname "$file")"

  if [[ ! -f "$file" ]]; then
    log "SKIP (not found): $file"
    return 0
  fi

  log "docker compose up -d : $file"
  ( cd "$dir" && docker compose -f "$file" up -d )
}

classify_compose() {
  # 用 compose 內容大略分類：infra / data / app / other
  # 只用 grep，不依賴 yq
  local file="$1"
  local text
  text="$(tr '[:upper:]' '[:lower:]' < "$file" 2>/dev/null || true)"

  if echo "$text" | grep -Eq "$INFRA_RE"; then echo "1_infra"; return; fi
  if echo "$text" | grep -Eq "$DATA_RE"; then echo "2_data"; return; fi
  if echo "$text" | grep -Eq "$APP_RE"; then echo "3_app"; return; fi
  echo "9_other"
}

discover_compose_files() {
  local tmp
  tmp="$(mktemp)"
  for d in "${SEARCH_DIRS[@]}"; do
    [[ -d "$d" ]] || continue
    for n in "${COMPOSE_NAMES[@]}"; do
      # 限制深度避免掃全機爆炸；需要可自行調大
      find "$d" -maxdepth 6 -type f -name "$n" 2>/dev/null || true
    done
  done | sort -u > "$tmp"
  cat "$tmp"
  rm -f "$tmp"
}

main() {
  log "stack-autostart: start"

  if ! command -v docker >/dev/null 2>&1; then
    log "ERROR: docker not found"
    exit 1
  fi

  if ! wait_docker; then
    log "ERROR: docker daemon not ready"
    exit 1
  fi

  # 若有 override-order.conf，完全照它的順序跑（最可控）
  if [[ -s "$OVERRIDE" ]]; then
    log "Using override order: $OVERRIDE"
    while IFS= read -r f; do
      [[ -z "${f// /}" ]] && continue
      [[ "$f" =~ ^# ]] && continue
      compose_up "$f"
    done < "$OVERRIDE"

    log "stack-autostart: done (override order)"
    exit 0
  fi

  # 否則自動探索 compose 檔，並依分類排序後啟動
  log "Discovering compose files..."
  mapfile -t files < <(discover_compose_files)

  if ((${#files[@]} == 0)); then
    log "No compose files found. Fallback: start all stopped containers."
    # fallback：把所有已存在但沒跑的容器 start 起來（順序不保證）
    mapfile -t stopped < <(docker ps -a --format '{{.ID}} {{.State}}' | awk '$2!="running"{print $1}')
    if ((${#stopped[@]} > 0)); then
      docker start "${stopped[@]}" >/dev/null || true
    fi
    log "stack-autostart: done (fallback)"
    exit 0
  fi

  # 生成「分類 key + path」後排序
  tmp="$(mktemp)"
  for f in "${files[@]}"; do
    # 避免把範例/模組 cache 的 compose 也啟動：常見忽略
    case "$f" in
      *"/node_modules/"*|*"/.cache/"*|*"/.vscode/"*|*"/snap/"*) continue ;;
    esac
    key="$(classify_compose "$f")"
    printf "%s\t%s\n" "$key" "$f" >> "$tmp"
  done

  log "Starting stacks by auto order (infra -> data -> app -> other)..."
  while IFS=$'\t' read -r key f; do
    log "Group=$key File=$f"
    compose_up "$f"
    sleep 1
  done < <(sort -k1,1 -k2,2 "$tmp")

  rm -f "$tmp"

  log "stack-autostart: done"
}

main "$@"
