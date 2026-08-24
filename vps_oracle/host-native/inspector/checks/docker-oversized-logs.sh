#!/usr/bin/env bash
# checks/docker-oversized-logs.sh
#
# Flags container json log files whose actual size exceeds
# INSPECTOR_LOG_ALERT_BYTES (default 50MiB). Design spec's "容器日誌檔
# 異常大" row (ALERT ONLY — an oversized log usually means the logging
# config did not take effect, which needs a human to investigate, not a
# truncate). /var/lib/docker/containers is root-only, so this is one of
# the two spec-sanctioned narrowly-scoped sudo uses (the other is
# crictl in k3s-containerd-images.sh). Threshold comparison happens in
# bash, not in find's -size, so tests can exercise it with a stub.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

THRESHOLD_BYTES="${INSPECTOR_LOG_ALERT_BYTES:-52428800}"

docker info >/dev/null 2>&1 || {
  emit_result "alert" "flagged" "check:docker-oversized-logs.sh" \
    "docker daemon unreachable — check skipped"
  exit 0
}

sudo -n true 2>/dev/null || {
  emit_result "alert" "flagged" "check:docker-oversized-logs.sh" \
    "passwordless sudo unavailable — cannot read /var/lib/docker, check skipped"
  exit 0
}

# Map container id -> name so the report names containers, not hashes.
declare -A id_to_name
while read -r id name; do
  [ -n "$id" ] && id_to_name["$id"]="$name"
done < <(docker ps -a --no-trunc --format '{{.ID}} {{.Names}}' 2>/dev/null)

while read -r size path; do
  [ -n "$size" ] || continue
  [ "$size" -gt "$THRESHOLD_BYTES" ] || continue
  cid="$(basename "$(dirname "$path")")"   # .../containers/<id>/<id>-json.log
  emit_result "alert" "flagged" "docker container ${id_to_name[$cid]:-$cid}" \
    "json log file is ${size} bytes, over ${THRESHOLD_BYTES} threshold — logging limits possibly not effective: $path"
done < <(sudo -n find /var/lib/docker/containers -name '*-json.log' -printf '%s %p\n' 2>/dev/null)
