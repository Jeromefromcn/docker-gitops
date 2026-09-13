# Investigation record: compose prometheus/grafana can't reach k3s NodePort, default gateway resolves to the wrong docker network

Date: 2026-08-24
Status: Fixed and applied (2026-08-24). **The fix originally written into the [Phase K design doc](../superpowers/specs/2026-08-24-k3s-phase-k-observability-design.md) (`networks.<name>.priority`) proved ineffective on this machine in testing**; the fix actually adopted is changing the compose project's own `default` network to `internal: true`, detailed under "Fix" below

## Background

While designing [K3s Phase K (observability onboarding)](../superpowers/specs/2026-08-24-k3s-phase-k-observability-design.md), after confirming that k3s pods cannot actively connect out to the docker compose network (see [the other investigation record from the same day](2026-08-24-k3s-pod-to-docker-bridge-blackhole.md)), the design switched to the reverse direction: have compose's existing Prometheus/Grafana actively reach k3s's NodePort to pull metrics/logs/traces. In theory this direction is the only path already proven in production on this machine (NPM reverse-proxying headlamp/lab-environment grafana/argocd goes exactly this way, see the [2026-08-19 NPM NodePort incident record](2026-08-19-npm-to-k3s-nodeport-outage.md)), but during verification it turned out not to work.

## Investigation

Tested from inside compose's `prometheus` container against a k3s NodePort already confirmed alive and working (headlamp, `30098`):

```bash
$ docker exec prometheus wget -T4 -qO- http://10.0.0.95:30098
wget: can't connect to remote host (10.0.0.95): No route to host
```

`No route to host` in Linux networking usually corresponds to receiving an explicit refusal (e.g. ICMP host-prohibited), not simply a vanished packet — first suspect was `host-firewall.sh`'s `INPUT` chain blocking it. But `host-firewall.sh` had already added an explicit allow rule for "docker `proxy` network → k3s NodePort range" back on 2026-08-19:

```
ipt INPUT -s 172.19.0.0/16 -p tcp -m tcp --dport 30000:32767 -j ACCEPT
```

So in theory it should work. Checked which networks the `prometheus` container actually has attached:

```bash
$ docker inspect prometheus --format '{{json .NetworkSettings.Networks}}'
{
  "monitoring_default": {"Gateway": "172.20.0.1", "IPAddress": "172.20.0.2", "GwPriority": 0, ...},
  "proxy":              {"Gateway": "172.19.0.1", "IPAddress": "172.19.0.4", "GwPriority": 0, ...}
}
```

The `prometheus` container is attached to **two** networks: the project's own `monitoring_default` (`172.20.0.0/16`) and `proxy` (`172.19.0.0/16`, used for a fixed IP — the exact segment the `host-firewall.sh` allow rule is bound to). Both networks have `GwPriority` of `0` (tie, no explicit priority specified), and in practice Docker resolves `monitoring_default` as the actual default gateway:

```bash
$ docker inspect prometheus --format '{{.NetworkSettings.Networks.monitoring_default.Gateway}}'
172.20.0.1
```

That is, when the `prometheus` container initiates an outbound connection (including this connection to `10.0.0.95:30098`), it goes out via `monitoring_default` (`172.20.0.0/16`), not `proxy` (`172.19.0.0/16`) — the packet leaves via the wrong network, its source address falls outside the `172.19.0.0/16` range of the `host-firewall.sh` rule, and is blocked by the chain's terminal default `REJECT --reject-with icmp-host-prohibited`, which presents to `wget` inside the container as `No route to host`.

Control group: check the network settings of the NPM container (existing production path, confirmed working):

```bash
$ grep -A5 "networks:" vps_oracle/compose/npm/docker-compose.yml
    networks:
      proxy:
        ipv4_address: 172.19.0.3
```

NPM is attached to **only the `proxy` network**, with no multi-network ambiguity, so its default gateway is naturally `172.19.0.1` — that's the difference between NPM (which can reach the k3s NodePort) and `prometheus`/`grafana` (both dual-attached `default` + `proxy` like `prometheus`) that currently can't.

One more control experiment to converge the variable down to "source IP" alone: the same `prometheus` container, only changing the destination IP, hitting the two bridge addresses on the host respectively (the NodePort service listens on `0.0.0.0` anyway, so both addresses are valid destinations), but because both are on-link (direct route, no default gateway), the packet's source IP lands in each respective segment:

```bash
# via proxy bridge (on-link, src=172.19.0.4, inside the firewall allow segment)
$ docker exec prometheus wget -T4 -qO- http://172.19.0.1:30098
<!DOCTYPE html>          # works

# via monitoring_default bridge (on-link, src=172.20.0.5, outside the allow segment)
$ docker exec prometheus wget -T4 -qO- http://172.20.0.1:30098
wget: can't connect to remote host (172.20.0.1): No route to host
```

Same container, same NodePort, only the source IP differs, one works and one doesn't — proving the routing/DNAT/Cilium side is all fine, and the only variable is which network the packet leaves from (i.e. which default gateway was chosen).

## Root cause

