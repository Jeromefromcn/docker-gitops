# K3s Phase C — Migration Template + First Batch Design

Date: 2026-08-09

Corresponds to phase C of the [K3s Cloud-Native Lab Platform Roadmap](2026-08-05-k3s-cloud-native-platform-roadmap.md): pick 1~2 low-risk services to work out the compose→k8s template, verify zero change in domain/port. Deliverable: a replicable migration SOP.

Prerequisite: [Phase B GitOps Bootstrap Design](2026-08-07-k3s-phase-b-gitops-design.md) is complete and validated. Current cluster state: ArgoCD app-of-apps works normally (`root` + three child Applications `argocd` / `phase-a-foundation` / `placeholder-hello`, all `Synced`/`Healthy`), all with `prune`/`selfHeal` on; the NPM→NodePort bridging pattern has been validated twice (phase A's smoke-test, phase B's ArgoCD UI).

## Scope

**What this phase does:**
- Migrate **homepage** (`ghcr.io/gethomepage/homepage:v1.13.2`) — establish the migration template for "config-type stateless services"
- Migrate **trilium** (`triliumnext/trilium:v0.104.1`) — establish the migration template for "services with real data", including PVC and data migration steps
- Bring both into app-of-apps (one Application each under `argocd/apps/`), deployed into the `workloads` namespace
- Repoint NPM's two existing proxy hosts at the k8s NodePorts, domain unchanged, users feel nothing
- Write the whole procedure into a replicable SOP for phase D to apply per service

**What this phase does not do (left to later phases):**
- CI pipeline — homepage/trilium are both third-party images used directly; this repo has no Dockerfile to build, so phase B's build→Trivy→Cosign has no build step to attach to. Following phase A/B's existing approach for Cilium/ArgoCD official images: pin the tag in the manifest and let ArgoCD deploy
- Deleting old compose containers — after the traffic-cut validation passes, only **stop, don't delete**, keeping them as a rollback point; the final keep/retire is phase H's decision (roadmap migration principle 3)
- trilium data backup mechanism — see "Known limitations"; this is a pre-existing gap from before migration, not in this phase's scope
- Other services (vikunja+pg, dify, llm, 3x-ui) — phase D
- Ingress / cert-manager replacing NPM — phase H

## Current-State Constraints

- **Resources**: live `free -h` shows 13Gi available. Actual usage of the two services (`docker stats`): homepage 110MiB, trilium 246MiB, CPU both nearly idle
- **`workloads` quota**: current hard cap `requests.cpu: 1` / `requests.memory: 2Gi` / `limits.cpu: 1` / `limits.memory: 2Gi`, already using `50m`/`64Mi` requests, `100m`/`128Mi` limits (only `placeholder-hello`)
- **StorageClass**: `local-path` (`rancher.io/local-path`), `reclaimPolicy: Delete`, **`volumeBindingMode: WaitForFirstConsumer`** — this binding mode directly determines the step order of the data migration, see "trilium data migration" below
- **trilium's existing data**: `/etc/trilium/data`, 12MB, owner `1000:1000`
- **trilium's runtime identity**: the container starts entrypoint as root, then `su -c node ./main.cjs node` drops to uid 1000 itself (verified with `docker top`). **On k8s we must not set `runAsUser`**, otherwise the entrypoint's `su` fails — keep behavior exactly consistent with compose
- **NodePort usage**: currently only `30090` (ArgoCD)

## Architecture

