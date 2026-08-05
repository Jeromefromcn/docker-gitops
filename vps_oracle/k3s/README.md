# vps_oracle/k3s

Phase A cluster foundation for the [K3s roadmap](../../docs/superpowers/specs/2026-08-05-k3s-cloud-native-platform-roadmap.md). See the [phase A design doc](../../docs/superpowers/specs/2026-08-05-k3s-phase-a-cluster-foundation-design.md) for the full rationale.

## Installed versions

| Component | Version | Resolved on |
|---|---|---|
| k3s | `v1.36.2+k3s1` | 2026-08-05 |
| Cilium | `1.20.0` | 2026-08-05 |

## Install

1. `sudo mkdir -p /etc/rancher/k3s`
2. `sudo cp install/config.yaml /etc/rancher/k3s/config.yaml`
3. `curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="v1.36.2+k3s1" sh -`
4. `mkdir -p ~/.kube`
5. `sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config && sudo chown ubuntu:ubuntu ~/.kube/config && chmod 600 ~/.kube/config`
6. Append KUBECONFIG export to `~/.profile` so k3s's kubectl uses the user's config by default:
   ```bash
   echo 'export KUBECONFIG=$HOME/.kube/config' >> ~/.profile
   ```
7. Verify kubectl works: `bash -lc 'kubectl get nodes'`

Re-applying `install/config.yaml` after an edit: copy it to `/etc/rancher/k3s/config.yaml` again, then `sudo systemctl restart k3s`.

## Cilium

Installed via Helm with `kube-proxy-replacement: true` — k3s's own kube-proxy is disabled (see `install/config.yaml`). Hubble relay + UI are enabled for flow observability.

Reinstall/upgrade: `helm upgrade cilium cilium/cilium --version <pinned> --namespace kube-system -f cilium/values.yaml`

Check health: `cilium status --wait`. View flows: `kubectl -n kube-system port-forward svc/hubble-ui 12000:80`, then open `http://localhost:12000` through an SSH tunnel.

**Known gotcha (fixed) — host firewall blocked pod → host-networked-service traffic.** This host's iptables `INPUT` chain (persisted at `/etc/iptables/rules.v4` via `iptables-persistent`) only allow-listed new inbound TCP on 22/80/443, default-REJECT otherwise. Cilium's kube-proxy replacement does socket-level load-balancing: any pod that connects to a ClusterIP backed by the node itself gets that connection transparently rewritten to `<node-ip>:<port>`. That rewritten packet leaves the pod via the node's physical NIC (Cilium's "Direct Routing" mode) and is filtered by the host's normal `INPUT` chain like any other inbound connection — so any port not on the 22/80/443 allow-list got ICMP `host-prohibited` rejected. This bit three host-networked ports during Phase A bring-up: `6443` (kube-apiserver — broke CoreDNS readiness, which cascaded into cluster DNS and Hubble Relay both failing), `4244` (cilium-agent's `hubble-peer` gRPC service — broke Hubble Relay directly), and `10250` (kubelet's metrics API — broke `metrics-server`).

Fix applied (scoped to the Cilium pod CIDR, not opened to the internet):
```bash
sudo iptables -I INPUT 9 -p tcp -s 10.0.0.0/24 -m tcp --dport 6443 -j ACCEPT
sudo iptables -I INPUT 10 -p tcp -s 10.0.0.0/24 -m tcp --dport 4244 -j ACCEPT
sudo iptables -I INPUT 11 -p tcp -s 10.0.0.0/24 -m tcp --dport 10250 -j ACCEPT
```
Live and persisted as of 2026-08-05 — `/etc/iptables/rules.v4` was updated via `iptables-save` (previous version backed up alongside it) so all three rules survive a reboot; no follow-up needed. Verify the pod CIDR with `kubectl -n kube-system get cm cilium-config -o yaml | grep cluster-pool` before reusing this pattern on a different node (this cluster's Cilium IPAM allocates from `10.0.0.0/8` in `/24`s per node; the live node's block was `10.0.0.0/24` at install time). If a future workload needs to reach some other host-networked port from a pod, the same pattern applies: check `cilium-dbg service list` for a backend on the node's own IP, and add the matching scoped `INPUT` rule.
