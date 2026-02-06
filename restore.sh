#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage:
  ./restore.sh <backup.tgz|backup.tgz.age> [options]

Options:
  --force          allow volume restore (required to overwrite volumes)
  --dry-run        show actions without making changes
  --no-start       do not start stack after restore
  --only-volumes   restore volumes only
  --only-configs   stage configs only
  --project NAME   override compose project name
  -h, --help       show help
USAGE
}

ARCHIVE=""
FORCE=0
DRY_RUN=0
NO_START=0
ONLY_VOLUMES=0
ONLY_CONFIGS=0
PROJECT_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=1; shift;;
    --dry-run) DRY_RUN=1; shift;;
    --no-start) NO_START=1; shift;;
    --only-volumes) ONLY_VOLUMES=1; shift;;
    --only-configs) ONLY_CONFIGS=1; shift;;
    --project) PROJECT_OVERRIDE="${2:-}"; shift 2;;
    -h|--help) usage; exit 0;;
    -*)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
    *)
      if [[ -z "$ARCHIVE" ]]; then
        ARCHIVE="$1"
        shift
      else
        echo "Unexpected argument: $1" >&2
        usage
        exit 1
      fi
      ;;
  esac
done

if [[ -z "$ARCHIVE" ]]; then
  usage
  exit 1
fi

if [[ "$ONLY_VOLUMES" -eq 1 && "$ONLY_CONFIGS" -eq 1 ]]; then
  echo "ERROR: --only-volumes and --only-configs are mutually exclusive" >&2
  exit 1
fi

if [[ ! -f "$ARCHIVE" ]]; then
  echo "ERROR: archive not found: $ARCHIVE" >&2
  exit 1
fi

if [[ ! -f docker-compose.yml && ! -f docker-compose.yaml ]]; then
  echo "ERROR: docker-compose.yml not found in current directory: $(pwd)" >&2
  exit 1
fi

compose() {
  if [[ -n "$PROJECT_OVERRIDE" ]]; then
    COMPOSE_PROJECT_NAME="$PROJECT_OVERRIDE" docker compose "$@"
  else
    docker compose "$@"
  fi
}

# Determine project name (same logic as backup.sh)
PROJECT_NAME="${PROJECT_OVERRIDE:-${COMPOSE_PROJECT_NAME:-}}"
if [[ -z "$PROJECT_NAME" && -f .env ]]; then
  PROJECT_NAME="$(grep -E '^[[:space:]]*COMPOSE_PROJECT_NAME=' .env | tail -n 1 | cut -d= -f2- | tr -d '\r' || true)"
fi
if [[ -z "$PROJECT_NAME" ]]; then
  PROJECT_NAME="$(basename "$PWD")"
fi

CHECKSUM_FILE="${ARCHIVE}.sha256"
if [[ -f "$CHECKSUM_FILE" ]]; then
  echo "[i] Verifying checksum: ${CHECKSUM_FILE}"
  sha256sum -c "$CHECKSUM_FILE"
fi

TMPDIR="$(mktemp -d)"
cleanup(){ rm -rf "$TMPDIR"; }
trap cleanup EXIT

ARCHIVE_TO_EXTRACT="$ARCHIVE"
if [[ "$ARCHIVE" == *.age ]]; then
  if ! command -v age >/dev/null 2>&1; then
    echo "ERROR: age not found. Install with: sudo apt install -y age" >&2
    exit 1
  fi
  DEC_PATH="${TMPDIR}/backup.tgz"
  echo "[i] Decrypting ${ARCHIVE} -> ${DEC_PATH}"
  age -d -o "${DEC_PATH}" "${ARCHIVE}"
  ARCHIVE_TO_EXTRACT="${DEC_PATH}"
fi

echo "[i] Project: ${PROJECT_NAME}"
echo "[i] Archive: ${ARCHIVE}"

echo "[i] Extracting..."
tar -C "$TMPDIR" -xzf "$ARCHIVE_TO_EXTRACT"

HAS_VOLUMES=0
if [[ -d "${TMPDIR}/volumes" ]]; then
  shopt -s nullglob
  vols=( "${TMPDIR}/volumes/"*.tar.gz )
  shopt -u nullglob
  if [[ "${#vols[@]}" -gt 0 ]]; then
    HAS_VOLUMES=1
  fi
fi

if [[ "$ONLY_CONFIGS" -eq 0 && "$HAS_VOLUMES" -eq 1 && "$FORCE" -ne 1 ]]; then
  echo "ERROR: volume restore requires --force" >&2
  exit 1
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[i] Dry-run mode"
  echo "    - would stage configs to ./_restore/<timestamp>/configs"
  if [[ "$ONLY_CONFIGS" -eq 0 && "$HAS_VOLUMES" -eq 1 ]]; then
    echo "    - would restore volumes (requires --force)"
  fi
  if [[ "$NO_START" -eq 0 ]]; then
    echo "    - would start stack (docker compose up -d)"
  fi
  exit 0
fi

if [[ "$ONLY_CONFIGS" -eq 0 && "$HAS_VOLUMES" -eq 1 ]]; then
  echo "[i] Stopping stack..."
  compose down || true
fi

TS="$(date +%Y%m%d_%H%M%S)"
STAGE_DIR="./_restore/${TS}/configs"

if [[ "$ONLY_VOLUMES" -eq 0 && -d "${TMPDIR}/configs" ]]; then
  echo "[i] Staging configs -> ${STAGE_DIR}"
  mkdir -p "$STAGE_DIR"
  cp -a "${TMPDIR}/configs/." "${STAGE_DIR}/"
fi
if [[ "$ONLY_VOLUMES" -eq 0 && -f "${TMPDIR}/META.txt" ]]; then
  mkdir -p "$(dirname "$STAGE_DIR")"
  cp -a "${TMPDIR}/META.txt" "$(dirname "$STAGE_DIR")/"
fi

restore_volume() {
  local vol_full="$1" src_tgz="$2"
  docker volume inspect "$vol_full" >/dev/null 2>&1 || docker volume create "$vol_full" >/dev/null
  docker run --rm -v "${vol_full}:/to" alpine:3.20 sh -lc "rm -rf /to/* /to/.[!.]* /to/..?* 2>/dev/null || true"
  docker run --rm \
    -v "${vol_full}:/to" \
    -v "${TMPDIR}/volumes:/from" \
    alpine:3.20 \
    sh -lc "cd /to && tar -xzf \"/from/${src_tgz}\""
}

if [[ "$ONLY_CONFIGS" -eq 0 && "$HAS_VOLUMES" -eq 1 ]]; then
  echo "[i] Restoring volumes..."
  shopt -s nullglob
  for tgz in "${TMPDIR}/volumes/"*.tar.gz; do
    base="$(basename "$tgz")"
    vol_full="${base%.tar.gz}"
    echo "  - ${vol_full}"
    restore_volume "${vol_full}" "${base}"
  done
  shopt -u nullglob
fi

if [[ "$NO_START" -eq 0 ]]; then
  echo "[i] Starting stack..."
  compose up -d
fi

echo "[✓] Restore finished."
if [[ "$ONLY_VOLUMES" -eq 0 ]]; then
  echo "    Configs staged at: ${STAGE_DIR}"
fi
