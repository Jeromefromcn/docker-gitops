# K3s Phase A — Cluster Foundation Design

Date: 2026-08-05

Corresponds to phase A of the [K3s Cloud-Native Lab Platform Roadmap](2026-08-05-k3s-cloud-native-platform-roadmap.md): K3s + containerd + Cilium (CNI/NetworkPolicy) + storage + resource budget (ResourceQuota/LimitRange). Deliverable: an empty but reachable cluster that NPM can route into.

## Scope

**What this phase does:**
- Single-node k3s cluster, Cilium as CNI (including kube-proxy replacement), local-path-provisioner as storage
- One workload namespace with ResourceQuota/LimitRange
- A one-off smoke test to verify the "NPM → k3s" connectivity path and that NetworkPolicy actually blocks traffic
- After validation, the cluster returns to an empty state; `vps_oracle/k3s/` keeps rerunnable validation tooling

**What this phase does not do (left to later phases):**
- Ingress controller selection (Traefik/nginx-ingress) — deferred until phase C actually migrates services; rationale in the "NPM bridging" section below
- ArgoCD/GitOps — phase B
- Any actual service migration — phase C onwards
- NPM's own migration or replacement — the roadmap principle already explicitly defers it to phase H

## Current-State Constraints (continuing the roadmap)

Single 4C/24G machine, existing docker services already consume 11Gi, the 4 CPU cores shared with all services; aarch64 (Ampere Altra), cgroup v2, iptables-nft mode, no ufw; k3s uses its own built-in containerd, a separate container runtime from the host's existing Docker daemon — the two are unaware of each other and do not contend for each other's resource namespaces.

## Architecture

```
Internet ──80/443──▶ npm (docker, unchanged this phase)
                        │ extra_hosts: host-gateway
                        ▼
                  Host IP : NodePort (30000-32767)
                        │
                  ┌─────────────────────────────┐
                  │  k3s single-node cluster (containerd) │
                  │  - Cilium CNI                │
                  │    (kube-proxy replacement)  │
                  │  - Hubble relay + UI          │
                  │  - local-path-provisioner     │
                  │  - namespace: workloads       │
                  │    (ResourceQuota 1C/2Gi)     │
                  │  - smoke-test pod (deleted after validation) │
                  └─────────────────────────────┘
```

## Components & Configuration

| Item | Decision | Rationale |
|---|---|---|
| Topology | Single-node k3s, server role | Only one machine; a k3s server node is schedulable by default, no need to remove a taint |
| CNI | Cilium, `kube-proxy-replacement: true` | One fewer set of iptables rules, one fewer resident process; single-node means no cross-node routing to validate, so enabling it carries the same risk as coexistence mode |
| Cilium tunnel mode | VXLAN (chart default) | Single-node: all pod-to-pod traffic is local, native routing has no practical benefit; use defaults to reduce variables |
| Observability | Install both Hubble relay + UI | Matches the roadmap's SRE learning goal; the resource overhead (two resident pods) sits outside the 1C/2Gi quota, counted as kube-system system overhead |
| k3s built-in Traefik / ServiceLB | `--disable traefik --disable servicelb` at install | Ingress controller selection deferred to phase C; single-node has no use for LoadBalancer-type Services, NodePort suffices |
| Storage | local-path-provisioner, path using k3s default `/var/lib/rancher/k3s/storage` | Matches the path in official docs / community discussions, easier to cross-reference when troubleshooting later |
| Version pinning | At install, check the actual version numbers from the k3s stable channel and the latest Cilium Helm chart, then write the pinned versions back to `vps_oracle/k3s/README.md` | This document was written in 2026-08 but the designer's knowledge cutoff is 2026-01; hard-coding version numbers has a high chance of being outdated or nonexistent. Use the "check latest stable at install and pin" procedure in place of concrete numbers, recording the accurate versions only at execution time |
| kubeconfig | Not in repo; copy from `/etc/rancher/k3s/k3s.yaml` to `~/.kube/config`, `chmod 600` | Contains cluster credentials, a secret; the repo convention is "never commit any secrets" |

## Repo Layout

Add `vps_oracle/k3s/`, parallel to `vps_oracle/compose/` (the existing compose stack directory after this re-organization):

```
vps_oracle/k3s/
  README.md              # install steps, validation method, per-phase version records
  install/config.yaml     # k3s server startup params (non-secret)
  cilium/values.yaml       # Helm values (non-secret)
  manifests/
    namespace.yaml         # workloads namespace
    resourcequota.yaml      # 1 core / 2Gi
    limitrange.yaml          # defaults applied to pods that don't set resources
    smoke-test.yaml           # nginx + fixed NodePort 30080, reusable connectivity/NetworkPolicy validation tool
```

