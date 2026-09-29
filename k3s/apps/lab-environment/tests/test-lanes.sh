#!/bin/bash
# Renders every lab PR lane the way the lab-lanes ApplicationSet does and
# checks it against the baseline it shadows. Needs kubectl (kustomize),
# python3 and PyYAML; no cluster access.
set -euo pipefail
exec python3 "$(dirname "$0")/test-lanes.py"
