#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYSTEMD_DIR="$ROOT_DIR/systemd"
SCRIPT_DIR="$ROOT_DIR/scripts"

if [ ! -f "$SCRIPT_DIR/stack-backup.sh" ]; then
  echo "missing $SCRIPT_DIR/stack-backup.sh" >&2
  exit 1
fi

sudo install -m 0755 "$SCRIPT_DIR/stack-backup.sh" /usr/local/bin/stack-backup.sh

sudo install -m 0644 "$SYSTEMD_DIR/stack-backup.service" /etc/systemd/system/stack-backup.service
sudo install -m 0644 "$SYSTEMD_DIR/stack-backup.timer" /etc/systemd/system/stack-backup.timer

if [ -f "$SYSTEMD_DIR/stack-backup.service.d.override.conf" ]; then
  sudo mkdir -p /etc/systemd/system/stack-backup.service.d
  sudo install -m 0644 "$SYSTEMD_DIR/stack-backup.service.d.override.conf" /etc/systemd/system/stack-backup.service.d/override.conf
fi

sudo systemctl daemon-reload
sudo systemctl enable --now stack-backup.timer

echo "OK"
