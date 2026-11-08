#!/usr/bin/env bash
# Provision the read-only user that elasticsearch-exporter (this stack) uses.
# Idempotent: ES_EXPORTER_PASSWORD in ../.env is generated once and reused.
#
# Role prometheus_exporter: cluster `monitor` only (health, node stats). No index
# privileges — the exporter runs without --es.indices, so it reads no app data.
# After the first run: docker compose up -d elasticsearch-exporter
set -euo pipefail

cd "$(dirname "$0")/.."
ENV_FILE=".env"
ES_URL="${ES_URL:-http://127.0.0.1:9200}"

[[ -f "$ENV_FILE" ]] || { echo "error: $ENV_FILE not found" >&2; exit 1; }
elastic_pw="$(grep -E '^ELASTIC_PASSWORD=' "$ENV_FILE" | tail -n1 | cut -d= -f2-)"
[[ -n "$elastic_pw" ]] || { echo "error: ELASTIC_PASSWORD empty in $ENV_FILE" >&2; exit 1; }

es_put() {
  local path="$1" body="$2" out code
  out="$(curl -sS -X PUT -K <(printf 'user = "elastic:%s"\n' "${elastic_pw//\"/\\\"}") \
          -H 'Content-Type: application/json' --data-binary @<(printf '%s' "$body") \
          -w '\n%{http_code}' "$ES_URL$path")"
  code="${out##*$'\n'}"
  [[ "$code" == 2* ]] || { echo "error: PUT $path -> HTTP $code: ${out%$'\n'*}" >&2; exit 1; }
}

pw="$(grep -E '^ES_EXPORTER_PASSWORD=' "$ENV_FILE" | tail -n1 | cut -d= -f2- || true)"
if [[ -z "$pw" ]]; then
  pw="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32)"
  printf 'ES_EXPORTER_PASSWORD=%s\n' "$pw" >> "$ENV_FILE"
  echo "generated ES_EXPORTER_PASSWORD in $ENV_FILE"
fi
chmod 600 "$ENV_FILE"

es_put /_security/role/prometheus_exporter '{"cluster":["monitor"],"indices":[]}'
es_put /_security/user/prometheus_exporter \
  "$(jq -nc --arg pw "$pw" '{password: $pw, roles: ["prometheus_exporter"]}')"
echo "user prometheus_exporter: role prometheus_exporter (cluster monitor only)"
