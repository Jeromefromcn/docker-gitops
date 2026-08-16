#!/usr/bin/env bash
# checks/docker-unused-volumes.sh
#
# Flags volumes not referenced by any container (docker's dangling
# filter). Design spec's "Docker 未用 volume" row (ALERT ONLY — a volume
# may hold the only copy of data; the cost of a wrong removal is
# asymmetric). Anonymous volumes (64-hex names, created implicitly by
# compose recreation) are aggregated into one summary line; named
# volumes get one line each.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

docker info >/dev/null 2>&1 || {
  emit_result "alert" "flagged" "check:docker-unused-volumes.sh" \
    "docker daemon unreachable — check skipped"
  exit 0
}

mapfile -t vols < <(docker volume ls --filter dangling=true --format '{{.Name}}' 2>/dev/null)
[ "${#vols[@]}" -eq 0 ] && exit 0

anonymous_count=0
named=()
for v in "${vols[@]}"; do
  [ -n "$v" ] || continue
  if [[ "$v" =~ ^[0-9a-f]{64}$ ]]; then
    anonymous_count=$((anonymous_count + 1))
  else
    named+=("$v")
  fi
done

if [ "$anonymous_count" -gt 0 ]; then
  emit_result "alert" "flagged" "docker anonymous volumes x${anonymous_count}" \
    "not mounted by any container (leftovers from compose recreation; review with 'docker volume inspect' / 'docker system df -v' before removing)"
fi

for n in "${named[@]:-}"; do
  [ -n "$n" ] || continue
  emit_result "alert" "flagged" "docker volume $n" \
    "named volume not mounted by any container — may hold data, manual review needed"
done
