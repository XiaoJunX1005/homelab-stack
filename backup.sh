#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage:
  ./backup.sh [options]

Options:
  --dir PATH        output directory (default: ./backups)
  --target PATH     output file path (must end with .tgz)
  --keep N          keep only newest N backups (delete older .tgz and .sha256)
  --project NAME    override compose project name (volume prefix)
  --with-logs       include homepage-config/logs in backup
  --no-volumes      skip volume backup
  --stop            docker compose down before backup, then docker compose up -d after backup
  --encrypt         encrypt the produced .tgz with age (outputs .tgz.age)
  -h, --help        show this help
USAGE
}

OUT_DIR="./backups"
TARGET_PATH=""
KEEP_N=0
WITH_LOGS=0
NO_VOLUMES=0
STOP_FIRST=0
ENCRYPT=0
PROJECT_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) OUT_DIR="${2:-}"; shift 2;;
    --target) TARGET_PATH="${2:-}"; shift 2;;
    --keep) KEEP_N="${2:-}"; shift 2;;
    --project) PROJECT_OVERRIDE="${2:-}"; shift 2;;
    --with-logs) WITH_LOGS=1; shift;;
    --no-volumes) NO_VOLUMES=1; shift;;
    --stop) STOP_FIRST=1; shift;;
    --encrypt) ENCRYPT=1; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown option: $1" >&2; usage; exit 1;;
  esac
done

if [[ -n "$KEEP_N" && "$KEEP_N" != "0" && ! "$KEEP_N" =~ ^[0-9]+$ ]]; then
  echo "ERROR: --keep expects a non-negative integer" >&2
  exit 1
fi

if [[ -n "$TARGET_PATH" && -n "$OUT_DIR" && "$OUT_DIR" != "./backups" ]]; then
  echo "ERROR: use either --dir or --target, not both" >&2
  exit 1
fi

# must be run in a compose project directory
if [[ ! -f docker-compose.yml && ! -f docker-compose.yaml ]]; then
  echo "ERROR: docker-compose.yml not found in current directory: $(pwd)" >&2
  exit 1
fi

compose() { docker compose "$@"; }

# Determine project name in a stable way:
# 1) --project
# 2) COMPOSE_PROJECT_NAME env
# 3) .env file COMPOSE_PROJECT_NAME=
# 4) current folder name
PROJECT_NAME="${PROJECT_OVERRIDE:-${COMPOSE_PROJECT_NAME:-}}"
if [[ -z "$PROJECT_NAME" && -f .env ]]; then
  PROJECT_NAME="$(grep -E '^[[:space:]]*COMPOSE_PROJECT_NAME=' .env | tail -n 1 | cut -d= -f2- | tr -d '\r' || true)"
fi
if [[ -z "$PROJECT_NAME" ]]; then
  PROJECT_NAME="$(basename "$PWD")"
fi

TS="$(date +%Y%m%d_%H%M%S)"
ARCHIVE_NAME="homelab-stack_${TS}.tgz"

if [[ -n "$TARGET_PATH" ]]; then
  if [[ "$TARGET_PATH" != *.tgz ]]; then
    echo "ERROR: --target must end with .tgz" >&2
    exit 1
  fi
  ARCHIVE_PATH="$TARGET_PATH"
  OUT_DIR="$(dirname "$TARGET_PATH")"
else
  ARCHIVE_PATH="${OUT_DIR}/${ARCHIVE_NAME}"
fi

mkdir -p "$OUT_DIR"

TMPDIR="$(mktemp -d)"
cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

echo "[i] Project: ${PROJECT_NAME}"
echo "[i] Output:  ${ARCHIVE_PATH}"

# Optionally stop stack
if [[ "$STOP_FIRST" -eq 1 ]]; then
  echo "[i] Stopping stack (docker compose down)..."
  compose down || true
fi

# Collect config files (repo-local)
mkdir -p "${TMPDIR}/configs"
for f in docker-compose.yml docker-compose.yaml .env deploy.sh README.md; do
  [[ -f "$f" ]] && cp -a "$f" "${TMPDIR}/configs/"
