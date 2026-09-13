# Investigation record: k3s pod can't reach docker compose containers, packets diverted to the lo blackhole by fwmark

Date: 2026-08-24
Status: Root cause confirmed, deliberately not fixed (see "Why not fix" below)

## Background

While designing [K3s Phase K (observability onboarding)](../superpowers/specs/2026-08-24-k3s-phase-k-observability-design.md), the original plan was to have `pr-lanes`'s Envoy/waypoint push logs and traces directly into the newly installed Loki and Jaeger in the docker compose network. Before starting, the path was verified first and found completely non-functional — this is not a service outage, but a connectivity verification that dead-ended during the design phase, recorded to avoid spending time re-investigating it next time.

## Investigation

From any pod in `pr-lanes` (`kubectl exec` into `hello-backend`), connecting to compose's Prometheus fixed IP:

```bash
kubectl -n pr-lanes exec hello-backend-xxx -- curl -m4 http://172.19.0.4:9090/-/healthy
# curl: (28) Operation timed out after 4002 milliseconds with 0 bytes received
```

First narrowing the scope:

- **host → compose Prometheus**: `curl http://172.19.0.4:9090/-/healthy` → `200`, the service itself is healthy
- **pod → external internet**: `curl http://1.1.1.1` → `301`, the pod's general egress is normal
- **A temporary pod entirely outside the ambient mesh** (`default` namespace, no ztunnel interception) equally can't reach `172.19.0.4:9090` → rules out ztunnel/ambient mesh as the culprit
- There's no `NetworkPolicy`/`CiliumNetworkPolicy`/`CiliumClusterwideNetworkPolicy` in the cluster (except the `argocd` namespace, unrelated to this path) → rules out an explicit refusal at the K8s/Cilium policy level

`tcpdump` packet capture to pinpoint: capturing simultaneously on the destination docker bridge (`br-99f461e27ed6`) and the local physical NIC (`enp0s6`), filter on the destination `172.19.0.4:9090`, resending a request — **both sides captured 0 packets**. The packet wasn't refused; it was never delivered to any network interface at all.

`sudo cilium-dbg monitor --type drop` watching throughout, resending the request — no drop event generated for this IPv4 traffic (only background IPv6 neighbor-discovery noise). This means Cilium's eBPF policy layer did not actively drop it.

Using `sudo cilium-dbg monitor -v` (no drop filter, full trace) and resending, caught the key line:

```
-> stack flow 0x4bbf5bf4 , identity 35328->world state new ifindex 0 orig-ip 0.0.0.0: 10.42.0.199:35494 -> 172.19.0.4:9090 tcp SYN
```

Cilium correctly identified the destination as `world` (outside the cluster) and handed the packet to "stack" (the normal kernel network stack) for processing — **not** dropped at the Cilium layer, only vanishing after that.

Turning to the kernel's policy routing:

```bash
$ ip rule show
9:      from all fwmark 0x200/0xf00 lookup 2004
100:    from all lookup local
32766:  from all lookup main
32767:  from all lookup default

$ ip route show table 2004
local default dev lo proto kernel scope host
```

Root cause found: an extremely high-priority rule (`9`, far earlier than the `main` table's `32766`) routes any packet carrying `fwmark 0x200/0xf00` to table 2004, which has only one route — `dev lo`. Any packet marked this way, regardless of its original destination, is diverted to loopback with no NAT/REDIRECT rewriting the destination, and vanishes on `lo` like this — never delivered to any physical/bridge interface, and never generating a Cilium-policy-layer drop event (because this is a kernel routing decision, not Cilium eBPF actively intercepting).

## Root cause

The `fwmark 0x200` mark is almost certainly part of the existing traffic-redirection mechanism between Cilium and istio-cni — marking traffic suspected of being destined for the mesh's local proxy (ztunnel/waypoint) and diverting it to local processing. This machine's `vps_oracle/k3s/cilium/values.yaml` has already recorded a precedent of the same kind ("Cilium and istio-cni redirection mechanisms racing", phase F+G Task 14, the problem `socketLB.hostNamespaceOnly` fixed: Cilium's eBPF dataplane resolving it to the backend Pod IP before istio-cni's iptables REDIRECT rule had a chance to preserve the original ClusterIP). This is another instance of the same kind of problem, just with a different trigger condition — the destination is a private address outside the cluster (`172.19.0.0/16`, docker's `proxy` network) rather than a ClusterIP.

Whether this fwmark is written by Cilium itself, or by the iptables rules istio-cni installs into each pod's netns, has not been definitively traced — non-mesh-member pods are equally affected, meaning this rule's scope is **not** written per-pod by istio-cni (in which case non-mesh pods wouldn't have the rule), and looks more like a Cilium node-level uniformly-applied mechanism, but this is only a conjecture, not further confirmed.

## Why not fix

This redirection mechanism is currently one of the core mechanisms that make ztunnel/waypoint traffic work normally. Recklessly adjusting it (e.g. trying to exclude `172.19.0.0/16` from this rule) risks taking down the currently-working mesh traffic redirection, and requires first fully understanding which component writes this rule before it's safe to touch — this is a deep investigation worth a dedicated project, not something to side-task while designing the observability config.

Phase K's design completely routes around this limitation: instead of letting pods actively connect out to the docker compose network, all three telemetry types (metrics/logs/traces) go the reverse direction — compose's Prometheus/Grafana actively reach k3s's NodePort (see the [Phase K design doc](../superpowers/specs/2026-08-24-k3s-phase-k-observability-design.md)), a direction unaffected by this problem (already verified in production, see the [2026-08-19 NPM NodePort incident record](2026-08-19-npm-to-k3s-nodeport-outage.md)).

## Lessons

- **This limitation is not specific to `pr-lanes` or this investigation's target** — any k3s pod trying to reach any container in the docker compose network will hit the same wall. Any future design that wants k3s pods to actively connect out to compose containers should first re-run the diagnostic steps here (`tcpdump` on both ends + `cilium-dbg monitor` + `ip rule`/`ip route show table <n>`), not assume "same machine, has a routing table entry" means it can reach it
- **`cilium-dbg monitor --type drop` not catching a drop event doesn't mean the packet wasn't intercepted** — this interception happens at the kernel's policy-routing layer (`ip rule`/custom routing tables), not Cilium's eBPF policy enforcement; the two are completely different mechanisms, and looking only at Cilium's own drop monitoring would misjudge it as "Cilium didn't intercept"
- **`ip rule show` + checking each custom routing table one by one** should be a standard step for this kind of "packet vanished out of thin air with no refusal signal" scenario, and finds the problem sooner than just looking at `iptables`/`cilium-dbg monitor` — this time it was only thought of quite late in the investigation