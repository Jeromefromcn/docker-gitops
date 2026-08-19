# npm-nodeport-relay — host-netns relay so NPM can reach k3s NodePorts

## Why this exists

Incident 2026-08-19 (full writeup: [docs/incidents/2026-08-19-npm-to-k3s-nodeport-outage.md](../../docs/incidents/2026-08-19-npm-to-k3s-nodeport-outage.md)):
NPM's proxy_host confs target `10.0.0.95:<NodePort>` directly (e.g.
`headlamp.jerome.cloudns.asia` → `10.0.0.95:30098`). This only ever worked
because Cilium's socket-LB, before phase F+G, redirected *any* process's
`connect()` call on this node — Docker containers included — straight to the
backend Pod IP before a packet was ever built, invisibly bypassing normal
routing/firewall. Phase F+G scoped that redirect to the host network
namespace only (`socketLB.hostNamespaceOnly: true`, required for istio-cni's
ambient mesh routing — do not revert). Docker containers (NPM's own `proxy`
bridge network) are a different netns, so they lost the redirect.

Without socket-LB, a container-originated packet to `10.0.0.95:<NodePort>`
gets delivered locally (kernel routing: `10.0.0.95` is a local address on
`enp0s6`) but there is no real listening socket there for Cilium's virtual
NodePort service, and it never transits `enp0s6`'s ingress hook either (it's
routed locally, not arriving off the wire) — so Cilium's other NodePort path
(eBPF on the physical device, for genuinely external traffic) never sees it
either. Confirmed empirically: a plain `socat` test listener bound to a
non-NodePort port on the host had the exact same failure, and only started
working once (a) the host firewall explicitly allowed the docker `proxy`
network to reach it, and (b) something was actually listening in the host's
own network namespace.

This relay is that "something." It runs *in the host netns*, so its own
outbound leg (`TCP:127.0.0.1:<port>`) is a normal host-netns `connect()` —
exactly the case socket-LB still covers — and gets redirected to the correct
backend Pod. NPM's confs need no changes: it keeps hitting
`10.0.0.95:<NodePort>` as before, now landing on this relay instead of a
black hole.

This also requires the host firewall to admit the docker `proxy` network to
the k3s NodePort range — see the `2026-08-19` rule in
[`../host-firewall/host-firewall.sh`](../host-firewall/host-firewall.sh).
Both parts are needed; neither alone is sufficient.

## Port inventory

One systemd instance per NodePort that an NPM proxy_host currently targets
(`docker exec npm grep -r 'set \$port' /data/nginx/proxy_host/*.conf` to
regenerate this list):

| Port | Service | NPM proxy_host |
|---|---|---|
| 30090 | argocd-server | argocd.jerome.cloudns.asia |
| 30092 | consul (lab-environment) | consul.lab.jerome.cloudns.asia |
| 30094 | grafana (lab-environment) | grafana.lab.jerome.cloudns.asia |
| 30095 | jaeger (lab-environment) | jaeger.lab.jerome.cloudns.asia |
| 30097 | api-gateway (lab-environment) | api.lab.jerome.cloudns.asia |
| 30098 | headlamp | headlamp.jerome.cloudns.asia |

**When adding a new NPM proxy_host that targets a k3s NodePort**, enable a
new instance for that port (see Install below) — otherwise it'll hit the
same black hole this incident was about.

## Install

```bash
sudo cp nodeport-relay@.service /etc/systemd/system/
sudo systemctl daemon-reload
for p in 30090 30092 30094 30095 30097 30098; do
  sudo systemctl enable --now nodeport-relay@$p.service
done
```

## Verify

```bash
systemctl status 'nodeport-relay@*.service'
docker exec npm curl -sS -o /dev/null -w '%{http_code}\n' http://10.0.0.95:30098/   # expect 200
```
