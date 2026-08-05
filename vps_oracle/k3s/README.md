# vps_oracle/k3s

Phase A cluster foundation for the [K3s roadmap](../../docs/superpowers/specs/2026-08-05-k3s-cloud-native-platform-roadmap.md). See the [phase A design doc](../../docs/superpowers/specs/2026-08-05-k3s-phase-a-cluster-foundation-design.md) for the full rationale.

## Installed versions

| Component | Version | Resolved on |
|---|---|---|
| k3s | `v1.36.2+k3s1` | 2026-08-05 |

## Install

1. `sudo cp install/config.yaml /etc/rancher/k3s/config.yaml`
2. `curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="v1.36.2+k3s1" sh -`
3. `sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config && sudo chown ubuntu:ubuntu ~/.kube/config && chmod 600 ~/.kube/config`

Re-applying `install/config.yaml` after an edit: copy it to `/etc/rancher/k3s/config.yaml` again, then `sudo systemctl restart k3s`.