Nothing under `vps_oracle/k3s/` holds any kubeconfig, node token or other secret — those stay in `/etc/rancher/k3s/`, `/var/lib/rancher/k3s/`, and never enter the repo.

## NPM Bridging

NPM (docker compose container) and k3s (independent containerd + CNI network) are two entirely different container runtimes; neither can see the other's container network. The roadmap's migration principle is already explicit: NPM's own network membership/config stays untouched throughout A~G, deferred to phase H for evaluation as to whether a k8s-native ingress replaces it. So there is only one bridging path: **NPM forwards to the host level**, not container-to-container.

Concretely:
- Add to `vps_oracle/compose/npm/docker-compose.yml`:
  ```yaml
  extra_hosts:
    - "host.docker.internal:host-gateway"
  ```
- The k3s-side smoke-test Service uses a fixed `nodePort: 30080` (not random allocation, so NPM's forward rule is reproducible and documentable)
- During validation, create a temporary proxy host in NPM with Forward Hostname/IP set to `host.docker.internal`, Forward Port set to `30080`; delete this temporary record after validation

This pattern (host-gateway forwarding to a host port) keeps working later if phase C actually installs an ingress controller — same mechanism, just the Forward Port changes to the ingress controller's NodePort — no need to redesign the bridging approach at that point.

## Namespace & Resource Quota

- Namespace: `workloads` (single namespace; phase A doesn't need per-service separation)
- ResourceQuota: `requests.cpu: 1`, `requests.memory: 2Gi`, `limits.cpu: 1`, `limits.memory: 2Gi` (request equals limit, no slack left — phase A's only resident is the smoke-test pod, which needs no elasticity; if 1/2Gi is insufficient when phase C/D loads real services, raise this quota directly — no effect on already-running pods)
- LimitRange: apply conservative defaults to containers that omit `resources.requests/limits` (e.g. `default: 200m/256Mi`, `defaultRequest: 100m/128Mi`), preventing a slip-of-hand pod from consuming the whole quota
- Cilium/Hubble/CoreDNS/local-path-provisioner in kube-system are not subject to this quota — the quota only governs the `workloads` namespace; this is expected behavior, not an omission

## Validation Checklist (phase A pass criteria)

1. `kubectl get nodes` → `Ready`
2. `cilium status --wait` healthy, output confirming `KubeProxyReplacement: True`
3. Hubble relay/UI reachable (`hubble status`, or port-forward the UI service to confirm it opens)
4. `kubectl describe resourcequota -n workloads` shows the quota is in effect
5. The smoke-test pod (`smoke-test.yaml`) runs, and `curl localhost:30080` on the host responds
6. **NetworkPolicy live test**: deploy another pod in the `workloads` namespace, apply a deny-all `NetworkPolicy`, verify traffic between the two pods is blocked (use `kubectl exec` to curl from one pod to the other, expecting timeout/refusal) — this is the "CNI/**NetworkPolicy**" explicitly stated as a phase-A roadmap goal; verifying connectivity alone is insufficient
7. Via the temporary NPM proxy host, curl the test domain from the external network, verifying the full path `Internet → npm → host:30080 → k3s pod`
8. Cleanup: delete the smoke-test Deployment/Service, delete the second pod from the NetworkPolicy test, delete the temporary NPM proxy host, returning the cluster to the "empty" state; keep `manifests/smoke-test.yaml` in the repo so later phases can rerun connectivity validation directly

## Known Limitations / Failure Modes

- `flannel-backend=none` makes k3s fully dependent on Cilium for pod networking — if Cilium fails to install or dies, the node is stuck at `NotReady` (fail-closed, as expected; not an anomaly to handle)
- The kube-system system components (Cilium agent, Hubble relay/UI, CoreDNS, local-path-provisioner) are not subject to the ResourceQuota, so in theory they could consume resources beyond the 1C/2Gi workload budget; this phase relies on the default request/limit from the official Helm charts as the backstop, and does not set a separate kube-system quota
- The host has only 4 CPU cores, shared with existing docker services (llm, dify, etc.); after the resident overhead of k3s + Cilium + Hubble is stacked on, if existing services' performance is observed to degrade, the next step is to re-examine whether Hubble UI is worth keeping on (it can be dropped to CLI/relay only), rather than redesigning the whole CNI selection

## Handoff to Phase B

Phase B (ArgoCD + GitHub Actions CI skeleton) depends on what this phase leaves behind: a reachable empty cluster with CNI/NetworkPolicy/storage/quota mechanisms, and the `vps_oracle/k3s/` repo directory convention — phase B's ArgoCD-related non-secret config is expected to continue living under the same directory.