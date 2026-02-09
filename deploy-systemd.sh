#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYSTEMD_DIR="$ROOT_DIR/systemd"
DEFAULTS_SRC="$SYSTEMD_DIR/homelab-stack.defaults.example"
DEFAULTS_DST="/etc/default/homelab-stack"

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "ERROR: please run with sudo: sudo ./deploy-systemd.sh" >&2
  exit 1
fi

install -m 0644 "$SYSTEMD_DIR/stack-backup.service" /etc/systemd/system/stack-backup.service
install -m 0644 "$SYSTEMD_DIR/stack-backup.timer" /etc/systemd/system/stack-backup.timer
install -m 0644 "$SYSTEMD_DIR/docker-prune.service" /etc/systemd/system/docker-prune.service
install -m 0644 "$SYSTEMD_DIR/docker-prune.timer" /etc/systemd/system/docker-prune.timer

if [ -f "$SYSTEMD_DIR/stack-backup.service.d.override.conf" ]; then
  mkdir -p /etc/systemd/system/stack-backup.service.d
  install -m 0644 "$SYSTEMD_DIR/stack-backup.service.d.override.conf" /etc/systemd/system/stack-backup.service.d/override.conf
fi

if [ ! -f "$DEFAULTS_DST" ]; then
  install -m 0644 "$DEFAULTS_SRC" "$DEFAULTS_DST"
  chmod 0644 "$DEFAULTS_DST"
  echo "Created $DEFAULTS_DST"
  echo "Please edit HOST_IP / CFG_DIR / STACK_DIR (required) and BACKUP_DIR if needed."
fi

systemctl daemon-reload
systemctl enable --now stack-backup.timer docker-prune.timer

systemctl list-timers --all | grep -E 'stack-backup|docker-prune' || true
systemctl status stack-backup.timer --no-pager || true
systemctl status docker-prune.timer --no-pager || true
