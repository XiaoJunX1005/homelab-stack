#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

PROJECT_NAME="$(basename "$(pwd)")"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_DIR="./backups"
BACKUP_FILE="${BACKUP_DIR}/homelab-stack_${TIMESTAMP}.tgz"

VOLUMES=(
  "portainer_data"
  "npm_data"
  "npm_letsencrypt"
)

log() {
  echo "[backup] $*"
}

log "Ensure backup directory"
mkdir -p "$BACKUP_DIR"

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

log "Collect configs"
mkdir -p "$TMP_DIR/configs"
cp -a docker-compose.yml deploy.sh .gitignore README.md "$TMP_DIR/configs/"

mkdir -p "$TMP_DIR/configs/homepage-config"
# Copy homepage-config excluding logs/
tar -C homepage-config --exclude='logs' -cf - . | tar -C "$TMP_DIR/configs/homepage-config" -xf -

log "Backup volumes"
mkdir -p "$TMP_DIR/volumes"
for short_name in "${VOLUMES[@]}"; do
  full_name="${PROJECT_NAME}_${short_name}"
  if ! docker volume inspect "$full_name" >/dev/null 2>&1; then
    echo "[backup] ERROR: volume not found: $full_name" >&2
    exit 1
  fi
  log "- $full_name"
  docker run --rm \
    -v "${full_name}:/volume" \
    -v "${TMP_DIR}/volumes:/backup" \
    alpine:3.20 \
    sh -c "tar czf /backup/${full_name}.tar.gz -C /volume ."
done

log "Create archive"
tar -czf "$BACKUP_FILE" -C "$TMP_DIR" configs volumes

log "Done: $BACKUP_FILE"
