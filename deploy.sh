#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

log() { echo "==> $*"; }
warn() { echo "WARN: $*" >&2; }
die() { echo "ERROR: $*" >&2; exit 1; }

if [ "${EUID:-$(id -u)}" -eq 0 ]; then
  warn "Running deploy.sh as root is not recommended."
  warn "If needed, set CFG_DIR=/home/<user>/.config explicitly."
fi

log "Preflight: docker / compose"
if ! command -v docker >/dev/null 2>&1; then
  die "docker not found. Install Docker Engine: https://docs.docker.com/engine/install/"
fi
if ! docker info >/dev/null 2>&1; then
  die "docker daemon not available. Is the service running?"
fi
if ! docker compose version >/dev/null 2>&1; then
  die "docker compose v2 not found. Install the Docker Compose plugin."
fi

log "Preflight: .env"
if [ ! -f .env ]; then
  if [ -f .env.example ]; then
    cp .env.example .env
    warn ".env not found. Created from .env.example. Please edit HOST_IP and CFG_DIR in .env."
  else
    die ".env missing and .env.example not found."
  fi
fi

HOST_IP="$(grep -E '^HOST_IP=' .env | tail -n 1 | cut -d= -f2- | tr -d '\r')"
CFG_DIR="$(grep -E '^CFG_DIR=' .env | tail -n 1 | cut -d= -f2- | tr -d '\r')"

if [ -z "${HOST_IP}" ]; then
  die "HOST_IP is empty in .env (add: HOST_IP=<your_vm_ip>)"
fi
if ! [[ "$HOST_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
  die "HOST_IP does not look like IPv4: $HOST_IP"
fi

if [ -z "${CFG_DIR}" ]; then
  CFG_DIR="${HOME}/.config"
  warn "CFG_DIR not set in .env. Using default: $CFG_DIR"
fi

log "Preflight: env_file targets"
if [ ! -f "${CFG_DIR}/watchtower.env" ]; then
  warn "Missing ${CFG_DIR}/watchtower.env"
  echo "  mkdir -p \"${CFG_DIR}\""
  echo "  cp env/watchtower.env.example \"${CFG_DIR}/watchtower.env\""
  echo "  # then edit watchtower.env (notification URLs, etc.)"
fi
if [ ! -f "${CFG_DIR}/kuma-relay.env" ]; then
  warn "Missing ${CFG_DIR}/kuma-relay.env"
  echo "  mkdir -p \"${CFG_DIR}\""
  echo "  cp env/kuma-relay.env.example \"${CFG_DIR}/kuma-relay.env\""
  echo "  # then edit kuma-relay.env (KUMA_PUSH_TOKEN)"
fi

log "Preflight: docker.sock access (Homepage)"
if grep -q '/var/run/docker.sock' docker-compose.yml >/dev/null 2>&1; then
  if ! id -nG "$USER" | tr ' ' '\n' | grep -qx docker; then
    warn "User '$USER' is not in docker group."
    warn "Fix: sudo usermod -aG docker $USER && re-login"
  fi
fi

log "Render compose"
if ! HOST_IP="$HOST_IP" CFG_DIR="$CFG_DIR" docker compose config > compose.rendered.yml; then
  die "compose render failed (check .env / HOST_IP / CFG_DIR)"
fi

log "Pull images"
docker compose pull

log "Start stack"
docker compose up -d

log "Status"
docker compose ps

log "Smoke test"
services="$(docker compose config --services)"
if echo "$services" | grep -qx watchtower; then
  docker logs watchtower --tail 30 || true
fi
if echo "$services" | grep -qx kuma-push-relay; then
  if command -v curl >/dev/null 2>&1; then
    curl -fsS http://127.0.0.1:18080/up || warn "relay test failed (token not set yet?)"
  else
    warn "curl not found; skipping relay test"
  fi
fi

log "URLs (adjust as needed)"
echo "Homepage:  http://home.local"
echo "NPM:       http://${HOST_IP}:81"
echo "Kuma:      http://${HOST_IP}:3001"
echo "Portainer: http://portainer.local (via NPM)"
echo
echo "Next (systemd timers): sudo ./deploy-systemd.sh"
