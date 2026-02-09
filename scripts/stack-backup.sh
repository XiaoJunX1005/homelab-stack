#!/usr/bin/env bash
set -euo pipefail

stack_name="stack"
compose_dir="/home/test/stack"
compose_file="$compose_dir/docker-compose.yml"
compose_env="$compose_dir/.env"
backup_root="/opt/stack-backups/${stack_name}"
timestamp="$(date +%Y%m%d-%H%M)"
workdir="$(mktemp -d)"

cleanup() { rm -rf "$workdir"; }
trap cleanup EXIT

mkdir -p "$backup_root"

# Determine project name
project_name=""
if [ -f "$compose_env" ]; then
  project_name="$(grep -E '^COMPOSE_PROJECT_NAME=' "$compose_env" | head -1 | cut -d= -f2-)"
fi
if [ -z "$project_name" ]; then
  project_name="$(basename "$compose_dir")"
fi
export COMPOSE_PROJECT_NAME="$project_name"

compose_args=(-f "$compose_file" -p "$project_name")
if [ -f "$compose_env" ]; then
  compose_args+=(--env-file "$compose_env")
fi

# Pack compose directory (exclude .git and local backups)
tar --exclude='.git' --exclude='backups' -czf "$workdir/compose.tar.gz" -C "$compose_dir" .

# Resolve volume names from docker compose config (YAML)
docker compose "${compose_args[@]}" config | awk -v project="$project_name" '
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
tar czf "$backup_root/stack-${timestamp}.tar.gz" -C "$workdir" .

# Retention: keep 14 days
find "$backup_root" -type f -name "stack-*.tar.gz" -mtime +14 -delete
