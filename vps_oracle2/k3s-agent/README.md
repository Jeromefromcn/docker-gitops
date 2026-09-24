# vps_oracle2/k3s-agent

vps-oracle2 is a **k3s agent (worker) node** of the cluster whose server runs on vps_oracle ([`vps_oracle/k3s/`](../../vps_oracle/k3s/README.md)). The control plane and every management component stay on vps_oracle; this node only runs workloads that explicitly tolerate its taint (lab-environment), plus the per-node DaemonSets (cilium, cilium-envoy, istio-cni, ztunnel).

Like everything under `vps_oracle2/`, nothing here is cloned onto oracle2. [`install.sh`](install.sh) runs **on vps_oracle** and drives oracle2 over SSH.

## Files

| File | What it is |
|---|---|
| [`config.yaml`](config.yaml) | the agent's `/etc/rancher/k3s/config.yaml` — server URL, tailscale node IP, `lb-server-port`, taint/label. Source of truth; the copy on oracle2 is derived from it |
| [`install.sh`](install.sh) | idempotent install/reconcile: pushes `config.yaml` if it drifted (then restarts `k3s-agent`), installs the pinned k3s version if missing or different |

```bash
vps_oracle2/k3s-agent/install.sh    # on vps_oracle
```

The join token is read from the server (`/var/lib/rancher/k3s/server/node-token`) and piped over SSH stdin into the installer — never in git, never in a process argv. The installer persists it on oracle2 in `/etc/systemd/system/k3s-agent.service.env`.

## Why these settings

- **Tailscale addressing.** The two hosts are in separate OCI tenancies; oracle2 cannot reach vps_oracle's VCN address `10.0.0.95`. Both nodes use their tailscale IP as node IP (the server's side is in `vps_oracle/k3s/install/config.yaml`), so Cilium's VXLAN tunnel runs inside tailscale's WireGuard. Pod MTU is 1230 (tailscale0 1280 − 50 VXLAN), auto-detected by Cilium.
- **ACL.** Only this node's k3s ports toward vps_oracle are open (tcp 6443, udp 8472, tcp 4240, icmp) — the one exception to oracle2's otherwise one-directional access, pinned by tests in [`tailscale/policy.hujson`](../../tailscale/policy.hujson).
- **`lb-server-port: 6443`.** Cilium is installed with `k8sServiceHost: 127.0.0.1`/`6443`. On the server that's the apiserver itself; moving the agent's local apiserver load-balancer to the same port makes the one Cilium config valid on both nodes, and keeps the server's own Cilium independent of tailscale.
- **Taint `dedicated=lab:NoSchedule`.** Keeps management components off this node. Anything meant to run here needs the matching toleration.

## If oracle2's tailscale IP changes

(e.g. after `tofu destroy`/`apply`, see [`../README.md`](../README.md)) — update `node-ip` here and rerun `install.sh`; also delete the stale `Node` object (`kubectl delete node <old>`) if the hostname changed.
