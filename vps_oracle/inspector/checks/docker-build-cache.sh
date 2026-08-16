#!/usr/bin/env bash
# checks/docker-build-cache.sh
#
# Prunes docker build cache older than
# INSPECTOR_BUILD_CACHE_MAX_AGE_SECONDS (default 7 days). Design spec's
# "Docker build cache" row (auto tier). Unlike the other checks this one
# cannot enumerate candidates per-entry for a would-delete list: builder
# records have no stable per-entry CLI listing, so dry-run reports the
# would-run command plus the current total instead, and the real run
# reports what prune reclaimed. Host currently has 0B build cache, so
# the common case is silence.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

MAX_AGE_SECONDS="${INSPECTOR_BUILD_CACHE_MAX_AGE_SECONDS:-604800}"

docker info >/dev/null 2>&1 || {
  emit_result "alert" "flagged" "check:docker-build-cache.sh" \
    "docker daemon unreachable — check skipped"
  exit 0
}

total="$(docker builder du 2>/dev/null | awk '/^Total:/ {print $2}')"
[ -n "$total" ] || exit 0
[ "$total" = "0B" ] && exit 0

if [ "${INSPECTOR_DRY_RUN:-0}" = "1" ]; then
  emit_result "auto" "would-delete" "docker build cache" \
    "would run: docker builder prune -f --filter until=${MAX_AGE_SECONDS}s (current total ${total})"
elif output="$(docker builder prune -f --filter "until=${MAX_AGE_SECONDS}s" 2>/dev/null)"; then
  reclaimed="$(awk '/^Total reclaimed space:/ {print $NF}' <<<"$output")"
  emit_result "auto" "deleted" "docker build cache" \
    "pruned cache records older than ${MAX_AGE_SECONDS}s, reclaimed ${reclaimed:-unknown} of ${total}"
else
  emit_result "alert" "flagged" "docker build cache" \
    "docker builder prune failed — manual investigation needed (total was ${total})"
fi
