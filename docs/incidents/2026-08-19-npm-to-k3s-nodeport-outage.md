# Incident record: Cilium socket-LB narrowed to host namespace, NPM reverse proxy to k3s NodePort all down

Date: 2026-08-19
Status: Resolved

## Background

In [phase F+G](../misc/2026-08-19-k3s-phase-fg-pr-lanes-summary.md) (Istio Ambient mesh + PR preview lanes) completed earlier the same day, [b79455f](../../vps_oracle/k3s/cilium/values.yaml) set Cilium's `socketLB.hostNamespaceOnly` to `true` — this is the correct fix for the waypoint-not-receiving-traffic problem, verified end-to-end in the phase F+G document. Afterwards the user reported "all services deployed in the k3s environment are inaccessible".

## Investigation

`kubectl get pods -A`, the ArgoCD Application list, and node status were all Healthy/Synced, and in the `pr-lanes` namespace `hello-frontend`/`hello-backend` were 1/1 Ready. `curl 127.0.0.1:<NodePort>` and `curl 10.0.0.95:<NodePort>` from the host itself both returned 200, and the waypoint's in-cluster routing was also normal — the cluster interior was completely healthy, and it briefly looked unrelated to today's development work.

The turning point was realizing that Cilium's eBPF NodePort dataplane attaches to the physical NIC (`enp0s6`), and `127.0.0.1` goes over loopback and never traverses that path, so it can't prove external reachability; at the same time I recalled that the NPM container is on a `docker compose` bridge network (`proxy`, 172.19.0.0/16), not host network mode. Switching to `docker exec npm curl 10.0.0.95:<NodePort>` from inside the NPM container immediately failed (`Couldn't connect to server`, 0ms, instantly refused). The same target address started from the host itself works perfectly — this "host namespace works, container netns doesn't" gap matches precisely with today's only relevant change (`socketLB.hostNamespaceOnly`).

Checked `vps_oracle/host-firewall/host-firewall.sh` (the single source of truth for host firewall, git-controlled); the `INPUT` chain never opened a port range for the k3s NodePort range (30000-32767) — the reason it worked before was entirely Cilium socket-LB's previous "Full" coverage silently carrying it: any process (not just k8s pods, but all docker-compose containers) initiating a connection to a Service/NodePort address would have it rewritten at the `connect()` stage by Cilium directly to the backend pod IP, completely bypassing the `iptables INPUT` chain. After changing to `hostNamespaceOnly: true`, this bypass only remains for "the host's own network namespace", so docker bridge containers like NPM are excluded and fall straight into the `INPUT` chain's default `REJECT --reject-with icmp-host-prohibited`.

Directly read NPM's actual production config (`docker exec npm cat /data/nginx/proxy_host/30.conf`, headlamp's reverse proxy) confirming `$server = 10.0.0.95`, `$port = 30098`, proving this is the real production path, not a guess — grafana.lab, argocd, jaeger, consul and others all use the same pattern, which is why it presented as "all k3s services inaccessible", not just today's pr-lanes/hello.

## Root cause (two layers, both necessary)

`socketLB.hostNamespaceOnly: true` itself is correct and necessary (the PR lane's waypoint L7 routing needs it), but it has a side effect that was never recorded: the previous NPM → k3s NodePort path worked entirely as an accidental side effect of socket-LB's "Full" coverage — under that coverage, Cilium rewrites the `connect()` call at the socket layer for *any* process (regardless of netns, as long as it's under the same machine's cgroup hierarchy), swapping the destination address directly for the backend pod IP and completing the forward before the packet is even assembled, entirely bypassing the normal routing/iptables path. After narrowing to host-namespace-only, NPM-style docker bridge containers' `connect()` is no longer rewritten, and the connection degrades to a normal TCP packet, which has no valid delivery path:

1. **The host firewall never allowed this path.** `host-firewall.sh`'s `INPUT` chain never opened the k3s NodePort range (30000-32767).
2. **Even if the firewall allowed it, nothing is listening.** A control experiment using a plainly self-hosted `socat` listening port, completely unrelated to NodePort: connecting from the NPM container the same way gets the same "immediate refusal" — proving the problem isn't specific to Cilium's NodePort logic, but that this kind of packet ("same machine, non-host netns source, destination a local address" — hairpin) is neither caught by Cilium's NodePort eBPF attached to `enp0s6` (the packet arrives via local routing and never actually enters through the NIC), nor helped by socket-LB anymore — both of Cilium's NodePort implementation paths (host-netns socket rewrite, external-packet NIC eBPF) fail to cover this scenario.

## Fix (two parts)

**1. `vps_oracle/host-firewall/host-firewall.sh`** adds an explicit `INPUT` allow rule, opening the first-layer root cause's hole:
```
ipt INPUT -s 172.19.0.0/16 -p tcp -m tcp --dport 30000:32767 -j ACCEPT
```
Source restricted to the docker `proxy` network segment (where NPM lives), destination ports restricted to k3s's NodePort range, not open to the outside; consistent in style with the existing `-s 10.42.0.0/16` (pod CIDR → specific port) rule.

**2. New [`vps_oracle/npm-nodeport-relay/`](../../vps_oracle/npm-nodeport-relay/)**, filling the second-layer root cause's missing "something to listen": a systemd template service that starts one `socat` instance per NodePort that NPM depends on, listening in the host netns and forwarding to `127.0.0.1:<same port>`. Because this forward is a `connect()` initiated from the host netns, it is still correctly rewritten by socket-LB to the backend pod — replacing "hoping Cilium forwards it" with "there really is a process listening in the host netns". NPM's config needs no change at all; hitting `10.0.0.95:<NodePort>` as before now lands on this relay instead of the blackhole.

Both parts are necessary: with only the firewall rule, the `socat` control experiment showed that switching to the NodePort's own port still can't connect (verified earlier); with only the relay and no firewall rule, the connection is blocked first by the `INPUT` chain's default `REJECT`.

## Verification

After both parts went live, re-tested all the NodePorts NPM actually depends on from inside the NPM container:
```bash
docker exec npm curl -sS -m5 -o /dev/null -w "%{http_code}\n" http://10.0.0.95:30090/   # argocd
docker exec npm curl -sS -m5 -o /dev/null -w "%{http_code}\n" http://10.0.0.95:30092/   # consul
docker exec npm curl -sS -m5 -o /dev/null -w "%{http_code}\n" http://10.0.0.95:30094/   # grafana
docker exec npm curl -sS -m5 -o /dev/null -w "%{http_code}\n" http://10.0.0.95:30095/   # jaeger
docker exec npm curl -sS -m5 -o /dev/null -w "%{http_code}\n" http://10.0.0.95:30097/   # api-gateway
docker exec npm curl -sS -m5 -o /dev/null -w "%{http_code}\n" http://10.0.0.95:30098/   # headlamp
```
All returned 200 (consul returned 301, which is its own UI's normal redirect, not an error).

## Lessons

When changing cluster-level network settings like Cilium socket-LB coverage that "look like they only affect k8s internals", be aware that they may also be carrying paths for things outside the cluster (docker-compose containers on the same machine) — especially with this machine's architecture where k3s and docker compose are co-located and share the same host network stack. Next time socket-LB / kube-proxy related settings are adjusted, the reachability of non-k8s consumers like NPM should be checked as well, not just k8s's own end-to-end verification.