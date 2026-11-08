#!/usr/bin/env bash
# Provision an app's isolated prod + dev pools on the shared Elasticsearch.
# Idempotent: safe to re-run; existing passwords in .env are reused, never rotated.
#
# Usage:
#   ./scripts/es-provision-app.sh <app> [--audit-pattern 'audit-<app>-<name>-*']
#
# Creates, for <app> (must match ^[a-z][a-z0-9]*$):
#   role <app>_rw      -> all privileges on <app>-*        ; user <app>
#   role <app>_dev_rw  -> all privileges on <app>_dev-*    ; user <app>_dev
# With --audit-pattern P (P must start with `audit-<app>-`):
#   role <app>_audit_writer      -> create_doc + auto_configure on P
#   role <app>_dev_audit_writer  -> same on P with `audit-<app>-` -> `audit-<app>_dev-`
#   each attached to the matching user (append-only: no read/update/delete there).
#
# Why the restrictions:
#   - ES roles are additive (no deny). An audit pattern inside <app>-* would be
#     covered by <app>_rw's `all`, so audit indices live under the reserved
#     `audit-` prefix instead, outside every app's namespace.
#   - No `-`/`_` in app names: with `rag` and `rag-x`, `rag-*` would also match
#     `rag-x-*`. Alphanumeric names keep every `<app>-*` / `<app>_dev-*` disjoint.
#
# Passwords: APP_<APP>_PASSWORD / APP_<APP>_DEV_PASSWORD in ../.env (gitignored,
# chmod 600), generated on first run. The elastic password is read from the
# same file. Credentials go to curl via /dev/fd, never on the command line.
set -euo pipefail

cd "$(dirname "$0")/.."
ENV_FILE=".env"
ES_URL="${ES_URL:-http://127.0.0.1:9200}"

usage() { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

app="${1:-}"; [[ -n "$app" ]] || usage; shift
audit_pattern=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --audit-pattern) audit_pattern="${2:-}"; [[ -n "$audit_pattern" ]] || usage; shift 2 ;;
    *) usage ;;
  esac
done

[[ "$app" =~ ^[a-z][a-z0-9]*$ ]] || { echo "error: app name must match ^[a-z][a-z0-9]*\$" >&2; exit 1; }
[[ "$app" != "audit" ]] || { echo "error: 'audit' is reserved for audit index patterns" >&2; exit 1; }
if [[ -n "$audit_pattern" && "$audit_pattern" != "audit-${app}-"* ]]; then
  echo "error: --audit-pattern must start with 'audit-${app}-' (outside the app's own namespace)" >&2
  exit 1
fi

[[ -f "$ENV_FILE" ]] || { echo "error: $ENV_FILE not found — copy .env.example first" >&2; exit 1; }
elastic_pw="$(grep -E '^ELASTIC_PASSWORD=' "$ENV_FILE" | tail -n1 | cut -d= -f2-)"
[[ -n "$elastic_pw" ]] || { echo "error: ELASTIC_PASSWORD empty in $ENV_FILE" >&2; exit 1; }

# es METHOD PATH [JSON_BODY] -> prints body, fails on non-2xx
es() {
  local method="$1" path="$2" body="${3:-}" out code
  # Body always sent (empty for GET); -H is harmless there.
  out="$(curl -sS -X "$method" -K <(printf 'user = "elastic:%s"\n' "${elastic_pw//\"/\\\"}") \
          -H 'Content-Type: application/json' --data-binary @<(printf '%s' "$body") \
          -w '\n%{http_code}' "$ES_URL$path")"
  code="${out##*$'\n'}"; out="${out%$'\n'*}"
  if [[ "$code" != 2* ]]; then
    echo "error: $method $path -> HTTP $code: $out" >&2
    return 1
  fi
  printf '%s\n' "$out"
}

# get_or_create_password VAR -> prints the password, appending to .env if new
get_or_create_password() {
  local var="$1" pw
  pw="$(grep -E "^${var}=" "$ENV_FILE" | tail -n1 | cut -d= -f2- || true)"
  if [[ -z "$pw" ]]; then
    pw="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32)"
    printf '%s=%s\n' "$var" "$pw" >> "$ENV_FILE"
    echo "  generated $var in $ENV_FILE" >&2
  fi
  chmod 600 "$ENV_FILE"
  printf '%s' "$pw"
}

es GET /_security/_authenticate >/dev/null || { echo "error: cannot authenticate as elastic at $ES_URL" >&2; exit 1; }

provision() {
  local user="$1" pw_var="$2" audit="$3" roles
  local rw_role="${user}_rw"
  # cluster:monitor/main = `GET /` only (client info()/version checks); the
  # broader `monitor` privilege would expose every index name via cluster state.
  es PUT "/_security/role/${rw_role}" "$(jq -nc --arg p "${user}-*" \
    '{cluster: ["cluster:monitor/main"], indices: [{names: [$p], privileges: ["all"]}]}')" >/dev/null
  roles="$(jq -nc --arg r "$rw_role" '[$r]')"
  echo "role  ${rw_role}: all on ${user}-*"

  if [[ -n "$audit" ]]; then
    local audit_role="${user}_audit_writer"
    es PUT "/_security/role/${audit_role}" "$(jq -nc --arg p "$audit" \
      '{cluster: [], indices: [{names: [$p], privileges: ["create_doc", "auto_configure"]}]}')" >/dev/null
    roles="$(jq -c --arg r "$audit_role" '. + [$r]' <<<"$roles")"
    echo "role  ${audit_role}: create_doc+auto_configure on ${audit}"
  fi

  local pw; pw="$(get_or_create_password "$pw_var")"
  es PUT "/_security/user/${user}" "$(jq -nc --arg pw "$pw" --argjson roles "$roles" \
    '{password: $pw, roles: $roles}')" >/dev/null
  echo "user  ${user}: roles $(jq -r 'join(",")' <<<"$roles"), password in ${PWD}/${ENV_FILE} (${pw_var})"
}

app_uc="$(tr '[:lower:]' '[:upper:]' <<<"$app")"
dev_audit=""
[[ -n "$audit_pattern" ]] && dev_audit="audit-${app}_dev-${audit_pattern#audit-"${app}"-}"

provision "$app"      "APP_${app_uc}_PASSWORD"     "$audit_pattern"
provision "${app}_dev" "APP_${app_uc}_DEV_PASSWORD" "$dev_audit"
