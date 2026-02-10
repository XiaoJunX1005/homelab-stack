#!/usr/bin/env bash
set -euo pipefail

# =========================
# Homelab Stack Backup Tool
# =========================
# Features:
# - Backup configs + (optional) docker named volumes
# - Output to ./backups by default (or --dest)
# - Keep last N backups (or --keep)
# - Optional Uptime Kuma Push notification (env: KUMA_PUSH_URL or --kuma-push-url)
#
# Usage:
#   ./backup.sh
#   ./backup.sh --no-volumes
#   ./backup.sh --dest /path/to/backups --keep 14
#   ./backup.sh --kuma-push-url "http://kuma.lan/api/push/xxx"
#
# Output:
#   Prints archive filename as the LAST line (方便腳本串接)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_DIR="$SCRIPT_DIR"

PROJECT_NAME="${PROJECT_NAME:-$(basename "$STACK_DIR")}"
PREFIX="${PREFIX:-homelab-stack}"
BACKUP_DIR_DEFAULT="$STACK_DIR/backups"

NO_VOLUMES=0
KEEP=0
DEST=""
KUMA_PUSH_URL="${KUMA_PUSH_URL:-}"

TMP_DIR=""

usage() {
  cat <<'EOF'
Usage: backup.sh [options]

Options:
  --no-volumes               Do not backup docker named volumes
  --dest <dir>               Backup output directory (default: ./backups)
  --keep <N>                 Keep last N backup archives in dest dir (0 = no rotation)
  --project <name>           Docker Compose project name (default: current folder name)
  --prefix <name>            Archive filename prefix (default: homelab-stack)
  --kuma-push-url <url>      Uptime Kuma push URL (or env: KUMA_PUSH_URL)
  -h, --help                 Show help

EOF
}

notify_kuma() {
  local status="${1:-up}"
  local msg="${2:-backup_ok}"
  if [[ -z "${KUMA_PUSH_URL}" ]]; then
    return 0
  fi
  # Use -G to append query parameters safely, even if URL already has '?'
  curl -fsS -G \
    --data-urlencode "status=${status}" \
    --data-urlencode "msg=${msg}" \
    "${KUMA_PUSH_URL}" >/dev/null || true
}

on_error() {
  notify_kuma "down" "backup_failed"
  echo "ERROR: backup failed." >&2
}

cleanup() {
  if [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]]; then
    rm -rf "${TMP_DIR}"
  fi
}

trap on_error ERR
trap cleanup EXIT

# -------------------------
# Parse args
# -------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-volumes) NO_VOLUMES=1; shift ;;
    --dest) DEST="${2:-}"; shift 2 ;;
    --keep) KEEP="${2:-0}"; shift 2 ;;
    --project) PROJECT_NAME="${2:-}"; shift 2 ;;
    --prefix) PREFIX="${2:-}"; shift 2 ;;
    --kuma-push-url) KUMA_PUSH_URL="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

BACKUP_DIR="${DEST:-$BACKUP_DIR_DEFAULT}"
mkdir -p "${BACKUP_DIR}"

TS="$(date +%Y%m%d_%H%M%S)"
ARCHIVE_NAME="${PREFIX}_${TS}.tgz"
ARCHIVE_PATH="${BACKUP_DIR}/${ARCHIVE_NAME}"

TMP_DIR="$(mktemp -d)"
CONFIG_DIR="${TMP_DIR}/configs"
VOLUME_DIR="${TMP_DIR}/volumes"
mkdir -p "${CONFIG_DIR}" "${VOLUME_DIR}"

# -------------------------
# Collect configs
# -------------------------
# 只備份專案關鍵檔案 + homepage-config（排除 logs）
for f in docker-compose.yml docker-compose.yaml deploy.sh README.md .gitignore; do
  if [[ -f "${STACK_DIR}/${f}" ]]; then
    cp -a "${STACK_DIR}/${f}" "${CONFIG_DIR}/"
  fi
done

if [[ -d "${STACK_DIR}/homepage-config" ]]; then
  mkdir -p "${CONFIG_DIR}/homepage-config"
  rsync -a --delete \
    --exclude 'logs/' \
    "${STACK_DIR}/homepage-config/" \
    "${CONFIG_DIR}/homepage-config/"
fi

# metadata（方便日後查）
{
  echo "timestamp=${TS}"
  echo "project_name=${PROJECT_NAME}"
  echo "prefix=${PREFIX}"
  echo "host=$(hostname)"
  echo "pwd=${STACK_DIR}"
  echo "git_commit=$(cd "${STACK_DIR}" 2>/dev/null && git rev-parse --short HEAD 2>/dev/null || echo "N/A")"
  echo "docker=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "N/A")"
} > "${TMP_DIR}/meta.txt"

# -------------------------
# Backup volumes (optional)
# -------------------------
if [[ "${NO_VOLUMES}" -eq 0 ]]; then
  # 依你目前 stack 實際用到的 volume（homepage 改成 bind mount 後就不用備份 volume）
  VOLUMES=(
    "${PROJECT_NAME}_portainer_data"
    "${PROJECT_NAME}_npm_data"
    "${PROJECT_NAME}_npm_letsencrypt"
  )

  echo "Backing up docker volumes:"
  for v in "${VOLUMES[@]}"; do
    if docker volume inspect "${v}" >/dev/null 2>&1; then
      echo "  - ${v}"
      docker run --rm \
        -v "${v}:/data:ro" \
        -v "${VOLUME_DIR}:/backup" \
        alpine sh -lc "cd /data && tar -czf /backup/${v}.tgz ."
    else
      echo "  - ${v} (SKIP: not found)"
    fi
  done
else
  echo "Skipping volumes (--no-volumes)."
fi

# -------------------------
# Build final archive
# -------------------------
tar -czf "${ARCHIVE_PATH}" -C "${TMP_DIR}" .

# -------------------------
# Rotation
# -------------------------
if [[ "${KEEP}" -gt 0 ]]; then
  # Keep latest N archives by mtime
  mapfile -t all < <(ls -1t "${BACKUP_DIR}/${PREFIX}_"*.tgz 2>/dev/null || true)
  if (( ${#all[@]} > KEEP )); then
    for ((i=KEEP; i<${#all[@]}; i++)); do
      rm -f "${all[$i]}" || true
    done
  fi
fi

notify_kuma "up" "backup_ok"

# 最後一行固定輸出檔名（方便你/AI接著做別的）
echo "${ARCHIVE_NAME}"
