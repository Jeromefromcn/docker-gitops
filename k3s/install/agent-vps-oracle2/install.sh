#!/usr/bin/env bash
# Install or reconcile the k3s agent on vps-oracle2. Run on vps_oracle, from
# anywhere: everything reaches oracle2 over SSH, the repo never lives there.
#
# Idempotent: re-running converges oracle2 back to this directory's config.
# - config.yaml differs from the live copy -> push it, restart k3s-agent
# - agent missing or wrong version          -> run the pinned installer
# The join token is read from this host's k3s server and piped straight into
# the remote installer's environment; it is never written into the repo.
set -euo pipefail

K3S_VERSION="v1.36.2+k3s1"   # must match the server (k3s/README.md)
HOST="vps-oracle2"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

remote() { ssh -o BatchMode=yes "$HOST" "$@"; }

changed=0
if ! remote 'sudo cat /etc/rancher/k3s/config.yaml 2>/dev/null' | cmp -s - "$HERE/config.yaml"; then
  echo "config: pushing $HERE/config.yaml"
  remote 'sudo mkdir -p /etc/rancher/k3s && sudo tee /etc/rancher/k3s/config.yaml >/dev/null' < "$HERE/config.yaml"
  changed=1
fi

current="$(remote 'k3s --version 2>/dev/null | head -1 | cut -d" " -f3' || true)"
if [ "$current" != "$K3S_VERSION" ] || ! remote 'systemctl list-unit-files k3s-agent.service >/dev/null 2>&1'; then
  echo "install: k3s agent ${current:-absent} -> $K3S_VERSION"
  token="$(sudo cat /var/lib/rancher/k3s/server/node-token)"
  # Token goes over stdin, not argv, so it never appears in a process listing.
  printf '%s' "$token" | remote "read -r T; curl -sfL https://get.k3s.io | \
    sudo INSTALL_K3S_VERSION='$K3S_VERSION' INSTALL_K3S_EXEC=agent K3S_TOKEN=\"\$T\" sh -"
elif [ "$changed" = 1 ]; then
  echo "restart: k3s-agent (config changed)"
  remote 'sudo systemctl restart k3s-agent'
else
  echo "up to date: $K3S_VERSION, config unchanged"
fi
