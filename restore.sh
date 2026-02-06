#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

log() {
  echo "[restore] $*"
}

usage() {
  echo "Usage: $0 backups/xxx.tgz --force" >&2
}

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

BACKUP_FILE="$1"
FORCE_FLAG="${2:-}"

if [[ "$FORCE_FLAG" != "--force" ]]; then
  echo "[restore] WARNING: This operation will overwrite Docker volumes." >&2
  echo "[restore] Re-run with --force to continue." >&2
  exit 1
fi

if [[ ! -f "$BACKUP_FILE" ]]; then
  echo "[restore] ERROR: backup file not found: $BACKUP_FILE" >&2
  exit 1
fi

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
RESTORE_DIR="./_restore/${TIMESTAMP}"
TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

log "Stopping stack"
docker compose down

log "Extract backup"
tar -xzf "$BACKUP_FILE" -C "$TMP_DIR"

if [[ -d "$TMP_DIR/volumes" ]]; then
  log "Restore volumes"
  shopt -s nullglob
  for archive in "$TMP_DIR/volumes"/*.tar.gz; do
    base_name="$(basename "$archive")"
    volume_name="${base_name%.tar.gz}"

    log "- $volume_name"
    docker volume create "$volume_name" >/dev/null
    docker run --rm -v "${volume_name}:/volume" alpine:3.20 \
      sh -c "rm -rf /volume/* /volume/.[!.]* /volume/..?*" || true
    docker run --rm -v "${volume_name}:/volume" -v "${TMP_DIR}/volumes:/backup" alpine:3.20 \
      sh -c "tar xzf /backup/${base_name} -C /volume"
  done
  shopt -u nullglob
fi

if [[ -d "$TMP_DIR/configs" ]]; then
  log "Copy configs to $RESTORE_DIR for manual review"
  mkdir -p "$RESTORE_DIR"
  cp -a "$TMP_DIR/configs/." "$RESTORE_DIR/"
fi

log "Start stack"
docker compose up -d

log "Done"
