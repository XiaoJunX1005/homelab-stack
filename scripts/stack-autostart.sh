#!/usr/bin/env bash
set -euo pipefail

log() { echo "[stack-autostart] $(date -Is) $*"; }

# Optional: shared env (HOST_IP / CFG_DIR / STACK_DIR / PROJECT_NAME ...)
ENV_FILE="/etc/default/homelab-stack"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

OVERRIDE="/etc/stack-autostart/override-order.conf"

# Defaults（可在 /etc/default/homelab-stack 覆寫）
STACK_DIR="${STACK_DIR:-/opt/homelab-stack}"
PROJECT_NAME="${PROJECT_NAME:-homelab-stack}"

wait_docker() {
  for _ in {1..60}; do
    if docker info >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  return 1
}

compose_up() {
  local file="$1"
  local dir
  dir="$(dirname "$file")"
  log "compose up: $file"
  ( cd "$dir" && COMPOSE_PROJECT_NAME="$PROJECT_NAME" docker compose -f "$file" up -d )
}

main() {
  if ! command -v docker >/dev/null 2>&1; then
    log "ERROR: docker not found"
    exit 1
  fi

  if ! wait_docker; then
    log "ERROR: docker daemon not ready"
    exit 1
  fi

  # 1) Absolute order (override)
  if [[ -s "$OVERRIDE" ]]; then
    log "Using override order: $OVERRIDE"
    while IFS= read -r f; do
      [[ -z "${f// /}" ]] && continue
      [[ "$f" =~ ^# ]] && continue
      [[ -f "$f" ]] || { log "WARN: not found: $f"; continue; }
      compose_up "$f"
      sleep 1
    done < "$OVERRIDE"
    log "Done (override)"
    exit 0
  fi

  # 2) Default: single stack in STACK_DIR
  local default_compose=""
  for n in docker-compose.yml compose.yml compose.yaml docker-compose.yaml; do
    if [[ -f "$STACK_DIR/$n" ]]; then default_compose="$STACK_DIR/$n"; break; fi
  done

  if [[ -z "$default_compose" ]]; then
    log "ERROR: compose file not found under STACK_DIR=$STACK_DIR"
    log "       Set STACK_DIR in $ENV_FILE or create $OVERRIDE"
    exit 1
  fi

  compose_up "$default_compose"
  log "Done"
}

main "$@"
