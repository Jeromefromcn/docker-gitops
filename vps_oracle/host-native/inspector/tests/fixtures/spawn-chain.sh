#!/usr/bin/env bash
# spawn-chain.sh OUT_FILE DEPTH
#
# Builds a real chain of DEPTH nested processes, each the direct parent
# of the next, and appends each generation's PID (root first) to
# OUT_FILE. Used only by tests/test-common.sh to exercise
# get_descendants/kill_tree against a real, disposable process tree
# instead of mocking /proc. The trick: each generation backgrounds the
# next generation as a real child *before* exec-ing into `sleep` --
# exec replaces the running program but does not change the PID or its
# already-established parent/child relationships, so the chain survives
# the exec.
out_file="$1"
depth="${2:-3}"

echo "$$" >> "$out_file"

if [ "$depth" -gt 1 ]; then
  bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/spawn-chain.sh" \
    "$out_file" $((depth - 1)) &
fi

exec sleep 300