In `vps_oracle/compose/monitoring/docker-compose.yml`, the `prometheus` and `grafana` services are both attached to their project's own `default` network and the shared `proxy` network (`proxy` was originally only for getting a fixed IP so things like NPM could reverse-proxy in, not designed for them to actively connect out). When both networks have the same `GwPriority` (both at the default `0`), Docker picks the `default` network (`monitoring_default`) as the actual default gateway rather than `proxy` — this isn't random, but there's no explicit configuration guaranteeing `proxy` gets chosen either; it's purely Docker's internal network ordering rule. Nobody noticed in the past because these two containers had never actively connected out to a k3s NodePort (they'd always been the connection targets, or only interconnected with other compose containers inside the `default` network); this was the first attempt, and thus the first exposure of this ambiguity.

## Fix

### Dead end: `networks.<name>.priority` (the fix originally written into the Phase K design)

The Compose Spec has a `networks.<name>.priority` field (higher number = higher priority), corresponding to the engine's `GwPriority`, which looks purpose-built for this scenario. **Tested on this machine, completely ineffective**:

| Tested version (`docker-compose-plugin` package version / CLI reported) | `docker compose config` | `GwPriority` after `up -d` | NodePort test |
|---|---|---|---|
| `5.1.1-1~ubuntu.24.04~noble` / `v5.1.4` (originally installed) | parses and validates fine | still `0` | still `No route to host` |
| `5.1.4-1~ubuntu.24.04~noble` / `v5.1.4` (pure packaging version change) | same | still `0` | same |
| `5.5.0-1~ubuntu.24.04~noble` / `v5.5.0` (latest apt has) | same | still `0` (`--force-recreate` forced rebuild also same) | same |

Also confirmed **the engine-side primitive itself is fine** — tested with a throwaway container:

```bash
$ docker network connect --gw-priority 1 <net> <throwaway>
$ docker inspect <throwaway> --format '{{...GwPriority}}'   # → 1, correctly effective
```

Conclusion: not a version lag, not a YAML mistake — **compose doesn't forward this field to the engine's `NetworkConnect`/`ContainerCreate`**. Upgrading compose on this machine can't route around it, so stop trying. (`docker-compose-plugin` is now pinned at `5.5.0`, upgraded during this investigation and not rolled back.)

### Adopted: change the compose project's own `default` network to `internal: true`

Since "raising `proxy`'s priority" is impossible, flip it around and "take `default` out of the election". **An internal network never gets a gateway assigned, so it doesn't participate in default-route election** — `proxy` thus automatically becomes the sole egress for `prometheus`/`grafana`, the source IP falls back into `172.19.0.0/16`, the existing `host-firewall.sh` rule takes effect directly, and the firewall needs not a single change.

Throwaway verification (done on a throwaway project first before touching the real one):

```bash
$ docker network create --internal --subnet 172.31.99.0/24 gwtest-internal
$ docker run -d --name gwtest-c --network gwtest-internal busybox:1.36 sleep 600
$ docker network connect proxy gwtest-c
$ docker exec gwtest-c ip route
default via 172.19.0.1 dev eth1          # ← proxy gets the default route
172.19.0.0/16 dev eth1 scope link  src 172.19.1.8
172.31.99.0/24 dev eth0 scope link  src 172.31.99.2   # ← internal network, not even a gateway
$ docker exec gwtest-c wget -T4 -qO- http://10.0.0.95:30098
<!DOCTYPE html>                          # works
```

