#!/usr/bin/env bash
# checks/k3s-containerd-images.sh
#
# Reports and prunes containerd images not referenced by any container
# (including exited ones) on the k3s node. Design spec's "k3s
# containerd 未用 image" row (auto tier). crictl needs root (socket +
# config are root-only) — this and docker-oversized-logs.sh are the two
# narrowly-scoped sudo uses the spec's deployment section sanctions.
#
# No age filter, deliberately: CRI exposes no image creation timestamp,
# and `crictl rmi --prune` (the spec's named action) has none either.
# Kubelet image GC is the age-aware primary mechanism; this is the
# backstop that reports what's sitting unused.
#
# ionice -c3 (idle) on the actual prune: 2026-08-18 incident — a
# migration backlog of stale k3s images made one prune run sustain IO
# PSI full 25-31% for ~7min (vs. no measurable impact on ordinary
# runs), long enough to cross the io_pressure_critical alert
# threshold. Idle class makes this check yield IO to every other
# process on the box instead of contending for it.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

sudo -n true 2>/dev/null || {
  emit_result "alert" "flagged" "check:k3s-containerd-images.sh" \
    "passwordless sudo unavailable — cannot run crictl, check skipped"
  exit 0
}

ps_json="$(sudo -n crictl ps -a -o json 2>/dev/null)" || {
  emit_result "alert" "flagged" "check:k3s-containerd-images.sh" \
    "crictl ps failed — check skipped"
  exit 0
}
images_json="$(sudo -n crictl images -o json 2>/dev/null)" || {
  emit_result "alert" "flagged" "check:k3s-containerd-images.sh" \
    "crictl images failed — check skipped"
  exit 0
}

used_file="$(mktemp)"
trap 'rm -f "$used_file"' EXIT
jq -r '.containers[].imageRef' <<<"$ps_json" | sed 's/^sha256://' | sort -u > "$used_file"

count=0
total_size=0
while read -r line; do
  [ -n "$line" ] || continue
  id="$(jq -r '.id' <<<"$line")"
  id="${id#sha256:}"
  grep -qx "$id" "$used_file" && continue
  size="$(jq -r '.size' <<<"$line")"
  count=$((count + 1))
  total_size=$((total_size + size))
done < <(jq -c '.images[]' <<<"$images_json")

[ "$count" -gt 0 ] || exit 0

detail="${count} images not referenced by any container (incl. exited), total ${total_size} bytes — no age filter: CRI exposes no image creation time; kubelet image GC is the age-aware mechanism"

if [ "${INSPECTOR_DRY_RUN:-0}" = "1" ]; then
  emit_result "auto" "would-delete" "containerd unused images x${count}" "$detail"
elif output="$(sudo -n ionice -c3 crictl rmi --prune 2>/dev/null)"; then
  emit_result "auto" "deleted" "containerd unused images x${count}" "$detail"
else
  emit_result "alert" "flagged" "containerd unused images x${count}" \
    "crictl rmi --prune failed — manual investigation needed"
fi