```
Internet ──▶ NPM (host 80/443, the only entry point, unchanged this phase)
              │
              │ homepage.jerome.cloudns.asia ─▶ 10.0.0.95:30081 ┐
              │ trilium.jerome.cloudns.asia  ─▶ 10.0.0.95:30082 ┤
              ▼                                                  │
        ┌──────────────────────────────────────────────────────┐ │
        │ k3s ── workloads namespace                   ◀───────┘ │
        │                                                        │
        │  homepage   Deployment + NodePort Service              │
        │    └─ ConfigMap (config/*.yaml) ─▶ initContainer copies │
        │         ─▶ emptyDir (writable) ─▶ main container /app/config │
        │                                                        │
        │  trilium    Deployment + NodePort Service               │
        │    └─ PVC (local-path, 5Gi) ─▶ /home/node/trilium-data  │
        └──────────────────────────────────────────────────────┘
              ▲
              │ ArgoCD root Application
              │   ├─ argocd / phase-a-foundation / placeholder-hello (existing)
              │   ├─ homepage           ← added this phase
              │   └─ trilium            ← added this phase
```

## Components & Configuration

| Item | Decision | Rationale |
|---|---|---|
| Image | Reuse the current compose tags: `ghcr.io/gethomepage/homepage:v1.13.2`, `triliumnext/trilium:v0.104.1` | The migration phase only changes the execution platform, not the version — so problems can be clearly attributed to the migration itself, not version drift |
| CI | Not built | See "what this phase does not do": third-party images, no build step to attach to |
| homepage config carrier | ConfigMap + initContainer copying into emptyDir | homepage writes into its config directory (its own `logs/homepage.log`, plus at startup it fills in defaults like `kubernetes.yaml`/`proxmox.yaml` — the existing `config/logs/homepage.log` has real records). A ConfigMap volume is read-only, so mounting it directly would make those writes fail. The initContainer `cp`s the ConfigMap contents into emptyDir and the main container mounts emptyDir — config stays versioned, writes no longer break |
| homepage container-status widgets | Removed | Implemented via a read-only mount of `/var/run/docker.sock`, which has no equivalent in k8s. Remove the `docker.yaml` provider definition and the `container`/`server` fields on each card in `services.yaml`; the three global widgets at the top — `search`/`resources`/`datetime` — don't depend on docker.sock and are kept as-is. Swapping to homepage's native Kubernetes provider would require an extra ServiceAccount + RBAC, not worth it for one status light — explicitly dropped |
| trilium storage | Standard dynamic PVC (`local-path` StorageClass), 5Gi | Deliberately no hostPath direct-mount of the existing directory. hostPath would skip the migration step but bypasses PVC lifecycle management, and is the pattern explicitly forbidden by Pod Security Standard "Restricted" and Kyverno's common default rules — phase E is about to add Kyverno, at which point it would either need an exception or a refactor; better to use the correct abstraction now. 5Gi has large headroom over the existing 12MB; `local-path` is a host directory underneath, doesn't pre-allocate space, so over-provisioning costs nothing |
| trilium `securityContext` | Don't set `runAsUser` | See "Current-State Constraints": entrypoint starts as root, `su`s down to uid 1000 by itself. Forcing `runAsUser: 1000` makes `su` fail |
| Resource requests/limits | homepage `100m`/`192Mi` → `300m`/`384Mi`; trilium `100m`/`320Mi` → `500m`/`640Mi` | Based on `docker stats` measurements (110MiB / 246MiB), leaving ~30% headroom for request, then double for limit |
| `workloads` quota | **Not adjusted** this phase | After adding the two services: requests `250m`/`576Mi`, limits `900m`/`1152Mi`, all still within `1`/`2Gi`. But `limits.cpu` has only `100m` headroom left — **must raise the quota before phase D starts**, otherwise the first new Application will be blocked by quota. This is a known, expected-for-phase-D item, not a gap in this phase |
| External exposure | NodePort: homepage `30081`, trilium `30082` | Reuse the NPM→NodePort bridging pattern validated twice in phase A/B. Fixed NodePort (not random allocation) is what makes NPM's forward rules stable |
| NPM config | Only change the Forward Hostname/IP + Port of the two existing proxy hosts, nothing else | Domain, SSL certificate, access list all kept exactly as-is, zero client-side change |

## Repo Layout

Continuing the convention from phase B:

