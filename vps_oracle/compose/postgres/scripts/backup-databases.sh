#!/usr/bin/env bash
# Logical backup of the unified Postgres instance.
# Runs on the HOST via cron (not in any container):
#   - cluster-global objects (roles, permissions, tablespaces) via pg_dumpall -g
#   - every non-template database via pg_dump
# Output: /etc/postgres/backups/global-objects-YYYYMMDD.sql and
#         /etc/postgres/backups/<db>/<db>-YYYYMMDD.sql, keeping newest KEEP_N each.
#
# Schedule example (host crontab, not committed):
#   30 2 * * * /home/ubuntu/jerome/docker-gitops/vps_oracle/compose/postgres/scripts/backup-databases.sh
#
# Why pg_dumpall -g: pg_dump is per-database and does NOT capture cluster-global
# objects (roles etc.). Backing those up here makes the backup self-contained —
# recreating the instance from these dumps restores an identical role set without
# depending on init/init-databases.sh having been kept in sync. Note: pg_dumpall
# -g exports password hashes, not plaintext — usable for restore, but keep the
# plaintext passwords in .env (gitignored) for provisioning new apps.
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

stamp="$(date +%Y%m%d)"
failed=0

# 1) Cluster-global objects (roles, permissions, tablespaces). Guarded by `|| true`
#    so a failure here doesn't abort the whole script; we record it in `failed`.
g_dir="$BACKUP_ROOT/global-objects"
mkdir -p "$g_dir"
g_out="$g_dir/global-objects-${stamp}.sql"
g_tmp="${g_out}.tmp.$$"
if docker compose -f "$STACK_DIR/docker-compose.yml" exec -T postgres \
    pg_dumpall -g -U "$PGUSER" > "$g_tmp" 2> /dev/null < /dev/null; then
  mv "$g_tmp" "$g_out"
  echo "backed up global objects -> $g_out"
else
  echo "FAILED: pg_dumpall -g" >&2
  rm -f "$g_tmp"
  failed=1
fi
# Prune old global-objects copies.
ls -1t "$g_dir"/global-objects-*.sql 2>/dev/null | tail -n +$((KEEP_N + 1)) | xargs -r rm -f

# 2) Per-database dumps (skip the bootstrap/template ones).
dbs="$(
  docker compose -f "$STACK_DIR/docker-compose.yml" exec -T postgres \
    psql -U "$PGUSER" -d postgres -tAc \
    "SELECT datname FROM pg_database WHERE datistemplate = false AND datname <> 'postgres'"
)"

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
