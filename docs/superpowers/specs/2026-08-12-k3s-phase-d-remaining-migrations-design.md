# K3s Phase D — Remaining Service Migrations Design

Date: 2026-08-12

Corresponds to phase D of the [K3s cloud-native experiment platform roadmap](2026-08-05-k3s-cloud-native-platform-roadmap.md): migrate the remaining services into k3s one by one, producing a "migration result + compose decommission decision" for each service. Scope of this phase: migrate the **vikunja stack**, the **dify suite**, and the **llm inference stack**; **keep 3x-ui in compose** (the direct client connection on 39876 is too critical, see "3x-ui keep/decommission decision").

Precondition: [Phase C migration template design](2026-08-09-k3s-phase-c-migration-template-design.md) is complete and verified. Cluster current state (measured 2026-08-12): 7 Applications all `Synced`/`Healthy` (argocd, phase-a-foundation, placeholder-hello, homepage, trilium, evidence-os-website, root); NodePorts in use `30081`(homepage)/`30082`(trilium)/`30083`(evidence)/`30090`(argocd); `workloads` quota `2C/4Gi`, actual usage `limits.cpu 1` / `limits.memory 1280Mi`, ample headroom.

## Scope

**To be done in this phase:**
- Migrate the **vikunja stack** into `workloads`: vikunja (including sqlite data migration) + vikunja-notify-relay + apprise (relay's only external dependency; migrating it too avoids crossing the docker/k8s boundary)
- Migrate the **dify suite** (9 containers) into a new `dify` namespace: db-postgres, pgvector, redis, ssrf-proxy, plugin-daemon, api, worker, worker-beat, web
- Migrate the **llm inference stack** into a new `llm` namespace: llama-cpp, open-webui, sillytavern (the whole stack is currently stopped, so this amounts to rebuilding in k8s with no cutover disruption)
- **3x-ui**: not migrated; the compose decommission decision is recorded as "keep"
- Deliverable: per-service migration result + per-service compose decommission decision

**Not done in this phase (left to later phases):**
- 3x-ui migration — 39876 is raw TCP that clients connect to directly (not via HTTP reverse proxy), with a real outage history (see roadmap current-state constraints); the candidate mechanism for migrating it (Klipper LB binding 39876) is kept in this design doc's appendix, untouched this phase
- Ingress / cert-manager replacing NPM — phase H
- Sealed Secrets / supply chain security (Trivy admission, Cosign signing verification, Kyverno) — phase E; D uses "manually created Secrets" as a stopgap (see "Secrets strategy")
- dify / llm CI pipelines — all third-party images (digest-pinned), no build step to attach; the only locally-built one is vikunja-notify-relay (see "relay image")
- Data backup mechanism — a pre-existing gap from before migration, already recorded in phase C, not solved opportunistically this phase
- Migration/decommission of NPM itself — evaluated only in phase H

## Current-state constraints

- **Resources**: 4C/24G (Oracle Ampere ARM), `free -h` shows 23Gi total, about 12Gi available. The existing docker compose side (monitoring, ccr, provider-switch, portainer, npm, programming-learning-platform, lab-environment, etc.) plus the k3s side (argocd, cilium, homepage/trilium/evidence/placeholder) have already consumed about half the memory
- **The llm stack is currently stopped**: `docker compose ps -a` shows the llama-cpp / open-webui / sillytavern containers don't exist (previously removed via `docker compose down`). So the llm migration has no "stop writes → move data → cut over traffic" rhythm; the data (models 1.9G, openwebui 894M, sillytavern 21M) is all static and can be copied straight into PVCs
- **dify image size**: 7 uncompressed images total about 8.5GB (dify-api 4.09GB, dify-plugin-daemon 2.26GB are the largest; dify-api's main cause is a 2.42GB Python venv + a 420MB apt layer including `fonts-noto-cjk`). containerd and docker are separate image stores, so the migration pulls a fresh copy. Disk is no concern (193G total, 89G available); the only cost is a one-time pull time. If it matters, `docker save` → `ctr images import` can preload
- **apprise is relay's only external dependency**: relay reaches apprise via `APPRISE_BASE_URL=http://apprise:8000` (docker DNS). Once relay is in k8s it can't resolve docker DNS, so apprise must migrate along (a same-named `apprise` Service inside k8s keeps this URL working as-is), or apprise's 8000 must be published to the host so k8s can reach across the boundary — the latter couples k8s workloads to a compose host port, which is uglier; this design chooses the former
- **vikunja currently uses sqlite, not postgres**: `VIKUNJA_DATABASE_TYPE: sqlite`. The roadmap D "vikunja+pg" is an idealized description; this stack never ran postgres. Switching database engines during migration is too risky (Phase C principle: change only the execution platform, not version/architecture at the same time), so this phase migrates sqlite as-is, with `vikunja.db` going into a PVC
- **dify's NPM host has 8 custom locations** (measured from the NPM DB): `/console/api`, `/api`, `/v1`, `/files`, `/mcp`, `/triggers`, `/openapi` → api:5001, `/e/` → plugin-daemon:5002, default → web:3000. After migration these 8 locations' Forward Host/Port must be changed one by one to the corresponding NodePorts
- **dify api/worker/worker-beat share the same storage directory**: in compose all three mount `/etc/dify/storage:/app/api/storage`. In k8s this is one RWO PVC mounted by three pods — legal on a single-node cluster (RWO's semantics are "single node"; multiple pods on the same node may share it), this phase relies on this, see "Known limitations"
- **dify service names must not contain underscores**: k8s Service names are subject to RFC 1123, so `db_postgres`/`worker_beat`/`plugin_daemon`/`ssrf_proxy` must become hyphenated names like `db-postgres`, and env vars in api/worker etc. like `DB_HOST`/`PLUGIN_DAEMON_URL`/`SSRF_PROXY_HTTP_URL` change accordingly
- **NPM's Forward Hostname/IP must be a literal IP** (known phase A gotcha): all new NodePorts point to `10.0.0.95`

## Architecture

```
Internet ──▶ NPM(host 80/443, single entry, untouched this phase)
              │
              │ vikunja.jerome.cloudns.asia        ─▶ 10.0.0.95:30084
              │ apprise.jerome.cloudns.asia        ─▶ 10.0.0.95:30085
              │ dify.jerome.cloudns.asia           ─▶ 30086(web default) / 30087(api: /api /v1 /files /mcp /triggers /openapi /console/api) / 30088(plugin-daemon: /e/)
              │ ollama.jerome.cloudns.asia         ─▶ 10.0.0.95:30089  (open-webui)
              │ sillytavern.jerome.cloudns.asia    ─▶ 10.0.0.95:30091
              │(panel/sub.3x, 3xpanel ─▶ compose 3x-ui, unchanged)
              ▼
        ┌─────────────────────────────────────────────────────────┐
        │ k3s                                                     │
        │                                                         │
        │  workloads ns(existing)                                    │
        │    vikunja  Deployment+PVC(sqlite+files) ─ NodePort 30084
        │    vikunja-relay Deployment(stateless,ClusterIP)         │
        │    apprise   Deployment+PVC(config 40K) ─ NodePort 30085│
        │                                                         │
        │  dify ns(new this phase)                                    │
        │    db-postgres / pgvector / redis   StatefulSet+PVC      │
        │    ssrf-proxy / plugin-daemon / api / worker /           │
        │    worker-beat / web                Deployment          │
        │    (api/worker/beat share storage PVC;                 │
        │      egress NetworkPolicy does SSRF isolation)                │
        │                                                         │
        │  llm ns(new this phase)                                    │
        │    llama-cpp   Deployment+PVC(models)  ClusterIP        │
        │    open-webui  Deployment+PVC(data)   ─ NodePort 30089  │
        │    sillytavern Deployment+PVC(config) ─ NodePort 30091  │
        └─────────────────────────────────────────────────────────┘
              ▲
              │ ArgoCD root Application
              │   ├─ existing(argocd / phase-a-foundation / placeholder-hello / homepage / trilium / evidence-os-website)
              │   ├─ vikunja   ← new this phase(vikunja + relay)
              │   ├─ apprise   ← new this phase
              │   ├─ dify      ← new this phase(incl. dify ns + quota + NetworkPolicy)
              │   └─ llm       ← new this phase(incl. llm ns + quota)
```

## Namespaces and quotas

Per the design decision: **large stacks get their own namespace**, `workloads` keeps only small services.

| Namespace | Contents | Quota | Rationale |
|---|---|---|---|
| `workloads`(existing) | vikunja + relay + apprise | unchanged (`2C/4Gi`) | after adding the vikunja stack, requests about `350m`/`384Mi`, limits about `700m`/`768Mi`; plus existing `1C/1280Mi` still within `2C/4Gi` |
| `dify`(new) | 9 containers | requests `2.5C/2Gi`, limits `3C/4Gi` | baseline measured via `docker stats` (~1.34Gi total) with 30% headroom, limits doubled; an independent ns gets its own quota and won't be squeezed out by other stacks |
| `llm`(new) | llama-cpp + open-webui + sillytavern | requests `2C/4Gi`, limits `5C/13Gi` | llama.cpp's 9G limit is an "anti-OOM ceiling", not a steady-state need (a 3B model is actually ~2-3G). **Deliberately breaks the phase C "request==limit" convention**: a low request avoids locking up half the machine's memory for a usually-idle inference stack, while a high limit is protective. The node itself is 4C/24G; oversubscribing limits (5C/13Gi > physical ceiling) is normal, and only ~12Gi was available to it anyway |

dify / llm's namespace + ResourceQuota each live in the corresponding app's `k8s/` directory, created and governed by their respective ArgoCD Applications (mirroring how phase-a-foundation manages `workloads`, but this phase folds ns/quota into the app itself so they prune together with the app).

## Components and configuration

### vikunja stack(workloads)

| Item | Decision | Rationale |
|---|---|---|
| vikunja image | `vikunja/vikunja:2.4.0` (keep current tag) | Phase C principle: change platform, not version |
| vikunja database | migrate sqlite as-is | see "Current-state constraints": it already runs sqlite, don't opportunistically switch to postgres during migration |
| vikunja storage | 1 PVC (`local-path`, 2Gi), subpaths mounting `files` → `/app/vikunja/files`, `db` → `/db` | reuses the trilium PVC pattern; `/etc/vikunja` is only 4.8M, 2Gi is plenty. Data migration follows the trilium six steps (seed pod) |
| vikunja env | keep all: `TZ`, `VIKUNJA_SERVICE_SECRET` (secret), `VIKUNJA_SERVICE_PUBLICURL`, `ENABLEREGISTRATION=false`, `ALLOWNONROUTABLEIPS=true` | `ALLOWNONROUTABLEIPS=true` is needed in k8s too — relay's ClusterIP is a private range, and without it vikunja's own SSRF protection blocks it |
| vikunja NodePort | `30084` (internal 3456) | NPM→NodePort bridging |
| vikunja `enableServiceLinks` | **false** | the Service name `vikunja` would inject `VIKUNJA_PORT=tcp://...`, colliding with the `VIKUNJA_*` env vars vikunja itself reads — the trilium `TRILIUM_PORT` lesson replaying directly. **All pods migrated this phase set it false** |
| relay image | push to GHCR (`ghcr.io/jeromefromcn/vikunja-notify-relay:<tag>`) | currently a local `docker compose build` image that k8s can't pull. See "relay image" |
| relay | stateless Deployment, ClusterIP `vikunja-notify-relay:8080`, `enableServiceLinks: false` | keep the Service name identical to compose so the already-registered webhook URL `http://vikunja-notify-relay:8080/` in vikunja's DB resolves unchanged |
| apprise image | `caronc/apprise:v1.5.1` | keep |
| apprise storage | 1 PVC (40K config) | `/config` is apprise's own persistence (holding the `vikunja-tg-{username}` targets), not versioned config, so a PVC is required. Seed pod copies `/etc/apprise/config` |
| apprise NodePort | `30085` (internal 8000) | relay reaches `http://apprise:8000` (same-name DNS inside k8s), NPM's `apprise.jerome.cloudns.asia` repointed to the NodePort |
| resource requests/limits | vikunja `100m/128Mi → 300m/256Mi`; relay `50m/64Mi → 100m/128Mi`; apprise `200m/192Mi → 300m/384Mi` | baseline measured via `docker stats` (38Mi/13Mi/135Mi); total still within `workloads` quota |
| NPM | `vikunja` → `10.0.0.95:30084`, `apprise` → `10.0.0.95:30085` | domain/SSL/access list untouched |

### dify(dify namespace)

| Item | Decision | Rationale |
|---|---|---|
| image | keep current compose digests (api/worker/worker-beat share `langgenius/dify-api:1.14.2@sha256:0628…`, web `1.14.2@sha256:db73…`, plugin-daemon `0.6.1-local@sha256:fa7a…`, pg etc. unchanged) | change platform, not version; both version and image pinned |
| StatefulSet vs Deployment | **db-postgres / pgvector / redis use StatefulSet**; the rest (ssrf-proxy, plugin-daemon, api, worker, worker-beat, web) use Deployment | on a single node, RWO PVC + Deployment rolling updates briefly have old and new pods coexist; StatefulSet's ordered updates prevent RWO mount conflicts; StatefulSet also gives databases stable network identity |
| Service naming | `db-postgres`, `pgvector`, `redis`, `ssrf-proxy`, `plugin-daemon`, `api`, `web`; env `DB_HOST: db-postgres`, `SSRF_PROXY_HTTP_URL: http://ssrf-proxy:3128`, `PLUGIN_DAEMON_URL: http://plugin-daemon:5002` etc. change accordingly | k8s Service names disallow underscores |
| which get NodePort | **web(30086), api(30087), plugin-daemon(30088)**; rest ClusterIP internal | corresponds to NPM's three backends (default → web, 7 locations → api, `/e/` → plugin-daemon). worker/worker-beat/ssrf-proxy/db/redis/pgvector have no external entry |
| SSRF isolation | **two layers**: (1) application layer — keep compose's `SSRF_PROXY_HTTP_URL/HTTPS_URL=http://ssrf-proxy:3128`, api/worker's outbound HTTP goes through squid, squid.conf blocks private ranges/metadata; (2) network layer — dify ns **egress NetworkPolicy**: api/worker/worker-beat may only egress to same-ns Services (incl. ssrf-proxy) + DNS, no direct internet; plugin-daemon may egress to the internet (its model-provider calls are direct, not via squid — compose never set proxy env for it); ssrf-proxy may egress; web may egress to same ns + internet (marketplace) | compose's `ssrf_proxy_network: internal` is network-layer isolation but api/plugin are also on the proxy network, so a direct-internet path still exists — "application-layer proxy + incomplete network isolation". k8s completes the isolation with egress NetworkPolicy. **No default-deny on ingress** — NPM's inbound `world` traffic must reach web/api/plugin-daemon's NodePorts (the k8s README gotcha: default-deny + NPM needs an extra allow-world, so here we simply skip default-deny) |
| SSRF verification gate | after migration, **run a real workflow** (with an HTTP-request node and an LLM conversation) to confirm SSRF isolation doesn't block normal model calls and the HTTP node can still reach the internet | if the egress policy wrongly blocks model calls, the fallback is to keep only application-layer isolation and drop the network layer (see "Known limitations") |
| storage | 5 PVCs: `db-postgres`, `pgvector`, `redis`, `plugin-daemon`, `storage` (shared by api/worker/beat, RWO single-node semantics) | corresponds to compose's 5 `/etc/dify/*` directories. The `storage` sharing relies on single-node (see "Known limitations"). db/pgvector/redis go through their own StatefulSet PVCs |
| `enableServiceLinks` | all **false** | uniformly avoids `<SVC>_PORT` colliding with env |
| secrets | `dify-secrets` (DB_PASSWORD, PGVECTOR_PASSWORD, REDIS_PASSWORD, SECRET_KEY, INIT_PASSWORD) created manually | see "Secrets strategy"; plugin-daemon's `SERVER_KEY`/`DIFY_INNER_API_KEY` are upstream defaults (already committed in compose, author notes non-sensitive), can stay in manifest |
| config | ssrf-proxy's `squid.conf.template` + `docker-entrypoint.sh` → ConfigMap | these two files are in the repo, mounted via ConfigMap |
| first boot | keep `MIGRATION_ENABLED: "true"` (api runs DB migration on start), `INIT_PASSWORD` | keep compose behavior |

### llm inference stack(llm namespace)

| Item | Decision | Rationale |
|---|---|---|
| llama-cpp | Deployment + ClusterIP `llama-cpp:8080`, models dir → PVC (1.9G), keep env `LLAMA_ARG_THREADS=3`/`CTX_SIZE=8192`/`CACHE_RAM=4096`, resources `1C/2Gi → 3C/9Gi` | keep compose's router mode and resource ceilings (Ampere-optimized `amperecomputingai/llama.cpp:3.4.2`, don't revert to ollama). Currently stopped = PVC copied from `/etc/llama-cpp/models`, no concurrent-write risk |
| open-webui | Deployment + NodePort `30089`, `/app/backend/data` → PVC (894M), `WEBUI_SECRET_KEY` secret, `OPENAI_API_BASE_URLS=http://llama-cpp:8080/v1` (k8s DNS) | NPM's `ollama.jerome.cloudns.asia` domain actually points at open-webui (historical naming); domain unchanged, only the Forward repointed to the NodePort |
| sillytavern | Deployment + NodePort `30091`, config/data/plugins/extensions → PVC (21M), basic auth credentials secret | ST's `SILLYTAVERN_<path>` env override mechanism was already used in compose to inject credentials (`.env`); k8s injects the same-named env via secretKeyRef. The Service name `sillytavern` would inject `SILLYTAVERN_PORT`, which ST's generic env override misreads → **`enableServiceLinks: false` is required** |
| resources | llama-cpp `1C/2Gi → 3C/9Gi`; open-webui `500m/1Gi → 1C/2Gi`; sillytavern `200m/256Mi → 200m/512Mi` | total limits `4.2C/11.5Gi`, within the llm ns quota `5C/13Gi` |
| internal networking | only open-webui / sillytavern → llama-cpp need to talk to each other, ClusterIP suffices | no entry points besides NPM |

### relay image

`vikunja-notify-relay` is the only locally-built image in the repo (Dockerfile + app.py + test_app.py all under `vps_oracle/compose/vikunja/notify-relay/`). For k8s to pull it, it must be pushed to a registry:

- **Recommended**: add a GitHub Actions workflow, following the existing shape of `placeholder-hello.yml` (build `linux/arm64` → Trivy → keyless Cosign → push to `ghcr.io/jeromefromcn/vikunja-notify-relay`), trigger on `vps_oracle/compose/vikunja/notify-relay/**`. Consistent with the roadmap's "all future deployments go through GitOps", and makes future relay changes reproducible
- Fallback: manually `docker build` + `docker push` once. Acceptable, but loses CI reproducibility

### Secrets strategy(stopgap before phase E)

**Create Secrets manually, out-of-band, not in git**. Rationale: ArgoCD's repo-server clones from git, the gitignored `.env` isn't in the repo, so Kustomize `secretGenerator` can't read it — this path doesn't work under GitOps. Instead:

- Source: each compose directory's existing gitignored `.env` (`vikunja/.env`, `dify/.env`, `llm/.env`)
- Creation: `kubectl create secret generic <name> --from-env-file=<that .env>` (or `--from-literal` for specific keys)
- Consumption: Deployment/StatefulSet reference via `secretKeyRef`
- ArgoCD won't touch these Secrets (resources not in the repo; prune/selfHeal only manage what ArgoCD manages), so they survive; **confirm the Secret exists before every sync** (the plan's steps verify this)
- once phase E takes over with Sealed Secrets, these out-of-band Secrets are retired

| Namespace | Secret | Contents |
|---|---|---|
| workloads | `vikunja` | `VIKUNJA_SERVICE_SECRET` |
| dify | `dify-secrets` | `DB_PASSWORD`, `PGVECTOR_PASSWORD`, `REDIS_PASSWORD`, `SECRET_KEY`, `INIT_PASSWORD` |
| llm | `open-webui` | `WEBUI_SECRET_KEY` |
| llm | `sillytavern` | `SILLYTAVERN_BASICAUTHUSER_USERNAME`, `SILLYTAVERN_BASICAUTHUSER_PASSWORD` |

## Repo layout

Follow phase B/C conventions: one compose stack maps to one child Application. dify / llm's namespace + quota fold into their own app directories:

```
vps_oracle/k3s/
  argocd/apps/
    vikunja.yaml                # new → ../../apps/vikunja/k8s/(vikunja + relay, one Application)
    apprise.yaml                # new → ../../apps/apprise/k8s/
    dify.yaml                   # new → ../../apps/dify/k8s/
    llm.yaml                    # new → ../../apps/llm/k8s/
  apps/
    vikunja/k8s/
      pvc.yaml                  # local-path, 2Gi
      deployment.yaml           # vikunja
      service.yaml              # NodePort 30084
      relay/deployment.yaml     # vikunja-notify-relay
      relay/service.yaml        # ClusterIP 8080
    apprise/k8s/
      pvc.yaml                  # local-path, 1Gi(40K config)
      deployment.yaml
      service.yaml              # NodePort 30085
    dify/k8s/
      namespace.yaml            # dify ns
      resourcequota.yaml        # requests 2.5C/2Gi, limits 3C/4Gi
      networkpolicies.yaml      # SSRF egress isolation
      configmap.yaml            # ssrf squid.conf + entrypoint
      db-postgres.yaml          # StatefulSet + Service + PVC
      pgvector.yaml             # StatefulSet + Service + PVC
      redis.yaml                # StatefulSet + Service + PVC
      ssrf-proxy.yaml           # Deployment + Service
      plugin-daemon.yaml        # Deployment + Service + PVC
      api.yaml                  # Deployment + Service(NodePort 30087)
      worker.yaml               # Deployment
      worker-beat.yaml          # Deployment
      web.yaml                  # Deployment + Service(NodePort 30086)
      storage-pvc.yaml          # shared by api/worker/beat
    llm/k8s/
      namespace.yaml            # llm ns
      resourcequota.yaml        # requests 2C/4Gi, limits 5C/13Gi
      llama-cpp.yaml            # Deployment + Service + PVC(models)
      open-webui.yaml           # Deployment + Service(NodePort 30089) + PVC
      sillytavern.yaml          # Deployment + Service(NodePort 30091) + PVC
```

The original `vps_oracle/compose/{vikunja,dify,llm}/` stay unchanged — the old compose definitions are the rollback path, decommission is decided in phase H. `vps_oracle/compose/3x-ui/` likewise (already decided keep).

dify / llm's child Applications need `syncPolicy.syncOptions: [CreateNamespace=true]` (new namespaces created by ArgoCD, with `namespace.yaml` still placed in `k8s/` for it to govern); vikunja / apprise land in the existing `workloads` ns and don't need it.

## Migration SOP(reuse phase C, applied per service)

Phase C's SOP applies unchanged, repeated per service (inventory → translate manifests → move data → into GitOps → internal verification → cutover → external verification → stop old containers). Three new points this phase:

1. **Dependency ordering for multi-container stacks**: dify has 9 pods with inter-Service dependencies. ArgoCD sync creates all at once, relying on initContainer/readiness rather than dependency ordering; but **verification must go bottom-up** (db/redis healthy → api/worker up → web up → run the workflow)
2. **DB data migration order**: follow the trilium six steps, seed pod triggers `WaitForFirstConsumer` provisioner → rsync → chown (dify's storage owner is uid 1001; postgres/pgvector/redis data-dir owners are each image's postgres/redis uid — `chown` correctly after copying)
3. **NPM custom locations**: dify's 8 locations must each have Forward Host/Port changed, not just the default forward. Use the NPM automation API (`vps_oracle/compose/npm/.npm-automation.env` + README) to `PUT` each location

## Migration order

1. **vikunja stack** (simplest, self-contained) — validates the "multi-pod mutual dependency + sqlite PVC + relay into registry + webhook URL reuse" pattern, laying groundwork for the next two stacks
2. **dify** (largest, heaviest) — 9 containers, 3 StatefulSets, SSRF NetworkPolicy, 5 secrets, 8 NPM locations. Self-contained, low external risk
3. **llm** (currently stopped, no cutover) — last because it's dormant, no urgency to revive, and heaviest on resources (3C/9G once running)

Only start the next service after the previous one is migrated and stabilized (passed the checklist).

## Verification checklist(phase D pass criteria)

**Common (every service):**
1. `kubectl -n <ns> get applications` → the new `vikunja`, `apprise`, `dify`, `llm` are all `Synced` + `Healthy`
2. `kubectl get pods -n <ns>` → all `Running`, no `CrashLoopBackOff`
3. all PVCs `Bound`
4. **Internal connectivity**: before switching NPM, first `curl http://localhost:<NodePort>` to verify (vikunja login page, apprise root path, dify web homepage, open-webui login page, sillytavern)
5. **Data integrity**: after migration, the file count/size in the PV directory matches the baseline (phase C's "don't count files at the exact moment you stop the container" lesson); stateful services verified by actually reading/writing in the UI
6. **Externally invisible**: after changing NPM, `curl https://<domain>` works + browser spot-check
7. **Old compose containers stopped but preserved**: `docker ps -a` shows `Exited`, not deleted (llm had no containers to begin with)

**Service-specific:**
8. **vikunja**: login, create a task; **end-to-end Telegram notification** (edit a task to trigger webhook → relay → apprise → Telegram received) — proves the whole chain still works after migrating relay+apprise
9. **dify**: login (`INIT_PASSWORD` first login); run a **real workflow**: LLM conversation + an app with an HTTP-request node (proves SSRF isolation doesn't wrongly block, model calls work, HTTP node reaches the internet); upload a document into the knowledge base (proves the shared storage reads/writes normally)
10. **llm**: open-webui starts a conversation → llama.cpp infers normally (3B model); sillytavern can reach the backend
11. **Quotas**: `kubectl describe resourcequota -n {dify,llm}` → `Used` within hard caps; `workloads` too
12. **NodePorts**: new NodePorts (30084-30089, 30091) don't collide (`kubectl get svc -A` double-check)

## Known limitations / failure modes

- **dify shared storage relies on single-node semantics**: the RWO PVC is mounted by three pods (api/worker/beat), valid only because "RWO = single node, this cluster has one node". A second node would block the second pod — accepted this phase, recorded
- **dify egress NetworkPolicy may wrongly block model calls**: by design plugin-daemon reaches the internet directly (model providers), api/worker go via squid. If testing shows api/worker have necessary outbound calls that don't go through squid, the policy blocks them → checklist item 9 is meant to catch this; if truly blocked, drop the network layer and keep only application-layer SSRF (matching compose's current state), without affecting the migration itself
- **relay image must hit the registry first**: vikunja sync depends on `ghcr.io/jeromefromcn/vikunja-notify-relay` already existing. Order-wise, run CI (or manual push) before sync
- **manual Secrets are out-of-band state**: ArgoCD neither creates nor repairs them; deleted = gone (pods won't start). The plan verifies secret existence before each service's sync; this is a known compromise until phase E adopts Sealed Secrets
- **llm quota breaks the request==limit convention**: `requests 2C/4Gi, limits 5C/13Gi`. Intentional (see "Namespaces and quotas"); when adding llm services later, remember that oversubscribed limits are part of the design
- **dify large image pulls**: ~8.5GB one-time download into containerd; open-webui alone is 6.5GB. Disk at 89G available is no concern, just slow first sync. If it matters, `docker save` + `ctr images import` to preload
- **TZ**: all set `TZ=Asia/Hong_Kong`, but does nothing if the image lacks tzdata (k8s README's comparison table). After migration, test each container with `date` and align with compose behavior, no further chasing
- **webhook re-registration**: the already-registered webhook URL in vikunja's DB (`http://vikunja-notify-relay:8080/`) is reused because the Service name matches, so no need to rerun `register-telegram-webhooks.sh`; but if that script is rerun later, its API base `http://vikunja:3456` must change to the k8s Service address (the plan mentions this)
- **brief outage at NPM cutover**: changing location/forward breaks existing connections. vikunja/dify aren't long-connection-sensitive (contrast with 3x-ui's VLESS), impact negligible

## 3x-ui keep/decommission decision(stay in compose)

- **Decision: keep in compose, don't migrate**. 39876 is client-direct VLESS+Reality raw TCP, not via an HTTP reverse proxy, and has had a real outage (2026-07-24 incident: shallow probing + `ulimit`). The migration demands zero downtime, but any k8s approach (extending the NodePort range requires restarting k3s; hostNetwork conflicts with phase E's PSS/Kyverno) touches a well-functioning production port — risk/benefit doesn't add up
- 3x-ui staying on the docker `proxy` network doesn't affect other migrations: NPM's `panel.3x`/`sub.3x`/`3xpanel` forwards, static IP/DNS host overrides all unchanged
- **Appendix (candidate mechanisms if migration is wanted later)**: Klipper LB (k3s's built-in LoadBalancer) binding `39876`, no k3s restart needed, pods stay isolated — the most likely path; still need to allow 39876 on the host firewall, and change xray's DNS host override from the docker network (172.19.0.3) to a reachable address pointing at NPM. Not implemented this phase

## Handoff to phase E

Phase E (supply chain security) depends on this phase: **Sealed Secrets takes over D's manual Secrets**, and **Kyverno/PSS baseline** must handle the three known conflicts left by this phase (trilium's missing `runAsUser`, 3x-ui's hostNetwork if migrated, dify shared storage's hostPath exception if changed) — phase D uses the right abstractions (PVC, NetworkPolicy, secretKeyRef) wherever possible to minimize the surface of exceptions needed.

This phase is also phase G (service mesh)'s precondition: dify's Service naming and NetworkPolicy model, and llm's large resource budget, both feed into G's "which services enter the mesh" considerations.