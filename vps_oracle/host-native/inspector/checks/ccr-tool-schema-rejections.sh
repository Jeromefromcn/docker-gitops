#!/usr/bin/env bash
# checks/ccr-tool-schema-rejections.sh
#
# Reads ccr's request-log database and reports requests the upstream
# provider refused because of a tool schema. ALERT ONLY — there is
# nothing to delete or clean up here.
#
# Why this check exists: 2026-09-25, switching a group's backend to
# ccr/DeepSeek silently broke every older session in that group, one
# 400 per turn, while newly created sessions worked. The cause was
# DeepSeek rejecting a `\0` escape inside a tool `pattern` — an
# incompatibility invisible from the outside, because ccr faithfully
# relays the provider's error and the CLI only shows "400 All target
# providers failed". It stayed unnoticed until a human happened to
# resume an old session and went looking.
#
# A schema rejection is never transient, never rate limiting, and never
# something the caller asked for, so alerting on it has no false
# positives from ordinary traffic — which is why this watches this one
# signature rather than the general non-2xx rate (a bad request, an
# expired key or a context-length overflow all legitimately produce 4xx
# and would make a general alert noisy). See
# docs/incidents/2026-09-25-ccr-deepseek-artifact-schema-400.md.
#
# The request-log database lives inside the ccr container's data volume
# (700 root:root, unreadable from the host, and the host has no sqlite3
# anyway), so the work is done by the container's own node. NODE_OPTIONS
# is cleared for that exec so ccr's preload middleware does not run for
# a read-only query.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

CCR_CONTAINER="${INSPECTOR_CCR_CONTAINER:-ccr}"
WINDOW_HOURS="${INSPECTOR_CCR_SCHEMA_WINDOW_HOURS:-24}"
TARGET="ccr request-logs"

docker info >/dev/null 2>&1 || {
  emit_result "alert" "flagged" "check:ccr-tool-schema-rejections.sh" \
    "docker daemon unreachable — check skipped"
  exit 0
}

running="$(docker inspect --format '{{.State.Running}}' "$CCR_CONTAINER" 2>/dev/null)" || running=""
if [ -z "$running" ]; then
  # No such container: ccr may legitimately not exist on a host this is
  # copied to. Same reasoning as the npm check.
  exit 0
fi
if [ "$running" != "true" ]; then
  emit_result "alert" "flagged" "docker container $CCR_CONTAINER" \
    "container is not running — provider request failures cannot be inspected, and every group routed through ccr is broken"
  exit 0
fi

# The sqlite query, piped into the container's node on stdin. Counting the
# window's failures alongside the matches gives the report a denominator:
# "2 of 5 failed" reads very differently from "2 of 4000".
read -r -d '' QUERY_JS <<'JS'
const Database = require("better-sqlite3");
const DB = "/data/.claude-code-router/app-data/request-logs.sqlite";
const hours = Number(process.env.CCR_SCHEMA_WINDOW_HOURS || 24);
const since = new Date(Date.now() - hours * 3600 * 1000).toISOString();
const SIGS = [
  ["Invalid schema for function", "%Invalid schema for function%"],
  ["not valid under any of the schemas", "%is not valid under any of the schemas%"],
];
let out;
try {
  const db = new Database(DB, { readonly: true });
  const failed = db
    .prepare("SELECT COUNT(*) AS n FROM request_logs WHERE created_at >= ? AND (status_code >= 400 OR ok = 0)")
    .get(since).n;
  const where = SIGS.map(() => "response_body_text LIKE ?").join(" OR ");
  const rows = db
    .prepare(
      "SELECT id, created_at, provider, resolved_model, status_code, response_body_text " +
        "FROM request_logs WHERE created_at >= ? AND (status_code >= 400 OR ok = 0) AND (" + where + ") " +
        "ORDER BY id DESC"
    )
    .all(since, ...SIGS.map((s) => s[1]));
  const matched = rows.map((r) => {
    const hit = SIGS.find((s) => (r.response_body_text || "").includes(s[0]));
    return {
      id: r.id,
      created_at: r.created_at,
      provider: r.provider,
      resolved_model: r.resolved_model,
      status_code: r.status_code,
      signature: hit ? hit[0] : "unknown",
    };
  });
  db.close();
  out = { ok: true, scanned: failed, matched: matched };
} catch (e) {
  out = { ok: false, error: String((e && e.message) || e) };
}
console.log(JSON.stringify(out));
JS

query_out="$(printf '%s' "$QUERY_JS" | docker exec -i \
  -e NODE_OPTIONS= -e NODE_PATH=/app/node_modules \
  -e CCR_SCHEMA_WINDOW_HOURS="$WINDOW_HOURS" \
  "$CCR_CONTAINER" node 2>/dev/null)" || query_out=""

jq -e 'type == "object" and has("ok")' <<<"$query_out" >/dev/null 2>&1 || {
  emit_result "alert" "flagged" "$TARGET" \
    "could not query the request-log database inside $CCR_CONTAINER (docker exec returned nothing parseable) — the data volume or the image's node may have moved"
  exit 0
}

if [ "$(jq -r '.ok' <<<"$query_out")" != "true" ]; then
  emit_result "alert" "flagged" "$TARGET" \
    "request-log query failed: $(jq -r '.error // "unknown error"' <<<"$query_out")"
  exit 0
fi

count="$(jq -r '.matched | length' <<<"$query_out")"
[ "$count" -eq 0 ] && exit 0

failed_total="$(jq -r '.scanned' <<<"$query_out")"
providers="$(jq -r '[.matched[].provider] | unique | join(", ")' <<<"$query_out")"
latest="$(jq -r '.matched[0].created_at' <<<"$query_out")"

emit_result "alert" "flagged" "$TARGET" \
  "$count of $failed_total failed request(s) in the last ${WINDOW_HOURS}h were refused by the provider over a tool schema ($providers, latest $latest) — this is never transient and never something the caller asked for; the outgoing schema needs sanitising, see docs/incidents/2026-09-25-ccr-deepseek-artifact-schema-400.md"