done

# homepage-config (exclude logs/ by default)
if [[ -d "homepage-config" ]]; then
  mkdir -p "${TMPDIR}/configs/homepage-config"
  if [[ "$WITH_LOGS" -eq 1 ]]; then
    tar -C homepage-config -cf - . | tar -C "${TMPDIR}/configs/homepage-config" -xf -
  else
    tar -C homepage-config --exclude='logs' -cf - . | tar -C "${TMPDIR}/configs/homepage-config" -xf -
  fi
fi

mkdir -p "${TMPDIR}/volumes"

get_compose_volumes() {
  docker compose config --volumes 2>/dev/null | sed '/^$/d'
}

resolve_volume_name() {
  local short="$1"
  local pref="${PROJECT_NAME}_${short}"
  if docker volume inspect "$pref" >/dev/null 2>&1; then
    echo "$pref"
    return
  fi
  if docker volume inspect "$short" >/dev/null 2>&1; then
    echo "$short"
    return
  fi
  echo "$pref"
}

backup_volume() {
  local vol_full="$1" out_tgz="$2"
  docker run --rm \
    -v "${vol_full}:/from:ro" \
    -v "${TMPDIR}/volumes:/to" \
    alpine:3.20 \
    sh -lc "cd /from && tar -czf \"/to/${out_tgz}\" ."
}

if [[ "$NO_VOLUMES" -eq 1 ]]; then
  echo "[i] Skipping volumes (--no-volumes)"
else
  echo "[i] Backing up volumes..."
  mapfile -t VOLS < <(get_compose_volumes || true)
  if [[ "${#VOLS[@]}" -eq 0 ]]; then
    VOLS=(portainer_data npm_data npm_letsencrypt homepage_data)
  fi
  for v in "${VOLS[@]}"; do
    vol_full="$(resolve_volume_name "$v")"
    if docker volume inspect "${vol_full}" >/dev/null 2>&1; then
      echo "  - ${vol_full}"
      backup_volume "${vol_full}" "${vol_full}.tar.gz"
    else
      echo "  - ${vol_full} (skip: not found)"
    fi
  done
fi

# Write metadata
cat > "${TMPDIR}/META.txt" <<META
project=${PROJECT_NAME}
created_at=$(date -Is)
host=$(hostname)
pwd=$(pwd)
META

echo "[i] Creating archive..."
tar -C "$TMPDIR" -czf "$ARCHIVE_PATH" .

echo "[i] Writing checksum..."
sha256sum "$ARCHIVE_PATH" > "${ARCHIVE_PATH}.sha256"

# Start stack back if we stopped it
if [[ "$STOP_FIRST" -eq 1 ]]; then
  echo "[i] Starting stack (docker compose up -d)..."
  compose up -d
fi

# Encrypt if requested
if [[ "$ENCRYPT" -eq 1 ]]; then
  if ! command -v age >/dev/null 2>&1; then
    echo "ERROR: age not found. Install with: sudo apt install -y age" >&2
    exit 1
  fi

  ENC_PATH="${ARCHIVE_PATH}.age"
  echo "[i] Encrypting -> ${ENC_PATH}"

  if [[ -n "${AGE_RECIPIENT:-}" ]]; then
    age -r "${AGE_RECIPIENT}" -o "${ENC_PATH}" "${ARCHIVE_PATH}"
  else
    echo "[i] Using passphrase mode (age -p). You'll be prompted."
    age -p -o "${ENC_PATH}" "${ARCHIVE_PATH}"
  fi
fi

if [[ "$KEEP_N" -gt 0 ]]; then
  echo "[i] Retention: keep newest ${KEEP_N}"
  mapfile -t backups < <(ls -1t "${OUT_DIR}/homelab-stack_"*.tgz 2>/dev/null || true)
  if [[ "${#backups[@]}" -gt "$KEEP_N" ]]; then
    for old in "${backups[@]:$KEEP_N}"; do
      echo "  - delete ${old}"
      rm -f "${old}" "${old}.sha256"
    done
  fi
fi

echo "[✓] Done: ${ARCHIVE_PATH}"
