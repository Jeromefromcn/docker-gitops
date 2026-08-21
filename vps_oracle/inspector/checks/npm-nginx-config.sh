#!/usr/bin/env bash
# checks/npm-nginx-config.sh
#
# Runs `nginx -t` inside the npm container. ALERT ONLY, and safe to run
# at any time: -t parses the config in a throwaway process and exits,
# so it never touches the nginx that is currently serving traffic. A
# failure here is a warning about the NEXT cold start, not a live
# outage.
#
# Why this check exists: NPM writes a literal hostname into proxy_pass
# for every Custom Location (its templates/_location.conf), unlike a
# normal forward which goes through a variable and is resolved per
# request via Docker's embedded DNS. A literal upstream has to resolve
# at config-load time, so once its backend container is gone nginx
# refuses to start at all -- taking down every proxied site, not just
# that one. Nothing surfaces this while the existing nginx process
# keeps running on addresses it resolved earlier; it only detonates on
# the next full restart, which is typically an unrelated one (host
# reboot, image upgrade) at an unrelated time.
#
# 2026-08-21: dify's containers had been stopped for 45h, and upgrading
# npm was what discovered that every site would go down on restart. An
# `nginx -t` at any point during those 45h would have caught it with
# zero downtime.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

NPM_CONTAINER="${INSPECTOR_NPM_CONTAINER:-npm}"

docker info >/dev/null 2>&1 || {
  emit_result "alert" "flagged" "check:npm-nginx-config.sh" \
    "docker daemon unreachable — check skipped"
  exit 0
}

running="$(docker inspect --format '{{.State.Running}}' "$NPM_CONTAINER" 2>/dev/null)" || running=""

if [ -z "$running" ]; then
  # No such container. Treated as a skip rather than an alert: the npm
  # stack may legitimately not exist on a host this script is copied to.
  exit 0
fi

if [ "$running" != "true" ]; then
  emit_result "alert" "flagged" "docker container $NPM_CONTAINER" \
    "container is not running — every proxied site is unreachable, and the nginx config could not be checked"
  exit 0
fi

if output="$(docker exec "$NPM_CONTAINER" nginx -t 2>&1)"; then
  exit 0
fi

# nginx -t failed. The first emerg line names the offending file and
# directive, which is the only part worth carrying into the report;
# fall back to a truncated single-line dump if the format ever changes.
reason="$(grep -m1 'emerg' <<<"$output" | sed 's/^nginx: //')"
[ -z "$reason" ] && reason="$(printf '%s' "$output" | tr '\n' ' ' | cut -c1-300)"

emit_result "alert" "flagged" "npm nginx config" \
  "nginx -t failed: ${reason} — traffic is unaffected for now, but npm will NOT come back up on its next restart until this is fixed"
