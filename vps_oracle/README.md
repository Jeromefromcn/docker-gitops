# vps_oracle

Services running on the Oracle Cloud VPS.

## Server information

- Domain: `jerome.cloudns.asia` (DDNS, resolves to this machine)
- Current IP: `161.118.254.107` (the IP changes; go by the DNS result — this just records the last known value)

## Directory structure

This machine runs more than just docker compose; each subdirectory under `vps_oracle/` is its own independent scope:

| Directory | What it manages | Conventions in |
|---|---|---|
| `compose/` | docker compose stacks; each subdirectory is that stack's working directory | root [README.md](../README.md) |
| `k3s/` | the K3s cloud-native experiment platform (Cilium / ArgoCD / Istio Ambient / Kyverno / Trivy / Sealed Secrets + the `lab-environment`, `headlamp`, `pr-lanes` workloads), always via GitOps, never manual `kubectl apply` | [k3s/README.md](k3s/README.md) |
| `inspector/` | host inspection scripts + systemd timer, doing read-only checks across both docker and k3s | [inspector/README.md](inspector/README.md) |
| `host-firewall/` | host iptables rule script (`INPUT` defaults to REJECT, whitelisted one rule at a time) | [host-firewall/README.md](host-firewall/README.md) |
| `tofu/` | OpenTofu brownfield adoption: VCN / subnet / IGW / route table / security list (recursively bringing the upstream OCI network resources under management) | [tofu/README.md](tofu/README.md) |
| `npm-nodeport-relay/` | a TCP relay in the host netns, filling in reachability from the NPM container to the k3s NodePort | [npm-nodeport-relay/README.md](npm-nodeport-relay/README.md) |
| `dotfiles/` | part of this machine's local config (Claude Code global settings, shell/git config, VS Code Server machine-level settings, etc.), symlinked into the repo for management | [dotfiles/README.md](dotfiles/README.md) |

The network conventions below apply only to `compose/`; the k3s-side network (Cilium pod network, NodePort, the NPM-to-NodePort gotcha) is in `k3s/README.md` and the root README.

## Network

A single shared external Docker network is the reverse-proxy entry point:

```bash
docker network create proxy
```

This network doesn't belong to any one service's compose lifecycle — create it manually once, it persists, and `docker compose down` won't remove it.

- **nginx-proxy-manager** ([compose/npm/](compose/npm/)): the only externally-facing 80/443 entry point; joined to the `proxy` network.

- **Default rule: any container with an HTTP(S) service that should be reverse-proxied by NPM joins the `proxy` network**, publishes no port to the host, and NPM uses the container name directly as the Forward Hostname/IP, e.g.:

  ```yaml
  networks:
    - proxy

  networks:
    proxy:
      external: true
  ```

  Benefit: the service exposes no port itself, NPM is the only entry point, minimizing the attack surface; addressing by container name means recreating containers doesn't require config changes. This is the default — without exception for services because they are "new" or "old".

- **Exception: ports the protocol requires clients to reach directly, that aren't HTTP and can't go through an NPM reverse proxy** (e.g. a VPN node's raw handshake port): publish these to the host as needed, independent of whether they join the `proxy` network — they were never reverse-proxy subjects. If the same service also has an HTTP part (e.g. a management panel or subscription endpoint), that part still follows the default rule above via `proxy` + container name.

- **Pure backends that serve nothing externally and don't need reverse-proxying** (databases, internal workers, etc.): don't join the `proxy` network; keep the default isolation to avoid being reachable by other containers on the same network.