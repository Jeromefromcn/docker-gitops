#!/usr/bin/env bash
# checks/docker-stopped-containers.sh
#
# Removes containers in `exited` state whose exit happened more than
# INSPECTOR_STOPPED_CONTAINER_MAX_AGE_SECONDS ago (default 7 days).
# Design spec's "Docker 已停止容器" row (auto tier). Uses explicit
# per-container `docker rm` of enumerated candidates rather than a
# blanket prune, so exactly the reported targets are the ones removed.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

MAX_AGE_SECONDS="${INSPECTOR_STOPPED_CONTAINER_MAX_AGE_SECONDS:-604800}"

docker info >/dev/null 2>&1 || {
  emit_result "alert" "flagged" "check:docker-stopped-containers.sh" \
    "docker daemon unreachable — check skipped"
  exit 0
}

now_epoch="$(date +%s)"

mapfile -t rows < <(docker ps -a --filter status=exited --format '{{.ID}}\t{{.Names}}' 2>/dev/null)
[ "${#rows[@]}" -eq 0 ] && exit 0

for row in "${rows[@]}"; do
  [ -n "$row" ] || continue
  id="${row%%$'\t'*}"
  name="${row#*$'\t'}"

  finished_at="$(docker inspect --format '{{.State.FinishedAt}}' "$id" 2>/dev/null)" || continue
  finished_epoch="$(date -d "$finished_at" +%s 2>/dev/null)" || continue
  age=$((now_epoch - finished_epoch))

  [ "$age" -ge "$MAX_AGE_SECONDS" ] || continue

  if [ "${INSPECTOR_DRY_RUN:-0}" = "1" ]; then
    emit_result "auto" "would-delete" "docker container ${name:-$id}" \
      "exited ${age}s ago (threshold ${MAX_AGE_SECONDS}s)"
  elif docker rm "$id" >/dev/null 2>&1; then
    emit_result "auto" "deleted" "docker container ${name:-$id}" \
      "exited ${age}s ago (threshold ${MAX_AGE_SECONDS}s)"
  else
    emit_result "alert" "flagged" "docker container ${name:-$id}" \
      "docker rm failed (exited ${age}s ago) — manual investigation needed"
  fi
done
