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

**Non-login shells:** `~/.profile` is only read by login shells. A plain non-login shell (`bash -c '...'` instead of `bash -lc '...'`, and most cron/CI/script contexts) won't pick up `KUBECONFIG`, and `kubectl` fails with a permission-denied error on `/etc/rancher/k3s/k3s.yaml` that reads like a bug rather than an unset env var. Those contexts need `export KUBECONFIG=$HOME/.kube/config` set explicitly before calling `kubectl`.

## Cilium

Installed via Helm with `kube-proxy-replacement: true` — k3s's own kube-proxy is disabled (see `install/config.yaml`). Hubble relay + UI are enabled for flow observability.

Reinstall/upgrade: `helm upgrade cilium cilium/cilium --version 1.20.0 --namespace kube-system -f cilium/values.yaml`

Check health: `cilium status --wait`. View flows: `kubectl -n kube-system port-forward svc/hubble-ui 12000:80`, then open `http://localhost:12000` through an SSH tunnel.

### Pod CIDR

Cilium's cluster-pool IPAM defaults to carving `10.0.0.0/8` into per-node `/24`s. On this host that allocated `10.0.0.0/24` — which is *also* this node's real Oracle VCN subnet (`enp0s6` is `10.0.0.95/24`, DHCP-assigned). The collision silently black-holed traffic to any other host on the VCN: `ip route get 10.0.0.50` resolved via `cilium_host` instead of the physical NIC.