The side effect is that `monitoring_default` itself no longer provides a public-internet egress, so containers attached only to that network lose public-internet access. Checked all four containers one by one: `prometheus`/`grafana` have `proxy` as egress and are unaffected (Grafana's Telegram alerts use this path), `node-exporter` doesn't need outbound access anyway (in fact it shrinks the attack surface), and **only `blackbox-exporter` genuinely needs public-internet access** (it must probe the batch of `https://*.jerome.cloudns.asia` in `prometheus.yml`). So it alone gets a dedicated `egress` bridge belonging only to this project — deliberately not the shared `proxy`: that's the external reverse-proxy plane, and dropping in an exporter that "can be directed by Prometheus to hit any URL" would just be gifting an SSRF pivot.

Final shape (`vps_oracle/compose/monitoring/docker-compose.yml`, the full why-comments are in the file):

```yaml
services:
  prometheus:        # networks block unchanged: default + proxy(172.19.0.4)
  grafana:           # networks block unchanged: default + proxy
  node-exporter:     # unchanged: only on default (now effectively no egress)
  blackbox-exporter:
    networks: [default, egress]      # the only service changed

networks:
  default:
    internal: true                   # ← the fix itself
  egress:                            # public-egress only for blackbox-exporter
  proxy:
    external: true
```

### Verification

```bash
$ docker exec prometheus wget -T5 -qO- http://10.0.0.95:30098 | head -2
<!DOCTYPE html>
<html lang="en">
$ docker exec grafana wget -T5 -qO- http://10.0.0.95:30098 | head -2
<!DOCTYPE html>
<html lang="en">
$ docker exec prometheus ip route
default via 172.19.0.1 dev eth1      # ← switched from 172.20.0.1 to the proxy gateway
```

Regression checks all passed: Prometheus's 18 targets all `up` (including all blackbox public-internet probes), NPM reverse-proxying Grafana returns 200, the k3s hostNetwork socat relay hitting `172.19.0.4:9090` still returns `Prometheus Server is Healthy.` (the `prometheus` fixed IP held), and Grafana's public-egress (Telegram alert path) is normal.

### Options evaluated but not chosen

| Option | Why not chosen |
|---|---|
| Add a `-s 172.20.0.0/16 --dport 30000:32767 ACCEPT` rule to `host-firewall.sh` | Works, and zero container rebuilds. But `172.20.0.0/16` is dynamically allocated by docker from an address pool; once the network is rebuilt the range might change, and the rule would silently fail — exactly the trap described in the [2026-08-16 ghost-rule incident](../../vps_oracle/host-firewall/README.md) (compose network rebuild reused `172.18.0.0/16`, applying the stale rule to the new network). Avoiding that requires pinning the subnet in compose, turning it into "change two files + one cross-file implicit coupling", more complex than the current fix; and it works around the root cause (packets still leave via the wrong network), so the next time these two containers need to reach something else on the host it'll hit the same wall again |
| Retroactively `docker network connect --gw-priority 1 proxy <container>` (script + systemd unit, mirroring the `host-firewall.sh` pattern) | Effective at the engine layer, but this setting is bound to the **container instance**: anyone running `docker compose up -d` once rebuilds the container and it silently reverts, requiring a `docker events`-style watcher to be reliable. One more unit, one more silently-failing failure mode |
| Attach `prometheus`/`grafana` only to `proxy`, and pull `node-exporter`/`blackbox-exporter` into `proxy` too | Stuffs two unauthenticated exporters (one of them an SSRF pivot) into the shared external reverse-proxy plane, visibly enlarging the attack surface, and the largest change |
| `cap_add: NET_ADMIN` + add a `10.0.0.95/32 via 172.19.0.1` static route inside the containers | Grants `NET_ADMIN` to two containers for one route, plus a helper container to run `ip route add` at startup. New privilege + new component, for an effect achievable in one `internal` line |
| Use `172.19.0.1:<NodePort>` as the target address instead of `10.0.0.95:<NodePort>` | **Works without changing any config** (see the control experiment in "Investigation" above): `172.19.0.1` is on-link for the container, leaving via the `proxy` interface with a naturally compliant source IP. But it depends on the "NodePort bound on `0.0.0.0`" precondition, true today but possibly narrowed in the future by Cilium `nodePort.addresses`, and using a docker bridge address to refer to "the k3s node" is hard to read. Kept here as a fallback |

## Lessons

- **When a compose container attaches to multiple docker networks, never assume "attached to a network" equals "outbound connections will go via that network"** — the actual default gateway depends on `GwPriority` (or internal ordering when unset), and must be explicitly verified with `docker inspect --format '{{.NetworkSettings.Networks.<net>.Gateway}}'`, not by just reading what's listed in the `networks:` block
- **`host-firewall.sh`'s source-segment restriction (`-s 172.19.0.0/16`) carries an implicit precondition**: that the caller's packets actually leave from that segment. This precondition holds naturally for single-network containers (like NPM) but not for multi-network containers; any future compose service wanting to use this existing "docker proxy net → k3s NodePort" path must first confirm it hasn't hit the same trap, not just copy NPM's firewall-rule logic and assume it works
- **`No route to host` in a container context is commonly caused by an explicit firewall REJECT on the host, but here the root cause is actually one step earlier — the container chose the wrong egress network**, and the firewall rule itself was entirely correct; when debugging this kind of error, checking which network the packet actually leaves from first locates the problem faster than directly suspecting a wrongly-written firewall rule
- **A field present in the Compose Spec and validated by `docker compose config` doesn't mean compose actually forwards it to the engine**. `networks.<name>.priority` is exactly that: all three package versions (5.1.1 / 5.1.4 / 5.5.0) silently ate the field, `GwPriority` always `0`. The only trustworthy way to tell whether a compose field actually took effect is **`docker inspect` the engine-side actual state after applying**, not the `docker compose config` output, nor the spec documentation
- **To control which network a multi-network container egresses through, `internal: true` is more reliable than `priority`**: an internal network can't even get a gateway, so it's naturally excluded from default-route election — this is docker's established behavior rather than a priority comparison. Conversely, "marking the network that shouldn't be the egress as internal" is usually closer to the intent than "raising the priority of the network that should be the egress", and by the way it also shrinks the attack surface of containers on that network that don't need egress (here, `node-exporter`)
- **Before removing an entire network's egress capability, ask each container one by one "does it need public-internet access"**. This time, of four containers only `blackbox-exporter` needs it; missing it would turn all public-internet probes red, and it'd only show up a scrape cycle later. And when giving it an egress, don't take the easy route of dropping it into the shared `proxy` — an exporter that can be directed to hit any URL placed on the reverse-proxy plane is an SSRF pivot; better to open a dedicated bridge just for it