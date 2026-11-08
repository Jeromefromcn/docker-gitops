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
# With --audit-pattern P (P must start with `audit-<app>-`; dev pattern Pd is P
# with `audit-<app>-` -> `audit-<app>_dev-`):
#   role <app>_audit_writer      -> create_doc + create_index on P   (on user <app>)
#   role <app>_dev_audit_writer  -> create_doc + create_index on Pd  (on user <app>_dev)
#   role+user <app>_audit_reader      -> read on P only
#   role+user <app>_audit_reader_dev  -> read on Pd only
#   The writers can create the index (with the app's own strict mapping) and
#   append docs, but not read, update, delete docs, delete the index or change
#   settings. They CAN add fields via PUT _mapping (create_index includes it).
#   The readers have no access to <app>-* / <app>_dev-* at all.
#   Also sets cluster `action.auto_create_index: -audit-*,+*`, so a write to a
#   missing audit index fails (404) instead of auto-creating it with a dynamic
#   mapping — create_index alone would still allow auto-creation (tested).
#
# Why the restrictions:
#   - ES roles are additive (no deny). An audit pattern inside <app>-* would be
#     covered by <app>_rw's `all`, so audit indices live under the reserved
#     `audit-` prefix instead, outside every app's namespace.
#   - No `-`/`_` in app names: with `rag` and `rag-x`, `rag-*` would also match
#     `rag-x-*`. Alphanumeric names keep every `<app>-*` / `<app>_dev-*` disjoint.
#
# Passwords: APP_<APP>_PASSWORD / APP_<APP>_DEV_PASSWORD (and, with an audit
# pattern, APP_<APP>_AUDIT_READER_PASSWORD / APP_<APP>_AUDIT_READER_DEV_PASSWORD) in ../.env (gitignored,
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
      '{cluster: [], indices: [{names: [$p], privileges: ["create_doc", "create_index"]}]}')" >/dev/null
    roles="$(jq -c --arg r "$audit_role" '. + [$r]' <<<"$roles")"
    echo "role  ${audit_role}: create_doc+create_index on ${audit}"
  fi

  local pw; pw="$(get_or_create_password "$pw_var")"
  es PUT "/_security/user/${user}" "$(jq -nc --arg pw "$pw" --argjson roles "$roles" \
    '{password: $pw, roles: $roles}')" >/dev/null
  echo "user  ${user}: roles $(jq -r 'join(",")' <<<"$roles"), password in ${PWD}/${ENV_FILE} (${pw_var})"
}

# provision_audit_reader USER PW_VAR PATTERN -> read-only user on the audit pattern
provision_audit_reader() {
  local user="$1" pw_var="$2" pattern="$3"
  es PUT "/_security/role/${user}" "$(jq -nc --arg p "$pattern" \
    '{cluster: ["cluster:monitor/main"], indices: [{names: [$p], privileges: ["read"]}]}')" >/dev/null
  local pw; pw="$(get_or_create_password "$pw_var")"
  es PUT "/_security/user/${user}" "$(jq -nc --arg pw "$pw" --arg r "$user" \
    '{password: $pw, roles: [$r]}')" >/dev/null
  echo "user  ${user}: read on ${pattern} only, password in ${PWD}/${ENV_FILE} (${pw_var})"
}

# Audit indices are never auto-created, cluster-wide: the app creates them
# explicitly with its own mapping, and a write to a missing one must fail.
# Refuses to overwrite a different existing value.
ensure_no_audit_autocreate() {
  local want="-audit-*,+*" cur
  cur="$(es GET '/_cluster/settings?flat_settings=true' | jq -r '.persistent["action.auto_create_index"] // .transient["action.auto_create_index"] // ""')"
  if [[ -z "$cur" ]]; then
    es PUT /_cluster/settings "$(jq -nc --arg v "$want" '{persistent: {"action.auto_create_index": $v}}')" >/dev/null
  elif [[ "$cur" != "$want" ]]; then
    echo "error: cluster action.auto_create_index is '$cur', expected '$want' — reconcile by hand" >&2
    exit 1
  fi
  echo "cluster action.auto_create_index: ${want}"
}

# Default 0 replicas for this app's indices. Single node, so a replica can never
# be assigned: any index created with the default 1 replica — notably the
# audit indices if the app omits the setting — would turn
# the cluster yellow for good. Scoped to the app's own patterns: a catch-all `*`
# template collides with the built-in .monitoring-* templates (same priority 0)
# or, at a higher priority, would override them. Only one composable template
# applies per index, so a later higher-priority template for these patterns
# must set number_of_replicas 0 itself. Explicit settings in a create-index
# request still win over this template.
es PUT "/_index_template/${app}-defaults" "$(jq -nc --arg a "$app" '{
  index_patterns: ["\($a)-*", "\($a)_dev-*", "audit-\($a)-*", "audit-\($a)_dev-*"],
  priority: 1,
  template: {settings: {number_of_replicas: 0}},
  _meta: {managed_by: "es-provision-app.sh"}}')" >/dev/null
echo "template ${app}-defaults: number_of_replicas 0 on ${app}-*, ${app}_dev-*, audit-${app}-*, audit-${app}_dev-*"

app_uc="$(tr '[:lower:]' '[:upper:]' <<<"$app")"
dev_audit=""
[[ -n "$audit_pattern" ]] && dev_audit="audit-${app}_dev-${audit_pattern#audit-"${app}"-}"

provision "$app"      "APP_${app_uc}_PASSWORD"     "$audit_pattern"
provision "${app}_dev" "APP_${app_uc}_DEV_PASSWORD" "$dev_audit"

if [[ -n "$audit_pattern" ]]; then
  provision_audit_reader "${app}_audit_reader"     "APP_${app_uc}_AUDIT_READER_PASSWORD"     "$audit_pattern"
  provision_audit_reader "${app}_audit_reader_dev" "APP_${app_uc}_AUDIT_READER_DEV_PASSWORD" "$dev_audit"
  ensure_no_audit_autocreate
fi
