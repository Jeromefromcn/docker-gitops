#!/usr/bin/env bash
# Generate redis/users.acl from .env — declarative per-app ACL provisioning.
# Mirrors the unified Postgres init script (../postgres/init/init-databases.sh):
# each app gets its own identity + namespace, isolated by key prefix.
#
# Output: ./redis/users.acl (gitignored — contains real passwords).
# Run after editing .env:  ./scripts/gen-users-acl.sh   then  docker compose restart redis
set -euo pipefail

cd "$(dirname "$0")/.."
ENV_FILE=".env"
ACL_FILE="redis/users.acl"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "error: $ENV_FILE not found — copy .env.example to .env first" >&2
  exit 1
fi

# shellcheck disable=SC1090
set -a   # auto-export sourced vars so `env` picks up APP_* below
source "$ENV_FILE"
set +a

if [[ -z "${REDIS_PASSWORD:-}" ]]; then
  echo "error: REDIS_PASSWORD is empty in $ENV_FILE" >&2
  exit 1
fi

{
  # NOTE: redis --aclfile requires EVERY line to be a valid `user ...` rule.
  # No comments/blank lines allowed, so the header lives here in the script.
  #
  # Default user = ops superuser, password from REDIS_PASSWORD. Setting a
  # password on the default user is REQUIRED: with an aclfile, requirepass is
  # ignored, and a nopass default user leaves protected-mode on, which refuses
  # non-loopback connections (RedisInsight's AUTH gets DENIED).
  printf 'user default on >%s ~* &* +@all\n' "$REDIS_PASSWORD"
  for entry in $(env | grep -E '^APP_[A-Z0-9_]+_PASSWORD=' | sed 's/^APP_//' | sed 's/_PASSWORD=.*//' | sort -u); do
    # entry is e.g. "NOTES" from APP_NOTES_PASSWORD
    app_lc="$(echo "$entry" | tr '[:upper:]' '[:lower:]')"
    pass_var="APP_${entry}_PASSWORD"
    prefix_var="APP_${entry}_KEY_PREFIX"
    pass="${!pass_var:-}"
    prefix="${!prefix_var:-$app_lc}"
    if [[ -z "$pass" || "$pass" == CHANGE_ME* ]]; then
      echo "error: ${pass_var} is empty or still a placeholder in $ENV_FILE" >&2
      exit 1
    fi
    printf 'user %s on >%s ~%s:* +@all\n' "$app_lc" "$pass" "$prefix"
  done
} > "$ACL_FILE"

echo "Wrote $ACL_FILE with $(grep -c '^user ' "$ACL_FILE" || true) app user(s)."
