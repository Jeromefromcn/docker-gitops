---
paths:
  - "*/compose/**"
---

# Compose conventions

Must be followed when writing or modifying any `<host>/compose/<compose>/docker-compose.yml`. This file is the single source of truth for these conventions; `README.md` is only a pointer.

- Never commit any key/password/token. Sensitive config goes in the `.env` file (already gitignored), referenced in compose via `env_file` or environment variables
- Pin image versions to a specific tag or digest wherever possible, not `latest`
- Keep each change small and single-purpose, for easy review and rollback
- Each compose directory corresponds to one independent docker-compose stack; a stack may contain multiple services, but don't mix files from different stacks into the same directory
- **Timezone**: containers uniformly use `environment: TZ: "Asia/Hong_Kong"` so log timestamps line up with humans.
  - **`TZ` alone doesn't always take effect**: the program must also be able to find `/usr/share/zoneinfo/Asia/Hong_Kong` inside the image; if it can't, it **silently falls back to UTC** without error. A full audit on 2026-08-21 found images with no zone file that actually run in UTC: `portainer/portainer-ce`, `headlamp`, cilium (only ships the single `UTC` zone), `alpine/socat`, `busybox`; images that do ship zone files: `ubuntu/squid`, `nginx:*-alpine`, grafana, the prom series. **Exceptions**: vikunja and homepage also lack zone files in their images, but their runtimes bundle tzdata (Go's `time/tzdata`, Node's ICU), so they still come out as `+0800` — the deciding factor is always the program's actual behavior, not whether the file is present.
  - **When the image ships no tzdata**, mount the single 1.2 KB zone file, not the whole 2.1 MB directory:
    ```yaml
    volumes:
      - /usr/share/zoneinfo/Asia/Hong_Kong:/usr/share/zoneinfo/Asia/Hong_Kong:ro
    ```
    **Don't use `/etc/localtime:/etc/localtime:ro`** (the most common pattern online — it's a wasted mount here): Go only reads `/etc/localtime` when `TZ` is unset; once `TZ` is set to a zone name it only looks under `/usr/share/zoneinfo`. This is how portainer was fixed.
  - Same on the **k3s side**, but check the namespace first: `headlamp` and `pr-lanes` carry `pod-security.kubernetes.io/enforce: baseline`, and the baseline profile **forbids hostPath volumes** — such namespaces instead pack the zone file into a ConfigMap and mount it via `subPath`, see [`vps_oracle/k3s/apps/headlamp/k8s/tzdata-configmap.yaml`](../../vps_oracle/k3s/apps/headlamp/k8s/tzdata-configmap.yaml).
  - **`docker exec <container> date` is not a reliable check**: the busybox `date` in the prom-series images doesn't recognize IANA zone names at all (only the POSIX form `TZ=HKT-8`), so it shows UTC while the Prometheus main process logs are actually `+08:00`; portainer has no shell at all. Judge the real timezone by the **application's own log timestamps**, or compare `docker inspect -f '{{.State.StartedAt}}'` against the first log line.
  - **Deliberately left as-is**: prometheus / node-exporter / blackbox-exporter (their application logs are already `+08:00`; the only thing that would fix busybox `date`, `TZ=HKT-8`, would push the application logs back to UTC — the two consumers demand mutually exclusive formats); cilium (rolling-restarting the whole cluster's CNI DaemonSet for a log timezone is not worth it, and its UTC output already matches kubectl and the other k8s components).
- **Log size limits**: every service must explicitly declare `logging` to keep logs from filling the disk:
  ```yaml
  logging:
    driver: json-file
    options:
      max-size: "10m"
      max-file: "5"
  ```
- **Minimal port exposure**: only publish host ports that genuinely need direct access (e.g. 3x-ui's node ports, npm's 80/443). Admin panels / internal services (3x-ui panel, Prometheus, Grafana, Portainer UI, etc.) are never published to the host — they all go through NPM reverse-proxied to `proxy`-network internal ports; emergency access goes via SSH + the container's internal IP, no extra ports opened.
- **Least privilege**: add `security_opt: [no-new-privileges:true]` to any container that allows it (already enabled for monitoring, portainer). Mounting `/var/run/docker.sock` is a known high-risk exception (e.g. portainer) — call out the reason explicitly in a comment, and don't silently introduce new equivalent mounts.
- **Restart policy**: uniformly `restart: unless-stopped` — auto-starts after a host reboot, but doesn't come back if manually stopped.
- **Network isolation**: cross-stack traffic goes over the external network `proxy` (subnet `172.19.0.0/16`; create it once manually with `docker network create proxy --subnet 172.19.0.0/16 --gateway 172.19.0.1 --ip-range 172.19.1.0/24`). Services that don't need external exposure should not be attached to `proxy`.
  - **`--ip-range` is intentional**: it confines dynamic allocation to `172.19.1.0/24`, so the entire `172.19.0.0/24` range can only be claimed by explicit `ipv4_address:` entries in compose — physically non-overlapping with the dynamic allocation pool. Background: on 2026-08-16 the host rebooted unexpectedly, and 3x-ui's pinned static IP (`172.19.0.2`) was grabbed by a container on the same network that started earlier and took default dynamic allocation, so 3x-ui failed to come up — the root cause was that "pinned static IPs" and the "dynamic pool for others" then shared the same address range; whoever attached to the network first could grab it, tightly coupled to start order and uncontrollable. After splitting the ranges, even if 3x-ui/npm start last, the dynamic allocator will never hand out `.2`/`.3`, so the problem can't structurally recur.
  - Containers currently pinned to static IPs: `3x-ui` (`172.19.0.2`), `npm` (`172.19.0.3`), `prometheus` (`172.19.0.4`, no live consumer since headlamp's relay was removed 2026-09-24 — kept as a stable host-side debug address; it is not reverse-proxied through NPM — `proxy` is also the only egress for `prometheus`/`grafana`, for reasons noted under `networks.default` at the end of `vps_oracle/compose/monitoring/docker-compose.yml`). For future services that need a fixed IP, register them here starting from `172.19.0.5`; don't use `172.19.1.0/24`.
- **Everything in English**: anything shown to end users / visitors (dashboard titles, service-card descriptions, UI copy, etc.) is uniformly in English; repo-internal comments, docs, and commit messages are also uniformly in English — no exceptions.

## After making changes

- The repo directory is the runtime directory — apply directly in the corresponding directory: `cd <host>/compose/<compose> && docker compose up -d`
- But **don't assume the repo definition matches what's live** — for any operation that recreates a container, confirm with the user first.
- One commit per change, scoped to a single compose stack.