```
vps_oracle/k3s/
  argocd/apps/
    homepage.yaml                  # new: child Application → ../../apps/homepage/k8s/
    trilium.yaml                   # new: child Application → ../../apps/trilium/k8s/
  apps/
    homepage/
      k8s/
        configmap.yaml             # config/*.yaml contents (docker provider and cards' container/server removed)
        deployment.yaml
        service.yaml               # NodePort 30081
    trilium/
      k8s/
        pvc.yaml                   # local-path, 5Gi
        deployment.yaml
        service.yaml               # NodePort 30082
```

The original `vps_oracle/compose/homepage/` and `vps_oracle/compose/trilium/` directories **stay unchanged** — the old compose definitions are part of the rollback path; phase H decides their fate.

## trilium Data Migration

`local-path`'s `WaitForFirstConsumer` binding mode determines the step order: after the PVC is created, no host directory is produced immediately — the provisioner only creates the directory once a Pod actually mounts the PVC and gets scheduled. So you cannot "create PVC → copy data → start Deployment"; instead:

1. **Stop writes**: `cd vps_oracle/compose/trilium && docker compose stop` (the user has confirmed no writes during migration, so no data-fork risk)
2. **Record baseline**: before migration, note the file count and total size of `/etc/trilium/data` as the post-migration comparison basis
3. **Create PVC + trigger provisioner**: manually apply `pvc.yaml` and a one-off helper Pod (mounting that PVC, `sleep`), the same manual apply/delete tool-Pod routine as phase A's `netpol-tester`. Wait for the PVC to become `Bound`, get the actual host directory from the PV's `spec.hostPath`
4. **Load data**: `sudo rsync -a /etc/trilium/data/ <PV dir>/`, then `sudo chown -R 1000:1000 <PV dir>` (the provisioner-created directory is owned by root; trilium's node process is uid 1000)
5. **Remove tool Pod**: delete the helper Pod (PVC kept, data stays in place)
6. **Hand to GitOps**: commit + push the `trilium.yaml` Application and all of `apps/trilium/k8s/` manifests (including `pvc.yaml`); when ArgoCD syncs it will "claim" this already-existing, already-populated PVC — the same pattern as phase B bringing phase A's manually-applied namespace/quota under GitOps management

Migration does not touch the original `/etc/trilium/data` (`rsync` only reads the source), and the old compose containers stay stopped, so rollback cost is minimal: `docker compose start`, and the data is still where it was.

## Migration SOP (this phase's core deliverable)

Applies to every phase D service, repeated per service:

1. **Inventory**: read the compose definition; list image tag, volumes, environment variables, NPM forward target, measured resource usage (`docker stats`)
2. **Translate manifest**: Deployment + Service (fixed NodePort); volumes are split by nature — versioned config goes to ConfigMap (if the service writes into that directory, use the initContainer→emptyDir pattern), real data goes to PVC
3. **Move data** (stateful services only): follow the six "trilium data migration" steps above
4. **Into GitOps**: `argocd/apps/<service>.yaml` + `apps/<service>/k8s/`, commit, push, sync
5. **Internal validation**: `kubectl -n workloads get pods` Running; `curl http://localhost:<NodePort>` works — **verify inside the cluster first, then cut traffic** (roadmap migration principle 3)
6. **Cut traffic**: change NPM's Forward Hostname/IP for that proxy host (host private IP, **must be a literal IP not a hostname** — a phase A known gotcha) and Forward Port (NodePort); domain/SSL/access list untouched
7. **External validation**: `curl https://<domain>` from the external network, confirm no visible change
8. **Stop old container**: `docker compose stop` (not `down`, not deleting data), kept as a rollback point

## Validation Checklist (phase C pass criteria)

1. `kubectl -n argocd get applications` → includes the new `homepage`, `trilium`, both `Synced` + `Healthy`
2. `kubectl -n workloads get pods` → homepage, trilium both `Running`, no `CrashLoopBackOff`
3. `kubectl -n workloads get pvc trilium` → `Bound`
4. **Data integrity**: after migration, the PV directory's file count and total size match the baseline recorded in step 2; and actually open an existing note in the trilium UI to confirm content is intact (matching file count does not mean the application can read it — both must be verified)
5. **Internal connectivity**: `curl http://localhost:30081` (homepage front page), `curl http://localhost:30082` (trilium login page) both respond normally — this must be done before switching NPM
6. **External no visible change**: after the traffic cut, `curl https://homepage.jerome.cloudns.asia`, `curl https://trilium.jerome.cloudns.asia` work, and actually operate them in a browser (homepage cards clickable, trilium can log in and read/write notes)
7. `kubectl describe resourcequota -n workloads` → `Used` within hard cap, and confirm the remaining `limits.cpu` headroom has been recorded (to be raised before phase D)
8. **Self-heal live test**: use homepage for the break test (`kubectl -n workloads scale deployment homepage --replicas=0`), confirm auto-restore. **Deliberately not trilium** — it's a service with real data, and there's no reason to take an extra downtime just to test a mechanism already validated in phase B
9. Old compose containers: `docker ps -a` confirms homepage/trilium are `Exited` and **not deleted**

## Known Limitations / Failure Modes

- **trilium has no data backup**: `/etc/trilium/data` currently has no automatic backup mechanism (the image's built-in `backup/` subdirectory is trilium's own database snapshot, not the same as host-level backup — if the same disk dies, both go). This is a pre-existing gap from before migration; not fixed in passing this phase to avoid scope creep. But after migrating to PVC the data actually lands under `/var/lib/rancher/k3s/storage/`, at a no-longer-obvious path, worth opening a separate work item for
- **`local-path`'s `reclaimPolicy: Delete`**: deleting the PVC deletes the data directory on the host along with it. ArgoCD's `prune: true` means removing `pvc.yaml` from git and syncing triggers this. The original data is still in `/etc/trilium/data` (migration leaves it), so it's recoverable for now, but once phase H decides to delete the old compose data this safety net is gone — handle the PVC with extra care then
- **trilium can't set `runAsUser`**, which directly conflicts with phase E's Kyverno/PSS "Restricted" baseline (that baseline requires `runAsNonRoot: true`). Phase E needs either an exception for trilium or an image that can start as non-root. Noted now, not solved now
- **homepage's ConfigMap→emptyDir pattern means things homepage writes into its config directory (including its own log) disappear on Pod restart**. For homepage this is fine (the log is unimportant, config is re-copied from ConfigMap each time), but this pattern cannot be blindly applied to services that "write back important state into the config directory" — phase D must judge per service when applying the SOP
- **Manual NodePort assignment**: `30081`/`30082` were hand-picked, with no mechanism preventing a future Application from colliding. Acceptable while service count is low; phase D will grow this list to the point where it needs central recording in the README
- **Brief interruption at the traffic-cut instant**: changing the NPM forward rule drops existing connections. Neither service is long-connection-sensitive (contrast 3x-ui's VLESS), impact negligible

## Handoff to Phase D

Phase D (remaining service migration) depends on what this phase leaves behind: the "Migration SOP" above, two replicable manifest layouts — `apps/homepage/` (stateless + ConfigMap template) and `apps/trilium/` (PVC + data migration template) — and the hands-on NPM→NodePort traffic-cut experience.

One thing that must be done before phase D starts: **raise the `workloads` ResourceQuota** (see "Components & Configuration" above; by then `limits.cpu` has only `100m` headroom left).

Phase D will hit new problems this phase deliberately did not cover: splitting multi-container services (the dify family), inter-Service dependencies and startup order, the StatefulSet vs Deployment trade-off for database-type services, 3x-ui's 39876 raw TCP passthrough (can't go through an HTTP reverse proxy, see the roadmap's current-state constraints), and the llm inference stack's large memory/multi-core resource budget.