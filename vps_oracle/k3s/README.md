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

**Known gotcha — host firewall blocks pod → apiserver traffic.** This host's iptables `INPUT` chain (persisted at `/etc/iptables/rules.v4` via `iptables-persistent`) only allow-lists new inbound TCP on 22/80/443, default-REJECT otherwise. Cilium's kube-proxy replacement does socket-level load-balancing: any pod that connects to the `kubernetes` ClusterIP (`10.43.0.1:443`) gets that connection transparently rewritten to the real backend, the node's own `<node-ip>:6443`. That rewritten packet leaves the pod via the node's physical NIC (Cilium's "Direct Routing" mode) and is filtered by the host's normal `INPUT` chain like any other inbound connection — the 22/80/443 allow-list doesn't cover 6443, so it gets ICMP `host-prohibited` rejected. Symptom: CoreDNS pod never goes `Ready` (`plugin/kubernetes: ... no route to host` reaching the apiserver), which cascades into cluster DNS being broken and Hubble Relay crash-looping (`dial udp ...:53: no route to host` resolving `hubble-peer`), even though `cilium status` reports `KubeProxyReplacement: True` and the node is `Ready`.

Fix: allow the Cilium pod CIDR to reach 6443, scoped (not opened to the internet):
```bash
sudo iptables -I INPUT 9 -p tcp -s 10.0.0.0/24 -m tcp --dport 6443 -j ACCEPT
# persist: add the same -A INPUT line to /etc/iptables/rules.v4 above the final REJECT, or `sudo netfilter-persistent save`
```
Verify the pod CIDR with `kubectl -n kube-system get cm cilium-config -o yaml | grep cluster-pool` (this cluster's Cilium IPAM allocates from `10.0.0.0/8` in `/24`s per node; the live node's block was `10.0.0.0/24` at install time — confirm before reusing this rule on a different node).
