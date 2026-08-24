#!/usr/bin/env bash
# Per-database logical backup (pg_dump) of the unified Postgres instance.
# Runs on the HOST via cron (not in any container): dumps every database in the
# `postgres` compose stack into /etc/postgres/backups/<db>/<db>-YYYYMMDD.sql,
# keeping the newest KEEP_N copies per database.
#
# Schedule example (host crontab, not committed):
#   30 2 * * * /home/ubuntu/jerome/docker-gitops/vps_oracle/compose/postgres/scripts/backup-databases.sh
#
# NOTE: pg_dump is a logical backup — it captures data + schema per database but
# not cluster-global objects (roles). Roles are managed declaratively in
# init/init-databases.sh; export them separately with `pg_dumpall -g` if needed.
set -u

STACK_DIR="/home/ubuntu/jerome/docker-gitops/vps_oracle/compose/postgres"
BACKUP_ROOT="/etc/postgres/backups"
KEEP_N=14                      # keep 14 daily copies per database
PGUSER="${POSTGRES_USER:-postgres}"

# Fail fast if the stack isn't up.
docker compose -f "$STACK_DIR/docker-compose.yml" ps --status running postgres >/dev/null 2>&1 || {
  echo "postgres container not running — aborting backup" >&2
  exit 1
}

# List databases (skip the bootstrap/template ones).
dbs="$(
  docker compose -f "$STACK_DIR/docker-compose.yml" exec -T postgres \
    psql -U "$PGUSER" -d postgres -tAc \
    "SELECT datname FROM pg_database WHERE datistemplate = false AND datname <> 'postgres'"
)"

if [ -z "$dbs" ]; then
  echo "no databases to back up" >&2
  exit 0
fi

stamp="$(date +%Y%m%d)"
failed=0

while IFS= read -r db; do
  [ -z "$db" ] && continue
  out_dir="$BACKUP_ROOT/$db"
  mkdir -p "$out_dir"
  out="$out_dir/${db}-${stamp}.sql"
  tmp="${out}.tmp.$$"
  if docker compose -f "$STACK_DIR/docker-compose.yml" exec -T postgres \
      pg_dump -U "$PGUSER" -d "$db" -f /dev/stdout > "$tmp" 2> /dev/null < /dev/null; then
    mv "$tmp" "$out"
    echo "backed up $db -> $out"
  else
    echo "FAILED: pg_dump $db" >&2
    rm -f "$tmp"
    failed=1
  fi
  # Prune old copies.
  ls -1t "$out_dir"/"${db}"-*.sql 2>/dev/null | tail -n +$((KEEP_N + 1)) | xargs -r rm -f
done <<< "$dbs"

exit "$failed"
