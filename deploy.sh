#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

echo "==> Pull images"
docker compose pull

echo "==> Start stack"
docker compose up -d

echo "==> Status"
docker compose ps

echo
echo "==> Quick checks"
# homepage container health (if exists)
if docker ps --format '{{.Names}}' | grep -qx homepage; then
  docker inspect -f 'homepage health={{.State.Health.Status}}' homepage || true
fi

echo
echo "==> URLs (adjust as needed)"
echo "Homepage:  http://home.local"
echo "NPM:       http://10.1.2.19:81"
echo "Portainer: http://10.1.2.19:9000 (or via your proxy)"