Fixed on 2026-08-06 by pinning an explicit, non-default pod CIDR in `cilium/values.yaml`, clear of both the host subnet and the docker bridge networks (`172.17-24.0.0/16`):
```yaml
ipam:
  mode: cluster-pool
  operator:
    clusterPoolIPv4PodCIDRList:
      - "10.42.0.0/16"
    clusterPoolIPv4MaskSize: 24
```
Applied with the same `helm upgrade` command above, then forced IPAM to re-allocate: `kubectl delete ciliumnode --all && kubectl -n kube-system rollout restart daemonset/cilium` (safe only because the `workloads` namespace was empty at the time — deleting the `CiliumNode` invalidates in-flight pod IPs). Every `kube-system` deployment holding a pod IP from before the migration needs a `kubectl rollout restart deployment/<name>` afterward, since Cilium won't reconcile an already-running pod's IP on its own — `hubble-relay`, `hubble-ui`, and `metrics-server` needed this immediately; `local-path-provisioner` was missed on the first pass (it kept running "successfully" on its stale `10.0.0.x` IP with zero apiserver connectivity and no probes to surface it — caught later via `cilium status`'s `Cluster Pods: N/M managed by Cilium` count reading less than the total pod count). **After any future re-IPAM, check `cilium status | grep "Cluster Pods"` and restart every `kube-system` deployment until it reads `N/N`, don't assume three known names is the complete list.**

Verify: `kubectl get ciliumnode -o jsonpath='{.items[0].spec.ipam.podCIDRs}'` → `10.42.x.0/24`; `ip route get 10.0.0.50` → resolves via `enp0s6`, not `cilium_host`.

Note: `kubectl get node -o yaml`'s `spec.podCIDR` shows k3s's own built-in default, which is irrelevant since Cilium's cluster-pool IPAM is authoritative — it now happens to also read `10.42.0.0/24`, purely coincidental with the CIDR chosen above, not a sign the two are actually linked.

### NPM traffic is `world` identity, not in-cluster

Cilium classifies any traffic entering from the `npm` docker container (via the compose-node-IP → NodePort bridge, see the root README's NPM section — not Docker's `host-gateway`, which doesn't reach a Cilium NodePort at all) as `world` identity — it never sees it as coming from something in-cluster, because it isn't. A namespace-level default-deny `NetworkPolicy` (like `manifests/netpol-test.yaml`'s `deny-all-ingress`) blocks `world` traffic exactly like any other non-selected source. This matters for every real service migrated behind NPM in a later phase: default-deny + NPM ingress needs an explicit ingress-allow rule for `world`/host-external traffic, not just intra-cluster pod/namespace selectors.

**Known gotcha (fixed) — host firewall blocked pod → host-networked-service traffic.** This host's iptables `INPUT` chain (persisted at `/etc/iptables/rules.v4` via `iptables-persistent`) only allow-listed new inbound TCP on 22/80/443, default-REJECT otherwise. Cilium's kube-proxy replacement does socket-level load-balancing: any pod that connects to a ClusterIP backed by the node itself gets that connection transparently rewritten to `<node-ip>:<port>`. That rewritten packet leaves the pod via the node's physical NIC (Cilium's "Direct Routing" mode) and is filtered by the host's normal `INPUT` chain like any other inbound connection — so any port not on the 22/80/443 allow-list got ICMP `host-prohibited` rejected. This bit three host-networked ports during Phase A bring-up: `6443` (kube-apiserver — broke CoreDNS readiness, which cascaded into cluster DNS and Hubble Relay both failing), `4244` (cilium-agent's `hubble-peer` gRPC service — broke Hubble Relay directly), and `10250` (kubelet's metrics API — broke `metrics-server`).

Fix applied (scoped to the Cilium pod CIDR, not opened to the internet):
```bash
sudo iptables -I INPUT 9 -p tcp -s 10.42.0.0/16 -m tcp --dport 6443 -j ACCEPT
sudo iptables -I INPUT 10 -p tcp -s 10.42.0.0/16 -m tcp --dport 4244 -j ACCEPT
sudo iptables -I INPUT 11 -p tcp -s 10.42.0.0/16 -m tcp --dport 10250 -j ACCEPT
```
Originally applied 2026-08-05 scoped to `10.0.0.0/24`; updated 2026-08-06 to `10.42.0.0/16` as part of the pod-CIDR fix above — the original scoping was accidentally as wide as the entire VCN subnet, not just the pod network, since `10.0.0.0/24` was both at the time. `/etc/iptables/rules.v4` was updated via `iptables-save` (previous version backed up alongside it, timestamped) so all three rules survive a reboot; no follow-up needed. Verify the current pod CIDR with `kubectl get ciliumnode -o jsonpath='{.items[0].spec.ipam.podCIDRs}'` before reusing this pattern after any future re-IPAM. If a future workload needs to reach some other host-networked port from a pod, the same pattern applies: check `cilium-dbg service list` for a backend on the node's own IP, and add the matching scoped `INPUT` rule against the current pod CIDR (`10.42.0.0/16`).

## Namespace & quota

`manifests/namespace.yaml` creates the `workloads` namespace — where phase C+ deploys real services. `manifests/resourcequota.yaml` caps the namespace at `requests.cpu: "1"`, `requests.memory: 2Gi`, `limits.cpu: "1"`, `limits.memory: 2Gi` (request == limit, no slack — phase A's only tenant is the smoke-test workload; bump the quota directly if a later phase needs more, it won't disturb pods already running). `manifests/limitrange.yaml` gives any container that omits its own `resources` a default of `100m`/`128Mi` requests and `200m`/`256Mi` limits, so a workload that forgets to set resources can't silently eat the whole quota. Neither applies to `kube-system` (Cilium, Hubble, CoreDNS, local-path-provisioner) — the quota only governs `workloads`, that's expected, not a gap.

## Verification runbook

`manifests/` holds the reusable connectivity/policy verification tooling for this cluster — kept in the repo so later phases can rerun it, not just phase A. Apply order:

1. Namespace/quota (idempotent, only needed if the namespace was ever deleted):
   ```bash
   kubectl apply -f manifests/namespace.yaml -f manifests/resourcequota.yaml -f manifests/limitrange.yaml
   ```
2. Smoke-test workload — Deployment + NodePort Service + `netpol-tester` pod:
   ```bash
   kubectl apply -f manifests/smoke-test.yaml
   ```
   **Do not** also apply `manifests/netpol-test.yaml` yet — see the header comment in both files. Applying the NetworkPolicy first blocks the very connectivity this step exists to prove.
3. Run the four checks:
   - **NodePort:** `curl http://localhost:30080` → nginx welcome page.
   - **ResourceQuota usage:** `kubectl describe resourcequota workloads-quota -n workloads` → `Used` reflects the smoke-test pod's requests/limits.
   - **NetworkPolicy enforcement:** `kubectl apply -f manifests/netpol-test.yaml`, then `kubectl -n workloads exec netpol-tester -- wget -qO- --timeout=3 http://smoke-test.workloads.svc.cluster.local` → times out (proves Cilium enforces `NetworkPolicy`, not just routes traffic). Then `kubectl delete -f manifests/netpol-test.yaml` before the NPM check below — NPM's traffic is `world` identity (see above) and the deny-all policy would block it too, which isn't what that check is testing.
   - **NPM end-to-end:** create a temporary NPM proxy host per the root README's "给服务接入 NPM 反代" section (note its NodePort gotcha: Forward Hostname/IP must be the node's literal IP, not a hostname), then `curl` the domain from outside. Delete the proxy host afterward.
4. Teardown:
   ```bash
   kubectl delete -f manifests/smoke-test.yaml
   kubectl delete -f manifests/netpol-test.yaml   # only if still applied
   kubectl get pods -n workloads                  # expect: No resources found
   ```

## Handoff to phase B

Phase B (ArgoCD + CI skeleton) picks up from here: a reachable, empty cluster with CNI/NetworkPolicy/storage/quota already in place, and this `vps_oracle/k3s/` directory as the established convention for where its own non-secret config lands.
