#!/usr/bin/env bash
# Declarative app provisioning for the unified Postgres instance.
# Runs on the FIRST init of an empty PGDATA (mounted at /docker-entrypoint-initdb.d/).
# To add a new app: append one `create_role_and_db "app_name"` line below, then
# either re-run on a fresh data dir OR apply it manually (see README "怎么加一个新应用").
#
# Each app gets its own role (LOGIN) and its own database owned by that role —
# the app connects as its own role and only sees its own database.
set -euo pipefail

# psql as the bootstrap superuser (POSTGRES_USER from the container env).
psql=(psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER:-postgres}")

create_role_and_db() {
  local app="$1"
  # CREATE ROLE is not idempotent-safe, so guard on existence.
  if ! "${psql[@]}" -tAc "SELECT 1 FROM pg_roles WHERE rolname='${app}'" | grep -q 1; then
    # Password is placeholder; the app's real connection uses a stronger one set
    # by whoever provisions the app (see README). Kept here so the DB exists
    # with an owner that is not the superuser.
    "${psql[@]}" -c "CREATE ROLE \"${app}\" LOGIN PASSWORD 'change-me'"
  fi
  if ! "${psql[@]}" -tAc "SELECT 1 FROM pg_database WHERE datname='${app}'" | grep -q 1; then
    "${psql[@]}" -c "CREATE DATABASE \"${app}\" OWNER \"${app}\""
  fi
}

# --- user's own apps (add yours here, one line each) ---
create_role_and_db "app_notes"
create_role_and_db "app_todo"
