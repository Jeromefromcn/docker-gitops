#!/usr/bin/env bash
# vps_oracle2/inspector-checks/checks/oracle2-docker-dangling-images.sh
#
# vps-oracle2 counterpart of checks/docker-dangling-images.sh (same logic and tier), run
# from vps_oracle against oracle2's docker over SSH; see lib/remote.sh.
#
# Removes dangling (untagged, unreferenced) images created more than
# INSPECTOR_DANGLING_IMAGE_MAX_AGE_SECONDS ago (default 7 days). Design
# spec's "Docker dangling image" row (auto tier). Per-image `docker rmi`
# of enumerated candidates instead of blanket `docker image prune`:
# prune has no per-image report and would ignore the age threshold.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/remote.sh"

MAX_AGE_SECONDS="${INSPECTOR_DANGLING_IMAGE_MAX_AGE_SECONDS:-604800}"

require_daemon "oracle2-docker-dangling-images.sh"

now_epoch="$(date +%s)"

mapfile -t ids < <(docker images --filter dangling=true --format '{{.ID}}' 2>/dev/null)
[ "${#ids[@]}" -eq 0 ] && exit 0

for id in "${ids[@]}"; do
  [ -n "$id" ] || continue
  created="$(docker image inspect --format '{{.Created}}' "$id" 2>/dev/null)" || continue
  created_epoch="$(date -d "$created" +%s 2>/dev/null)" || continue
  age=$((now_epoch - created_epoch))
  [ "$age" -ge "$MAX_AGE_SECONDS" ] || continue

  if [ "${INSPECTOR_DRY_RUN:-0}" = "1" ]; then
    emit_result "auto" "would-delete" "docker image $id" \
      "dangling, created ${age}s ago (threshold ${MAX_AGE_SECONDS}s)"
  elif docker rmi "$id" >/dev/null 2>&1; then
    emit_result "auto" "deleted" "docker image $id" \
      "dangling, created ${age}s ago (threshold ${MAX_AGE_SECONDS}s)"
  else
    emit_result "alert" "flagged" "docker image $id" \
      "docker rmi failed (dangling, created ${age}s ago) — manual investigation needed"
  fi
done
