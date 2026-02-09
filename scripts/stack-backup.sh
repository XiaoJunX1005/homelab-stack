#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="${STACK_DIR:-/home/test/stack}"
PROJECT_NAME="${PROJECT_NAME:-stack}"
BACKUP_DIR="${BACKUP_DIR:-/opt/stack-backups/${PROJECT_NAME}}"
KEEP_DAYS="${KEEP_DAYS:-14}"

compose_dir="$STACK_DIR"
compose_file="$compose_dir/docker-compose.yml"
compose_env="$compose_dir/.env"
timestamp="$(date +%Y%m%d-%H%M)"
workdir="$(mktemp -d)"

cleanup() { rm -rf "$workdir"; }
trap cleanup EXIT

mkdir -p "$BACKUP_DIR"

# Determine project name
project_name=""
if [ -n "$PROJECT_NAME" ]; then
  project_name="$PROJECT_NAME"
elif [ -f "$compose_env" ]; then
  project_name="$(grep -E '^COMPOSE_PROJECT_NAME=' "$compose_env" | head -1 | cut -d= -f2-)"
fi
if [ -z "$project_name" ]; then
  project_name="$(basename "$compose_dir")"
fi
export COMPOSE_PROJECT_NAME="$project_name"

compose_args=(
  --project-directory "$compose_dir"
  --env-file "$compose_env"
  -f "$compose_file"
  -p "$project_name"
)

compose() {
  docker compose "${compose_args[@]}" "$@"
}

# Pack compose directory (exclude .git and local backups)
tar --exclude='.git' --exclude='backups' -czf "$workdir/compose.tar.gz" -C "$compose_dir" .

# Resolve volume names from docker compose config (YAML)
compose config | awk -v project="$project_name" '
BEGIN { in_vol=0; key=""; name=""; }
# enter volumes section
/^volumes:/ { in_vol=1; next; }
# leave when hit next top-level key
in_vol && /^[^[:space:]]/ { in_vol=0; }
# capture volume key
in_vol && /^  [A-Za-z0-9_.-]+:/ {
  key=$1; sub(":", "", key);
  name=""; next;
}
# capture name override
in_vol && /^    name:/ {
  name=$2;
  if (name != "") {
    print name;
  } else if (key != "") {
    print project "_" key;
  }
  next;
}
# end of volume block without name
in_vol && /^  [A-Za-z0-9_.-]+:/ {
  if (key != "") {
    print project "_" key;
  }
}
END {
  # fallback: if name not set for last key
  # (handled by key line, so no-op)
}
' | awk '!seen[$0]++' > "$workdir/volumes.txt"

# If volumes.txt is empty, fallback to docker volume list by prefix
if [ ! -s "$workdir/volumes.txt" ]; then
  docker volume ls --format '{{.Name}}' | awk -v pfx="${project_name}_" 'index($0,pfx)==1' > "$workdir/volumes.txt"
fi

# Backup volumes
while IFS= read -r v; do
  [ -z "$v" ] && continue
  if docker volume inspect "$v" >/dev/null 2>&1; then
    docker run --rm -v "${v}:/data" -v "$workdir:/backup" alpine:3.19 \
      tar czf "/backup/volume-${v}.tar.gz" -C /data .
  else
    echo "missing volume: $v" >> "$workdir/volume-missing.txt"
  fi
done < "$workdir/volumes.txt"

# Final bundle
tar czf "$BACKUP_DIR/stack-${timestamp}.tar.gz" -C "$workdir" .

# Retention: keep 14 days
find "$BACKUP_DIR" -type f -name "stack-*.tar.gz" -mtime +"$KEEP_DAYS" -delete
