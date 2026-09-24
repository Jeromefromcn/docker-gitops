#!/usr/bin/env bash
# vps_oracle2/inspector-checks/checks/oracle2-k3s-containerd-images.sh
#
# vps-oracle2 counterpart of checks/k3s-containerd-images.sh (same tier), for
# oracle2's k3s-agent containerd. Runs `sudo k3s crictl` on oracle2 over SSH
# (see lib/remote.sh oracle2_ssh); CRI has no DOCKER_HOST-style redirection.
#
# Deliberately NOT the local check's `crictl rmi --prune`: prune removes every
# unreferenced image with no way to exclude any, and that is exactly how the
# lab-environment images were lost on 2026-09-24 — ops-lab/* are local-only
# builds (no registry; `docker save | k3s ctr images import`), the lab sat at
# 0 replicas so nothing referenced them, and the local check pruned them. Here
# unreferenced images are enumerated, anything whose tag matches
# INSPECTOR_CONTAINERD_PROTECTED_REGEX (default: any ops-lab/ repo, with or
# without the docker.io/ prefix containerd adds) is kept, and only the rest is
# removed by ID.
#
# No age filter, same reason as the local check: CRI exposes no image
# creation time; kubelet image GC is the age-aware mechanism.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/remote.sh"

PROTECTED_REGEX="${INSPECTOR_CONTAINERD_PROTECTED_REGEX:-(^|/)ops-lab/}"
NAME="oracle2-k3s-containerd-images.sh"

ps_json="$(oracle2_ssh sudo -n k3s crictl ps -a -o json 2>/dev/null)" || {
  emit_result "alert" "flagged" "check:$NAME" \
    "cannot run crictl on vps-oracle2 over SSH (unreachable, sudo, or k3s-agent down) — check skipped"
  exit 0
}
images_json="$(oracle2_ssh sudo -n k3s crictl images -o json 2>/dev/null)" || {
  emit_result "alert" "flagged" "check:$NAME" \
    "crictl images failed on vps-oracle2 — check skipped"
  exit 0
}

used="$(jq -r '[.containers[].imageRef | sub("^sha256:"; "")]' <<<"$ps_json")"

# One jq pass: unreferenced images split into removable vs protected.
summary="$(jq -c --argjson used "$used" --arg re "$PROTECTED_REGEX" '
  [.images[]
   | .id |= sub("^sha256:"; "")
   | select(.id as $i | $used | index($i) | not)
   | .protected = any(.repoTags[]?; test($re))]
  | {remove: [.[] | select(.protected | not) | {id, size: (.size | tonumber)}],
     protected: ([.[] | select(.protected)] | length)}' <<<"$images_json")" || {
  emit_result "alert" "flagged" "check:$NAME" \
    "could not parse crictl output from vps-oracle2 — check skipped"
  exit 0
}

count="$(jq '.remove | length' <<<"$summary")"
[ "$count" -gt 0 ] || exit 0
total_size="$(jq '[.remove[].size] | add' <<<"$summary")"
protected="$(jq '.protected' <<<"$summary")"
mapfile -t ids < <(jq -r '.remove[].id' <<<"$summary")

detail="${count} images not referenced by any container (incl. exited), total $(human_bytes "$total_size"); kept ${protected} protected (${PROTECTED_REGEX}, local-only builds)"

if [ "${INSPECTOR_DRY_RUN:-0}" = "1" ]; then
  emit_result "auto" "would-delete" "containerd unused images x${count}" "$detail"
elif oracle2_ssh sudo -n ionice -c3 k3s crictl rmi "${ids[@]}" >/dev/null 2>&1; then
  emit_result "auto" "deleted" "containerd unused images x${count}" "$detail"
else
  emit_result "alert" "flagged" "containerd unused images x${count}" \
    "crictl rmi failed on vps-oracle2 — manual investigation needed"
fi
