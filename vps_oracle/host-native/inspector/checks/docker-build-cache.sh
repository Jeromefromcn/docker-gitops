#!/usr/bin/env bash
# checks/docker-build-cache.sh
#
# Prunes docker build cache older than
# INSPECTOR_BUILD_CACHE_MAX_AGE_SECONDS (default 7 days). Design spec's
# "Docker build cache" row (auto tier). Unlike the other checks this one
# cannot enumerate candidates per-entry for a would-delete list: builder
# records have no stable per-entry CLI listing, so dry-run reports the
# would-run command plus the current total instead, and the real run
# reports what prune reclaimed.
#
# --all is required: without it, prune skips any cache record still
# referenced by an existing image ("in use"), which in practice is most
# of the cache on this host (only ccr/switchboard build local images),
# so plain `docker builder prune` silently reclaimed nothing every run
# while still reporting "deleted". --all costs a slower rebuild next
# time those two stacks are built, nothing else.
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
    "would run: docker builder prune -f --all --filter until=${MAX_AGE_SECONDS}s (current total ${total})"
elif output="$(docker builder prune -f --all --filter "until=${MAX_AGE_SECONDS}s" 2>/dev/null)"; then
  # Older docker CLIs print a "Total reclaimed space: <size>" summary
  # line; newer ones (confirmed on 29.6.0) print a du-style table
  # ending in "Total:\t<size>" instead, with no "reclaimed" wording at
  # all -- support both rather than assuming one.
  reclaimed="$(awk '
    /^Total reclaimed space:/ { print $NF; exit }
    /^Total:/ { t = $NF }
    END { if (t) print t }
  ' <<<"$output")"
  # Empty (no size line matched) or "0B" (matched but nothing pruned)
  # both mean no candidate existed -- stay silent like the other auto
  # checks do when they find nothing, instead of reporting a "deleted"
  # action for a no-op run.
  [ -n "$reclaimed" ] && [ "$reclaimed" != "0B" ] || exit 0
  emit_result "auto" "deleted" "docker build cache" \
    "pruned cache records older than ${MAX_AGE_SECONDS}s, reclaimed ${reclaimed} of ${total}"
else
  emit_result "alert" "flagged" "docker build cache" \
    "docker builder prune failed — manual investigation needed (total was ${total})"
fi
