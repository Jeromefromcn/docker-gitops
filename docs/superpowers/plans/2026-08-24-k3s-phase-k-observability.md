# K3s Phase K — Mesh Observability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `pr-lanes`' mesh metrics (istiod/ztunnel/waypoint), waypoint access logs, and Envoy traces queryable in the docker-compose stack's existing Prometheus/Grafana — without installing a second monitoring stack and without depending on `lab-environment`.

**Architecture:** A new, independent k3s namespace (`mesh-observability`) hosts Loki, Jaeger, and a `pr-lanes`-scoped Promtail — none of it in `pr-lanes-quota`, none of it in `lab-environment`. Three new NodePort `Service`s expose istiod's, ztunnel's, and waypoint's existing Prometheus endpoints; two more expose Loki's query API and Jaeger's query UI. Compose's *existing* Prometheus/Grafana pull/query all five over NodePort — the one cross-boundary direction proven to work in production (matches how NPM already reaches k3s NodePorts). Promtail→Loki and Envoy→Jaeger's Zipkin collector both stay inside the cluster (ClusterIP), never crossing the docker↔k3s boundary. Compose's `prometheus`/`grafana` containers need one prerequisite fix first — their docker network gateway currently resolves to the wrong network, so they can't reach *any* k3s NodePort yet.

**Tech Stack:** Kubernetes plain manifests (no Kustomize needed — same pattern as `hello`/`lab-environment`), ArgoCD (`project: default`, automated prune+selfHeal), Grafana Loki `3.1.0`, Jaeger `jaegertracing/all-in-one:1.60`, Grafana Promtail `3.1.0` (same pinned versions already running in `lab-environment`), Istio `telemetry.istio.io/v1` `Telemetry` CR + `meshConfig.extensionProviders` (istiod `1.30.3`, confirmed live), Docker Compose `v5.1.4` / Engine `29.6.0` (confirmed supports `networks.<name>.priority`).

**Spec:** [docs/superpowers/specs/2026-08-24-k3s-phase-k-observability-design.md](../specs/2026-08-24-k3s-phase-k-observability-design.md)

**Depends on:** Phase J (complete, merged to main) — confirmed not to interfere (see Global Constraints). Independent of Phase L (not started). Treats [docs/incidents/2026-08-24-k3s-pod-to-docker-bridge-blackhole.md](../../incidents/2026-08-24-k3s-pod-to-docker-bridge-blackhole.md) and [docs/incidents/2026-08-24-compose-prometheus-grafana-k3s-nodeport-gateway.md](../../incidents/2026-08-24-compose-prometheus-grafana-k3s-nodeport-gateway.md) as settled root-cause findings — this plan does not re-diagnose either issue, only applies the fix the second one already prescribes.

## Global Constraints

- **`lab-environment` is never touched by this plan.** No file under `vps_oracle/k3s/apps/lab-environment/` is created, modified, or read for anything other than copying a pattern (Loki/Jaeger/Promtail specs, ConfigMap structure) into the new `mesh-observability` files. Verify this holds at the end (Task 7).
- **`pr-lanes-quota` is unaffected.** Confirmed live before this plan: `limits.cpu: 500m/1200m`, `limits.memory: 640Mi/1536Mi`, `requests.cpu: 125m/400m`, `requests.memory: 320Mi/768Mi` (Phase J's numbers). The only `pr-lanes`-namespaced resources this plan adds are a `Service` (`waypoint-metrics`, Task 4) and a `Telemetry` CR (Task 3) — both pure control-plane objects, zero CPU/memory request. Re-check these exact numbers are unchanged after every task that touches `pr-lanes`.
- **`mesh-observability`'s own `ResourceQuota`** (Task 1): `requests.cpu: 200m`, `requests.memory: 320Mi`, `limits.cpu: 500m`, `limits.memory: 640Mi`. Loki (`50m`/`128Mi` request, `100m`/`256Mi` limit), Jaeger (`25m`/`64Mi` request, `100m`/`256Mi` limit), and Promtail (`25m`/`32Mi` request, `50m`/`64Mi` limit) together request `100m`/`224Mi` and limit `250m`/`576Mi` — both comfortably inside the quota, with headroom left on every dimension. Do not raise this quota without re-reading the roadmap's host-memory constraint (23Gi total, 813Mi truly free as of 2026-08-19, swap 85% used) — if any pod is throttled against these limits, that's a signal to investigate before raising the number, not a reason to raise it reflexively.
- **NodePort allocations, confirmed free immediately before this plan starts** (`kubectl get svc -A --field-selector spec.type=NodePort`, re-run this exact command at the start of Task 1 — if anything now occupies `30110`-`30114`, stop and pick different numbers before proceeding, don't silently overwrite):

  | Service | Namespace | NodePort | Port |
  |---|---|---|---|
  | `istiod-metrics` | `istio-system` | `30110` | `15014` |
  | `ztunnel-metrics` | `istio-system` | `30111` | `15020` |
  | `waypoint-metrics` | `pr-lanes` | `30112` | `15090` |
  | `loki` | `mesh-observability` | `30113` | `3100` |
  | `jaeger-query` | `mesh-observability` | `30114` | `16686` |

  Already in use (do not collide): `30083` (pr-lanes/hello-frontend), `30090` (argocd), `30092`-`30098` (lab-environment + headlamp), `30512` (lab-environment jaeger-zipkin).
- **`istio-istiod` and `istio-ztunnel` are remote-Helm-chart ArgoCD Applications, not plain-manifest ones.** Their `source` is `https://istio-release.storage.googleapis.com/charts` (`chart: istiod`/`chart: ztunnel`); `vps_oracle/k3s/istio/*.yaml` is Helm **values** only (`valueFiles: - $values/vps_oracle/k3s/istio/istiod-values.yaml`), referenced via a second `ref: values` source. A plain `Service` YAML dropped into `vps_oracle/k3s/istio/` is **not** picked up by either Application — this is why `istiod-metrics-service.yaml` and `ztunnel-metrics-service.yaml` (Task 4) live in `mesh-observability`'s own directory instead, each with an explicit `metadata.namespace: istio-system`. ArgoCD applies a manifest to whatever namespace it names in `metadata.namespace`, regardless of the owning Application's own `destination.namespace` — `lab-environment`'s existing YAMLs already rely on this same explicit-namespace convention.
- **Kyverno does not interfere with anything in this plan** (confirmed by reading every policy file under `vps_oracle/k3s/kyverno/policies/`): `restrict-image-registry.yaml`'s `verifyImages` only matches `ghcr.io/jeromefromcn/*` image references — `grafana/loki`, `jaegertracing/all-in-one`, `grafana/promtail` don't match, so the rule doesn't apply to them at all. `require-vuln-scan-clean.yaml` and `restricted-self-built.yaml` both match only `app` label `in [hello-frontend, hello-backend]` — no pod this plan creates carries either label. `restrict-image-registry-pr-lanes.yaml` is scoped to the `pr-lanes` namespace and only concerns image *registries*, not Service objects (Task 4's `waypoint-metrics` Service, the only `pr-lanes` resource this plan adds besides the `Telemetry` CR, has no image).
- **`mesh-observability`'s namespace must carry no Pod Security Standards label** (no `pod-security.kubernetes.io/enforce`), matching `lab-environment`'s namespace exactly (confirmed live: `kubectl get namespace lab-environment -o jsonpath='{.metadata.labels}'` → only the automatic `kubernetes.io/metadata.name`). `pr-lanes`, by contrast, carries `pod-security.kubernetes.io/enforce: baseline`, which forbids `hostPath` volumes — Promtail's `/var/log/pods` mount (Task 2) would be rejected at admission if it ever landed in a baseline-enforced namespace. Do not add a PSS label to `mesh-observability`'s `namespace.yaml`.
- **Docker Compose `networks.<name>.priority` is confirmed supported** on this host (`docker compose version` → `v5.1.4`; `docker version --format '{{.Server.Version}}'` → `29.6.0`, both well above the Compose Spec version that introduced this field). Task 5 depends on this.
- **`host-firewall.sh` already allows the traffic this plan needs — no firewall changes anywhere in this plan.** The existing rule `ipt INPUT -s 172.19.0.0/16 -p tcp -m tcp --dport 30000:32767 -j ACCEPT` (added 2026-08-19, see [that incident](../../incidents/2026-08-19-npm-to-k3s-nodeport-outage.md)) already covers every NodePort this plan adds. If any verification step in this plan fails with something that looks like a firewall block, re-read [docs/incidents/2026-08-24-compose-prometheus-grafana-k3s-nodeport-gateway.md](../../incidents/2026-08-24-compose-prometheus-grafana-k3s-nodeport-gateway.md) before touching `vps_oracle/host-firewall/host-firewall.sh` — the actual root cause found there was the compose containers' own network gateway, not the firewall.
- **Never attempt to make a k3s pod connect out to a docker-compose container.** [docs/incidents/2026-08-24-k3s-pod-to-docker-bridge-blackhole.md](../../incidents/2026-08-24-k3s-pod-to-docker-bridge-blackhole.md) confirmed this direction is cluster-wide blackholed (a `fwmark 0x200/0xf00 → table 2004` policy route sends it to `lo`). Every data flow in this plan crosses the boundary in the other direction only (compose initiates, k3s NodePort receives) or stays entirely inside the cluster (ClusterIP). If a task in this plan is ever tempted to add a k3s→compose egress path, stop — that's a design change, not an implementation detail, and belongs back in brainstorming.
- **Envoy trace sampling is set to 100% deliberately** (Task 3's `Telemetry` CR, `randomSamplingPercentage: 100.0`), not left at Istio's low default — `pr-lanes` carries no real user traffic (same reasoning the roadmap's Phase L section already gives for skipping rate-limiting), so there's no cost concern, and Phase K's own verification (Task 7) needs traces to actually show up without needing dozens of retries.
- **Git workflow:** commit and push to `main` after each task; every k3s resource in this plan syncs via ArgoCD (`automated: {prune: true, selfHeal: true}`) — never `kubectl apply`/`patch`/`edit` a live k3s resource to test something before it's committed, per repo convention. Compose changes (Task 5, Task 6) are applied with `docker compose up -d` from `vps_oracle/compose/monitoring/`, per repo convention — not git-synced. This checkout has had concurrent-session activity before (other Claude sessions have committed unrelated files here mid-plan in the past) — run `git status` and `git log --oneline -3` before every commit in this plan, and only `git add` the files this plan actually touches, never a broad `git add -A`.
- **Read-only `kubectl`/`docker`/`cilium-dbg` diagnostics are always fine** at any point. The one documented exception for genuine live k3s trial-and-error (disable `selfHeal`, re-enable after) is **not needed anywhere in this plan** — every k3s mutation here is git-first, and the compose mutations (Task 5, Task 6) are compose's normal apply path, not a git-managed resource.

---

### Task 1: `mesh-observability` namespace, quota, and ArgoCD Application

**Files:**
- Create: `vps_oracle/k3s/apps/mesh-observability/k8s/namespace.yaml`
- Create: `vps_oracle/k3s/argocd/apps/mesh-observability.yaml`

**Interfaces:**
- Consumes: nothing from another task in this plan.
- Produces: the `mesh-observability` namespace and a synced ArgoCD Application watching `vps_oracle/k3s/apps/mesh-observability/k8s`. Every later task in this plan that adds a file under that directory relies on this Application already existing and syncing automatically — it is not recreated or modified again.

- [ ] **Step 1: Confirm current state before touching anything**

```bash
kubectl get namespace mesh-observability 2>&1
kubectl get svc -A --field-selector spec.type=NodePort -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,PORTS:.spec.ports
kubectl -n pr-lanes describe resourcequota pr-lanes-quota
git status
git log --oneline -3
```

Expected: `mesh-observability` namespace does not exist yet (`Error from server (NotFound)`). NodePort list matches the Global Constraints table exactly — `30110`-`30114` free. `pr-lanes-quota` matches Global Constraints. `git status` clean; note the current `git log` head.

- [ ] **Step 2: Write the namespace and quota**

```yaml
# vps_oracle/k3s/apps/mesh-observability/k8s/namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: mesh-observability
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: mesh-observability-quota
  namespace: mesh-observability
spec:
  hard:
    requests.cpu: "200m"
    requests.memory: 320Mi
    limits.cpu: "500m"
    limits.memory: 640Mi
```

No `pod-security.kubernetes.io/enforce` label — see Global Constraints.

- [ ] **Step 3: Write the ArgoCD Application**

```yaml
# vps_oracle/k3s/argocd/apps/mesh-observability.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: mesh-observability
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/Jeromefromcn/docker-gitops.git
    targetRevision: main
    path: vps_oracle/k3s/apps/mesh-observability/k8s
  destination:
    server: https://kubernetes.default.svc
    namespace: mesh-observability
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

Matches `lab-environment.yaml`'s format exactly (`CreateNamespace=true` is redundant with the explicit `Namespace` manifest in Step 2, same belt-and-suspenders pattern `lab-environment` already uses).

- [ ] **Step 4: Validate YAML and commit**

```bash
python3 -c "
import yaml
for f in ['vps_oracle/k3s/apps/mesh-observability/k8s/namespace.yaml',
          'vps_oracle/k3s/argocd/apps/mesh-observability.yaml']:
    list(yaml.safe_load_all(open(f)))
" && echo OK
git add vps_oracle/k3s/apps/mesh-observability/k8s/namespace.yaml vps_oracle/k3s/argocd/apps/mesh-observability.yaml
git commit -m "Add mesh-observability namespace and ArgoCD Application

New, independent k3s namespace for Phase K's Loki/Jaeger/Promtail —
not pr-lanes-quota, not lab-environment. See the Phase K design doc
for why both of those were ruled out."
git push
```

- [ ] **Step 5: Verify the namespace exists and the Application is healthy**

```bash
kubectl get namespace mesh-observability -o jsonpath='{.metadata.labels}'; echo
kubectl -n argocd get application mesh-observability -o custom-columns=SYNC:.status.sync.status,HEALTH:.status.health.status
kubectl -n mesh-observability describe resourcequota mesh-observability-quota
```

Expected: namespace exists, labels show only `kubernetes.io/metadata.name` (no PSS label). Application `Synced`/`Healthy`. Quota shows `0` used against the hard limits from Step 2.

---

### Task 2: Loki + Promtail (log pipeline)

**Files:**
- Create: `vps_oracle/k3s/apps/mesh-observability/k8s/configmaps.yaml`
- Create: `vps_oracle/k3s/apps/mesh-observability/k8s/loki.yaml`
- Create: `vps_oracle/k3s/apps/mesh-observability/k8s/promtail.yaml`

**Interfaces:**
- Consumes: `mesh-observability` namespace and its synced Application (Task 1).
- Produces: a running `loki` Service reachable in-cluster at `loki.mesh-observability.svc.cluster.local:3100`, and externally at NodePort `30113` (Task 6 consumes the NodePort for Grafana's datasource). Promtail pushes `pr-lanes` pod logs into it continuously — no other task depends on Promtail directly.

- [ ] **Step 1: Write the ConfigMaps (Loki config + Promtail config, pr-lanes-scoped)**

```yaml
# vps_oracle/k3s/apps/mesh-observability/k8s/configmaps.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: loki-config
  namespace: mesh-observability
data:
  loki-config.yml: |
    auth_enabled: false

    server:
      http_listen_port: 3100

    common:
      path_prefix: /loki
      storage:
        filesystem:
          chunks_directory: /loki/chunks
          rules_directory: /loki/rules
      replication_factor: 1
      ring:
        kvstore:
          store: inmemory

    schema_config:
      configs:
        - from: 2024-01-01
          store: tsdb
          object_store: filesystem
          schema: v13
          index:
            prefix: index_
            period: 24h

    limits_config:
      retention_period: 24h
      reject_old_samples: true
      reject_old_samples_max_age: 168h
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: promtail-config
  namespace: mesh-observability
data:
  # Same technique as lab-environment's promtail-config.yml: a
  # namespace-prefixed glob against kubelet's own per-pod log path, not
  # kubernetes_sd_configs + relabel_configs — this Promtail physically never
  # opens a log file outside pr-lanes, it doesn't just filter one out after
  # the fact. No Kubernetes API access, no RBAC/ServiceAccount needed.
  promtail-config.yml: |
    server:
      http_listen_port: 9080

    positions:
      filename: /tmp/positions.yaml

    clients:
      - url: http://loki:3100/loki/api/v1/push

    scrape_configs:
      - job_name: pr-lanes-pods
        static_configs:
          - targets:
              - localhost
            labels:
              job: pr-lanes
              namespace: pr-lanes
              __path__: /var/log/pods/pr-lanes_*/*/*.log
        pipeline_stages:
          - cri: {}
          - regex:
              source: filename
              expression: '^/var/log/pods/pr-lanes_(?P<pod_name>[^_]+)_[0-9a-f-]+/(?P<container_name>[^/]+)/\d+\.log$'
          - labels:
              pod_name:
              service: container_name
```

- [ ] **Step 2: Write Loki (Deployment + Service, NodePort)**

```yaml
# vps_oracle/k3s/apps/mesh-observability/k8s/loki.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: loki
  namespace: mesh-observability
  labels:
    app: loki
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: loki
  template:
    metadata:
      labels:
        app: loki
    spec:
      enableServiceLinks: false
      containers:
        - name: loki
          image: grafana/loki:3.1.0
          args:
            - -config.file=/etc/loki/loki-config.yml
          env:
            - name: TZ
              value: "Asia/Hong_Kong"
          ports:
            - containerPort: 3100
          volumeMounts:
            - name: config
              mountPath: /etc/loki/loki-config.yml
              subPath: loki-config.yml
          resources:
            requests:
              cpu: 50m
              memory: 128Mi
            limits:
              cpu: 100m
              memory: 256Mi
      volumes:
        - name: config
          configMap:
            name: loki-config
---
apiVersion: v1
kind: Service
metadata:
  name: loki
  namespace: mesh-observability
spec:
  type: NodePort
  selector:
    app: loki
  ports:
    - port: 3100
      targetPort: 3100
      nodePort: 30113
```

Same image/resource spec as `lab-environment/k8s/loki.yaml` — **`replicas: 1`, not `0`**. `lab-environment`'s copy is deliberately off by default; this one is Phase K's whole point and must stay on. Its Service is also `NodePort` here (Grafana needs to reach it from compose), where `lab-environment`'s own Loki Service has no external exposure at all.

- [ ] **Step 3: Write Promtail (Deployment, no Service needed — it only pushes outbound)**

```yaml
# vps_oracle/k3s/apps/mesh-observability/k8s/promtail.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: promtail
  namespace: mesh-observability
  labels:
    app: promtail
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: promtail
  template:
    metadata:
      labels:
        app: promtail
    spec:
      enableServiceLinks: false
      containers:
        - name: promtail
          image: grafana/promtail:3.1.0
          args:
            - -config.file=/etc/promtail/promtail-config.yml
          env:
            - name: TZ
              value: "Asia/Hong_Kong"
          volumeMounts:
            - name: config
              mountPath: /etc/promtail/promtail-config.yml
              subPath: promtail-config.yml
            - name: pod-logs
              mountPath: /var/log/pods
              readOnly: true
          resources:
            requests:
              cpu: 25m
              memory: 32Mi
            limits:
              cpu: 50m
              memory: 64Mi
      volumes:
        - name: config
          configMap:
            name: promtail-config
        - name: pod-logs
          hostPath:
            path: /var/log/pods
            type: Directory
```

`replicas: 1`, same reasoning as Step 2.

- [ ] **Step 4: Validate YAML and commit**

```bash
python3 -c "
import yaml
for f in ['vps_oracle/k3s/apps/mesh-observability/k8s/configmaps.yaml',
          'vps_oracle/k3s/apps/mesh-observability/k8s/loki.yaml',
          'vps_oracle/k3s/apps/mesh-observability/k8s/promtail.yaml']:
    list(yaml.safe_load_all(open(f)))
" && echo OK
git add vps_oracle/k3s/apps/mesh-observability/k8s/configmaps.yaml \
  vps_oracle/k3s/apps/mesh-observability/k8s/loki.yaml \
  vps_oracle/k3s/apps/mesh-observability/k8s/promtail.yaml
git commit -m "Add Loki and a pr-lanes-scoped Promtail to mesh-observability

Same pinned images/resource specs already validated running in
lab-environment, but replicas: 1 (always on, not the off-by-default
lab-environment pattern) and scoped to only read pr-lanes pod logs.
Loki's Service is NodePort — compose's Grafana queries it directly."
git push
```

- [ ] **Step 5: Verify both pods come up and Loki is reachable in-cluster**

```bash
kubectl -n mesh-observability get pods -o wide
kubectl -n mesh-observability logs deploy/promtail --tail=30
kubectl -n mesh-observability run curl-loki-check --rm -i --restart=Never --image=curlimages/curl:8.11.1 -- \
  curl -s -o /dev/null -w '%{http_code}\n' http://loki:3100/ready
```

Expected: both `loki` and `promtail` pods `Running`, `1/1`. Promtail's log shows it opened the `pr-lanes` glob without error (no `too many open files`/inotify errors — if this cluster ever needs more than the `fs.inotify.max_user_instances` headroom `lab-environment`'s README documents running into, that's the thing to check first). The in-cluster `curl` to Loki's `/ready` endpoint returns `200`.

- [ ] **Step 6: Confirm quota usage and generate a log line to confirm end-to-end ingestion**

```bash
kubectl -n mesh-observability describe resourcequota mesh-observability-quota
kubectl -n pr-lanes get pod -l app=hello-frontend -o jsonpath='{.items[0].metadata.name}'
FRONTEND_POD=$(kubectl -n pr-lanes get pod -l app=hello-frontend -o jsonpath='{.items[0].metadata.name}')
kubectl -n pr-lanes exec "$FRONTEND_POD" -- curl -s -o /dev/null http://hello-backend.pr-lanes.svc.cluster.local/
sleep 15
kubectl -n mesh-observability run curl-loki-query --rm -i --restart=Never --image=curlimages/curl:8.11.1 -- \
  curl -s "http://loki:3100/loki/api/v1/query_range?query=%7Bnamespace%3D%22pr-lanes%22%7D&limit=5"
```

Expected: quota shows Loki + Promtail's combined usage, within the hard limits from Task 1. The Loki query returns at least one log entry from the last 15 seconds (waypoint's access log for the request just made, or one of the app pods' own stdout — either confirms the pipeline is flowing end-to-end).

---

### Task 3: Jaeger + Istio tracing configuration (trace pipeline)

**Files:**
- Create: `vps_oracle/k3s/apps/mesh-observability/k8s/jaeger.yaml`
- Modify: `vps_oracle/k3s/istio/istiod-values.yaml`
- Create: `vps_oracle/k3s/apps/hello/k8s/pr-lanes-telemetry.yaml`

**Interfaces:**
- Consumes: `mesh-observability` namespace (Task 1).
- Produces: `jaeger.mesh-observability.svc.cluster.local:9411` (Zipkin ingest, ClusterIP, consumed by istiod's `extensionProviders` config in this same task) and a `jaeger-query` NodePort at `30114` (Task 6 consumes this for Grafana's datasource).

- [ ] **Step 1: Write Jaeger — two Services, not one (Zipkin ingest stays ClusterIP-only)**

```yaml
# vps_oracle/k3s/apps/mesh-observability/k8s/jaeger.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: jaeger
  namespace: mesh-observability
  labels:
    app: jaeger
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: jaeger
  template:
    metadata:
      labels:
        app: jaeger
    spec:
      enableServiceLinks: false
      containers:
        - name: jaeger
          image: jaegertracing/all-in-one:1.60
          env:
            - name: TZ
              value: "Asia/Hong_Kong"
            - name: COLLECTOR_ZIPKIN_HOST_PORT
              value: ":9411"
            # Same reasoning as lab-environment's jaeger.yaml: the default
            # all-in-one in-memory store keeps every trace forever with no
            # eviction. Bound it instead of chasing the memory limit.
            - name: SPAN_STORAGE_TYPE
              value: "memory"
            - name: MEMORY_MAX_TRACES
              value: "5000"
          ports:
            - containerPort: 16686
              name: ui
            - containerPort: 9411
              name: zipkin
          resources:
            requests:
              cpu: 25m
              memory: 64Mi
            limits:
              cpu: 100m
              memory: 256Mi
---
# Zipkin span ingest — in-cluster only, Envoy sends spans here directly.
# Never exposed via NodePort: nothing outside the cluster needs to reach it,
# and it must not cross the k3s->compose boundary this plan avoids entirely.
apiVersion: v1
kind: Service
metadata:
  name: jaeger
  namespace: mesh-observability
spec:
  type: ClusterIP
  selector:
    app: jaeger
  ports:
    - port: 9411
      targetPort: 9411
      name: zipkin
---
# Query UI/API — this is what compose's Grafana talks to, over NodePort.
apiVersion: v1
kind: Service
metadata:
  name: jaeger-query
  namespace: mesh-observability
spec:
  type: NodePort
  selector:
    app: jaeger
  ports:
    - port: 16686
      targetPort: 16686
      nodePort: 30114
      name: ui
```

This deviates from `lab-environment/k8s/jaeger.yaml`, which exposes both ports on one `NodePort`-type Service — here the two ports have genuinely different audiences (in-cluster Envoy vs. external Grafana), so they're split into two Services, one `ClusterIP` and one `NodePort`. `replicas: 1`, same reasoning as Task 2.

- [ ] **Step 2: Add the Zipkin extension provider to istiod's Helm values**

Read the current file first:

```bash
cat vps_oracle/k3s/istio/istiod-values.yaml
```

Add `extensionProviders` under the existing `meshConfig:` key (do not create a second `meshConfig:` key — merge into the one that already has `accessLogFile`):

```yaml
# vps_oracle/k3s/istio/istiod-values.yaml
profile: ambient

# Startup sizing, not a claim about steady state: this mesh has a
# handful of pods (hello-frontend/hello-backend/waypoint + per-PR-lane
# pods), nowhere near the ~100-pod baseline the upstream "small
# cluster" guidance (500m/512Mi requests) assumes. Revisit if istiod
# gets OOMKilled — see the resource budget table in the phase F+G
# design doc.
resources:
  requests:
    cpu: 100m
    memory: 256Mi
  limits:
    cpu: 500m
    memory: 512Mi

meshConfig:
  # Only pr-lanes opts into ambient (namespace label, Task 4) — this
  # doesn't change that, it's istiod's own default proxy behavior for
  # any namespace that DOES opt in. Left at chart default deliberately:
  # no sidecar injection anywhere, ambient is fully sidecar-free.
  accessLogFile: /dev/stdout
  # Phase K: lets pr-lanes' Telemetry CR (see
  # vps_oracle/k3s/apps/hello/k8s/pr-lanes-telemetry.yaml) send Envoy spans
  # to mesh-observability's Jaeger over its Zipkin-compatible ingest port —
  # in-cluster ClusterIP call, never crosses the k3s<->compose boundary.
  extensionProviders:
    - name: zipkin-mesh-observability
      zipkin:
        service: jaeger.mesh-observability.svc.cluster.local
        port: 9411

global:
  waypoint:
    # Chart default (2 CPU / 1Gi limit) blows pr-lanes-quota's
    # limits.cpu: 1200m cap on its own -- a single waypoint pod alone
    # exceeded the whole namespace's budget (Task 7 discovered this via
    # repeated FailedCreate/exceeded-quota events on the waypoint
    # Deployment's ReplicaSet). This is the design doc's own stated
    # waypoint budget (phase F+G design, 元件與設定 table), just never
    # actually wired in anywhere until now. Do not raise pr-lanes-quota
    # instead -- it's deliberately sized around this exact budget,
    # including its ~8-concurrent-PR-lane capacity math.
    resources:
      requests:
        cpu: 50m
        memory: 128Mi
      limits:
        cpu: 200m
        memory: 256Mi
```

Only the `extensionProviders:` block (and its comment) under `meshConfig:` is new — everything else in the file is unchanged.

- [ ] **Step 3: Write the `Telemetry` CR enabling tracing in `pr-lanes`**

```yaml
# vps_oracle/k3s/apps/hello/k8s/pr-lanes-telemetry.yaml
apiVersion: telemetry.istio.io/v1
kind: Telemetry
metadata:
  name: mesh-tracing
  namespace: pr-lanes
spec:
  tracing:
    - providers:
        - name: zipkin-mesh-observability
      randomSamplingPercentage: 100.0
```

`100.0` is deliberate, not a placeholder — see Global Constraints.

- [ ] **Step 4: Validate YAML and commit**

```bash
python3 -c "
import yaml
for f in ['vps_oracle/k3s/apps/mesh-observability/k8s/jaeger.yaml',
          'vps_oracle/k3s/istio/istiod-values.yaml',
          'vps_oracle/k3s/apps/hello/k8s/pr-lanes-telemetry.yaml']:
    list(yaml.safe_load_all(open(f)))
" && echo OK
git add vps_oracle/k3s/apps/mesh-observability/k8s/jaeger.yaml \
  vps_oracle/k3s/istio/istiod-values.yaml \
  vps_oracle/k3s/apps/hello/k8s/pr-lanes-telemetry.yaml
git commit -m "Wire pr-lanes Envoy tracing into mesh-observability's Jaeger

istiod gets a zipkin extensionProvider pointed at Jaeger's in-cluster
Zipkin ingest port; a Telemetry CR in pr-lanes turns tracing on at
100% sampling (no real traffic in this namespace, so no cost concern
— see the design doc). Jaeger's query UI is a separate NodePort
Service, its Zipkin ingest stays ClusterIP-only."
git push
```

- [ ] **Step 5: Verify Jaeger is running and istiod picked up the new provider**

```bash
kubectl -n mesh-observability get pods -l app=jaeger
kubectl -n argocd get application istio-istiod -o custom-columns=SYNC:.status.sync.status,HEALTH:.status.health.status
kubectl -n istio-system get cm istio -o jsonpath='{.data.mesh}' | grep -A5 extensionProviders
kubectl -n pr-lanes get telemetry mesh-tracing -o yaml
```

Expected: `jaeger` pod `Running`, `1/1`. `istio-istiod` Application `Synced`/`Healthy` (a Helm-values-only change still triggers a normal sync). The rendered `istio` ConfigMap's `mesh` data shows the `zipkin-mesh-observability` provider. The `Telemetry` object exists with the exact spec from Step 3.

- [ ] **Step 6: Generate a request and confirm a trace lands in Jaeger**

```bash
FRONTEND_POD=$(kubectl -n pr-lanes get pod -l app=hello-frontend -o jsonpath='{.items[0].metadata.name}')
for i in $(seq 1 5); do
  kubectl -n pr-lanes exec "$FRONTEND_POD" -- curl -s -o /dev/null http://hello-backend.pr-lanes.svc.cluster.local/
done
sleep 10
kubectl -n mesh-observability run curl-jaeger-check --rm -i --restart=Never --image=curlimages/curl:8.11.1 -- \
  curl -s "http://jaeger-query:16686/api/services"
```

Expected: the services list includes an entry for the waypoint/mesh traffic (exact service name depends on how Envoy tags spans — note whatever name actually shows up here in Task 7's findings, don't assume a specific string in advance). If the list is empty after 5 requests, re-check Step 5's `extensionProviders` output landed and the `Telemetry` CR's `providers[].name` spells `zipkin-mesh-observability` identically in both files — a mismatch here silently produces zero spans, not an error.

---

### Task 4: Metrics NodePort Services (istiod, ztunnel, waypoint)

**Files:**
- Create: `vps_oracle/k3s/apps/mesh-observability/k8s/istiod-metrics-service.yaml`
- Create: `vps_oracle/k3s/apps/mesh-observability/k8s/ztunnel-metrics-service.yaml`
- Create: `vps_oracle/k3s/apps/hello/k8s/waypoint-metrics-service.yaml`

**Interfaces:**
- Consumes: `mesh-observability` namespace (Task 1) for the first two files; the existing `hello` Application (already syncing `vps_oracle/k3s/apps/hello/k8s/`, confirmed in Phase J's plan) for the third.
- Produces: three NodePorts (`30110`, `30111`, `30112`) that Task 6's compose Prometheus scrape_configs consume. No new Deployments — every one of these Services exposes a port an existing pod already listens on.

- [ ] **Step 1: Confirm the exact ports and selectors before writing anything**

```bash
kubectl -n istio-system get svc istiod -o jsonpath='{.spec.ports}'; echo
kubectl -n istio-system get pod -l app=ztunnel -o jsonpath='{.items[0].spec.containers[*].ports}'; echo
kubectl -n pr-lanes get pod -l gateway.networking.k8s.io/gateway-name=waypoint -o jsonpath='{.items[0].spec.containers[*].ports}'; echo
```

Expected: istiod's existing Service lists `http-monitoring` on `15014`. ztunnel's pod shows `ztunnel-stats` on `15020`. The waypoint pod shows `metrics` (`15020`), `status-port` (`15021`), and `http-envoy-prom` (`15090`) — this plan uses `15090`. If any of these differ from what's written below (istiod/ztunnel/waypoint images or configs may have changed since this plan was written), update the Step 2/3 YAML to match reality, don't force these numbers.

- [ ] **Step 2: Write the istiod and ztunnel metrics Services**

```yaml
# vps_oracle/k3s/apps/mesh-observability/k8s/istiod-metrics-service.yaml
apiVersion: v1
kind: Service
metadata:
  name: istiod-metrics
  namespace: istio-system
spec:
  type: NodePort
  selector:
    app: istiod
    istio: pilot
  ports:
    - port: 15014
      targetPort: 15014
      nodePort: 30110
      name: http-monitoring
```

```yaml
# vps_oracle/k3s/apps/mesh-observability/k8s/ztunnel-metrics-service.yaml
apiVersion: v1
kind: Service
metadata:
  name: ztunnel-metrics
  namespace: istio-system
spec:
  type: NodePort
  selector:
    app: ztunnel
  ports:
    - port: 15020
      targetPort: 15020
      nodePort: 30111
      name: ztunnel-stats
```

Both live in `mesh-observability`'s directory with an explicit `metadata.namespace: istio-system` — see Global Constraints for why they can't go in `vps_oracle/k3s/istio/`.

- [ ] **Step 3: Write the waypoint metrics Service**

```yaml
# vps_oracle/k3s/apps/hello/k8s/waypoint-metrics-service.yaml
apiVersion: v1
kind: Service
metadata:
  name: waypoint-metrics
  namespace: pr-lanes
spec:
  type: NodePort
  selector:
    gateway.networking.k8s.io/gateway-name: waypoint
  ports:
    - port: 15090
      targetPort: 15090
      nodePort: 30112
      name: http-envoy-prom
```

The existing auto-generated `waypoint` Service (created by the `Gateway` resource) only forwards `15021`/`15008` — this is a separate, hand-written Service, not a modification of that one.

- [ ] **Step 4: Validate YAML and commit**

```bash
python3 -c "
import yaml
for f in ['vps_oracle/k3s/apps/mesh-observability/k8s/istiod-metrics-service.yaml',
          'vps_oracle/k3s/apps/mesh-observability/k8s/ztunnel-metrics-service.yaml',
          'vps_oracle/k3s/apps/hello/k8s/waypoint-metrics-service.yaml']:
    yaml.safe_load(open(f))
" && echo OK
git add vps_oracle/k3s/apps/mesh-observability/k8s/istiod-metrics-service.yaml \
  vps_oracle/k3s/apps/mesh-observability/k8s/ztunnel-metrics-service.yaml \
  vps_oracle/k3s/apps/hello/k8s/waypoint-metrics-service.yaml
git commit -m "Expose istiod/ztunnel/waypoint Prometheus endpoints via NodePort

Zero new Deployments — each Service just exposes a port the pod
already listens on. istiod/ztunnel Services live in
mesh-observability's directory (istio-istiod/istio-ztunnel are
remote-Helm-chart Applications, not plain-manifest ones — see the
plan's Global Constraints) with an explicit istio-system namespace."
git push
```

- [ ] **Step 5: Verify all three Services exist with real endpoints**

```bash
kubectl -n istio-system get svc istiod-metrics ztunnel-metrics -o wide
kubectl -n pr-lanes get svc waypoint-metrics -o wide
kubectl -n istio-system get endpoints istiod-metrics ztunnel-metrics
kubectl -n pr-lanes get endpoints waypoint-metrics
```

Expected: all three Services show `NodePort` type with the exact node ports from Global Constraints. Every `endpoints` output lists at least one real pod IP:port — an empty endpoints list means the selector doesn't match anything (re-check Step 1's live label/port output against what got written).

- [ ] **Step 6: Verify each metrics endpoint actually serves Prometheus-format output, from inside the cluster**

```bash
kubectl -n mesh-observability run curl-metrics-check --rm -i --restart=Never --image=curlimages/curl:8.11.1 -- sh -c '
  echo "--- istiod ---"; curl -s http://istiod-metrics.istio-system.svc.cluster.local:15014/metrics | head -3
  echo "--- ztunnel ---"; curl -s http://ztunnel-metrics.istio-system.svc.cluster.local:15020/metrics | head -3
  echo "--- waypoint ---"; curl -s http://waypoint-metrics.pr-lanes.svc.cluster.local:15090/stats/prometheus | head -3
'
```

Expected: each section prints Prometheus exposition-format lines (`# HELP ...` / `# TYPE ...` followed by metric samples), not an error or empty output. This confirms the port numbers in Step 1 were correct before Task 6 spends any effort wiring compose to them.

---

### Task 5: Fix compose `prometheus`/`grafana` docker network gateway priority

**Files:**
- Modify: `vps_oracle/compose/monitoring/docker-compose.yml`

**Interfaces:**
- Consumes: nothing from another task — this is a standalone prerequisite, testable against an *existing* NodePort (`headlamp`, `30098`), not one this plan created.
- Produces: compose `prometheus`/`grafana` containers whose default gateway is the `proxy` network. Task 6 depends on this — without it, the new scrape_configs/datasources this plan adds will all show as down, for a reason that looks unrelated (see the incident doc).

- [ ] **Step 1: Confirm the current broken state (don't skip this — it's the baseline Step 4 compares against)**

```bash
docker exec prometheus wget -T4 -qO- http://10.0.0.95:30098 2>&1
docker inspect prometheus --format '{{.NetworkSettings.Networks.monitoring_default.Gateway}}'
```

Expected: `wget: can't connect to remote host (10.0.0.95): No route to host`, gateway shows `172.20.0.1` (the `monitoring_default` network, not `proxy`) — matches [the incident write-up](../../incidents/2026-08-24-compose-prometheus-grafana-k3s-nodeport-gateway.md) exactly.

- [ ] **Step 2: Read the current file and add `priority` to both services' `proxy` network entry**

```bash
cat vps_oracle/compose/monitoring/docker-compose.yml
```

`prometheus`'s `networks:` block (already long-form — add one line):

```yaml
    networks:
      default: {}
      proxy:
        ipv4_address: 172.19.0.4
        priority: 1
```

`grafana`'s `networks:` block (currently short-form list — must convert to long-form to carry `priority`):

```yaml
    networks:
      default: {}
      proxy:
        priority: 1
```

Every other line in the file (both services' `image`, `environment`, `volumes`, `logging`, etc., and the top-level `networks:` block at the bottom of the file) is unchanged.

- [ ] **Step 3: Apply and verify the fix**

```bash
cd vps_oracle/compose/monitoring
docker compose up -d
docker inspect prometheus --format '{{.NetworkSettings.Networks.proxy.GwPriority}}'
docker inspect grafana --format '{{.NetworkSettings.Networks.proxy.GwPriority}}'
docker exec prometheus wget -T4 -qO- http://10.0.0.95:30098 2>&1 | head -c 200; echo
docker exec grafana wget -T4 -qO- http://10.0.0.95:30098 2>&1 | head -c 200; echo
```

Expected: both `GwPriority` values are `1`. Both `wget` calls now return HTML content (headlamp's index page), not `No route to host` — this is the same known-good NodePort used in Step 1, now reachable.

- [ ] **Step 4: Commit**

```bash
cd /home/ubuntu/jerome/docker-gitops
git status
git add vps_oracle/compose/monitoring/docker-compose.yml
git commit -m "Fix prometheus/grafana docker network gateway priority

Both containers are multi-homed (default + proxy) and Docker was
picking 'default' (monitoring_default, 172.20.0.0/16) as the actual
gateway instead of 'proxy' (172.19.0.0/16) -- the network
host-firewall.sh's k3s-NodePort allow rule is scoped to. Root cause
fully diagnosed in docs/incidents/2026-08-24-compose-prometheus-
grafana-k3s-nodeport-gateway.md. Without this, neither container can
reach any k3s NodePort, which Phase K's remaining tasks depend on."
git push
```

Compose changes apply via `docker compose up -d` (already done in Step 3), not via ArgoCD — this commit records the change in git per repo convention, it doesn't trigger anything by itself.

---

### Task 6: Wire compose Prometheus + Grafana to the new NodePorts

**Files:**
- Modify: `vps_oracle/compose/monitoring/prometheus/prometheus.yml`
- Create: `vps_oracle/compose/monitoring/grafana/provisioning/datasources/loki.yml`
- Create: `vps_oracle/compose/monitoring/grafana/provisioning/datasources/jaeger.yml`

**Interfaces:**
- Consumes: NodePorts `30110`/`30111`/`30112` (Task 4), `30113` (Task 2), `30114` (Task 3); the network fix (Task 5).
- Produces: nothing further tasks in this plan depend on — Task 7 is end-to-end verification.

- [ ] **Step 1: Read the current Prometheus config and add three scrape jobs**

```bash
cat vps_oracle/compose/monitoring/prometheus/prometheus.yml
```

Add these three jobs to the existing `scrape_configs:` list (after the existing `blackbox_tcp` job, matching the file's existing `static_configs` style — no service discovery used anywhere in this file):

```yaml
  - job_name: istiod
    static_configs:
      - targets: ['10.0.0.95:30110']

  - job_name: ztunnel
    static_configs:
      - targets: ['10.0.0.95:30111']

  - job_name: waypoint
    static_configs:
      - targets: ['10.0.0.95:30112']
```

Every existing job in the file (`node`, `prometheus`, `grafana`, `blackbox_exporter_self`, the three `blackbox_http_*` jobs, `blackbox_tcp`) is unchanged.

- [ ] **Step 2: Write the Loki and Jaeger Grafana datasources**

```yaml
# vps_oracle/compose/monitoring/grafana/provisioning/datasources/loki.yml
apiVersion: 1

datasources:
  - name: Loki
    type: loki
    access: proxy
    url: http://10.0.0.95:30113
    uid: loki
```

```yaml
# vps_oracle/compose/monitoring/grafana/provisioning/datasources/jaeger.yml
apiVersion: 1

datasources:
  - name: Jaeger
    type: jaeger
    access: proxy
    url: http://10.0.0.95:30114
    uid: jaeger
```

Matches the existing `prometheus.yml` datasource file's style exactly (`access: proxy`, lowercase `uid`) — that file is untouched, these are two new files alongside it in the same `datasources/` directory, picked up automatically by Grafana's existing dashboard-provisioning provider on container restart.

- [ ] **Step 3: Apply and validate the YAML**

```bash
python3 -c "
import yaml
for f in ['vps_oracle/compose/monitoring/prometheus/prometheus.yml',
          'vps_oracle/compose/monitoring/grafana/provisioning/datasources/loki.yml',
          'vps_oracle/compose/monitoring/grafana/provisioning/datasources/jaeger.yml']:
    yaml.safe_load(open(f))
" && echo OK
cd vps_oracle/compose/monitoring
docker compose up -d
```

- [ ] **Step 4: Commit**

```bash
cd /home/ubuntu/jerome/docker-gitops
git status
git add vps_oracle/compose/monitoring/prometheus/prometheus.yml \
  vps_oracle/compose/monitoring/grafana/provisioning/datasources/loki.yml \
  vps_oracle/compose/monitoring/grafana/provisioning/datasources/jaeger.yml
git commit -m "Point compose Prometheus/Grafana at pr-lanes' new NodePorts

Three new Prometheus scrape jobs (istiod/ztunnel/waypoint) and two new
Grafana datasources (Loki, Jaeger), all targeting mesh-observability's
and the mesh's newly-exposed NodePorts. Depends on the network gateway
fix landing first."
git push
```

- [ ] **Step 5: Verify Prometheus targets are all UP**

```bash
curl -s http://172.19.0.4:9090/api/v1/targets | python3 -c "
import json, sys
data = json.load(sys.stdin)
for t in data['data']['activeTargets']:
    print(t['labels'].get('job'), t['health'])
"
```

Expected: `istiod up`, `ztunnel up`, `waypoint up`, alongside the pre-existing jobs (`node`, `prometheus`, `grafana`, `blackbox_*`) all still `up`. If any of the three new jobs shows `down`, check its `lastError` in the same JSON output before assuming the NodePort itself is broken — a `context deadline exceeded` here after Task 5's fix most likely means a genuinely different problem than the one Task 5 solved, not a regression of it.

- [ ] **Step 6: Verify Grafana can query both new datasources**

```bash
docker exec grafana wget -T4 -qO- http://10.0.0.95:30113/ready 2>&1 | head -c 100; echo
docker exec grafana wget -T4 -qO- http://10.0.0.95:30114/api/services 2>&1 | head -c 200; echo
```

Expected: both return real content (Loki's `ready` response, Jaeger's services JSON), confirming Grafana's own container — not just Prometheus's — can reach both new NodePorts. (Grafana's actual datasource connection test happens through its UI, exercised manually in Task 7 — this step is the automatable proxy for it.)

---

### Task 7: End-to-end verification, `lab-environment` non-interference check, and design doc update

**Files:**
- Modify: `docs/superpowers/specs/2026-08-24-k3s-phase-k-observability-design.md`

**Interfaces:**
- Consumes: everything from Tasks 1-6.
- Produces: nothing — this is the plan's final gate.

- [ ] **Step 1: Full resource quota and cluster health check**

```bash
kubectl -n pr-lanes describe resourcequota pr-lanes-quota
kubectl -n mesh-observability describe resourcequota mesh-observability-quota
kubectl get pods -A -o wide | grep -v Running
kubectl get applications -n argocd -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status | grep -v "Synced.*Healthy"
```

Expected: `pr-lanes-quota` identical to the Global Constraints baseline — confirms this plan added zero cost there. `mesh-observability-quota` shows Loki+Jaeger+Promtail's combined usage, within its own hard limits. Both `grep -v` commands print nothing — every pod cluster-wide `Running`, every Application `Synced`/`Healthy`.

- [ ] **Step 2: Confirm `lab-environment` was never touched**

```bash
git log --oneline --stat main -20 -- vps_oracle/k3s/apps/lab-environment/
kubectl -n lab-environment get deployments -o custom-columns=NAME:.metadata.name,REPLICAS:.spec.replicas
```

Expected: the `git log` shows no commits from this plan touching that path (the last entries should predate this plan's work). Every `lab-environment` Deployment still shows `REPLICAS: 0`.

- [ ] **Step 3: Full round-trip — generate real traffic, confirm it's visible in all three signals via compose's Grafana**

```bash
FRONTEND_POD=$(kubectl -n pr-lanes get pod -l app=hello-frontend -o jsonpath='{.items[0].metadata.name}')
for i in $(seq 1 10); do
  kubectl -n pr-lanes exec "$FRONTEND_POD" -- curl -s -o /dev/null http://hello-backend.pr-lanes.svc.cluster.local/
done
sleep 15
echo "--- metrics: waypoint request count from Prometheus ---"
curl -s 'http://172.19.0.4:9090/api/v1/query?query=up%7Bjob%3D%22waypoint%22%7D' | python3 -m json.tool
echo "--- logs: waypoint access log entries from Loki, last 1 minute ---"
kubectl -n mesh-observability run curl-final-loki --rm -i --restart=Never --image=curlimages/curl:8.11.1 -- \
  curl -s "http://loki:3100/loki/api/v1/query_range?query=%7Bnamespace%3D%22pr-lanes%22%7D&limit=5" | python3 -m json.tool
echo "--- traces: Jaeger service list ---"
kubectl -n mesh-observability run curl-final-jaeger --rm -i --restart=Never --image=curlimages/curl:8.11.1 -- \
  curl -s "http://jaeger-query:16686/api/services" | python3 -m json.tool
```

Expected: `up{job="waypoint"}` returns a value of `1`. The Loki query returns recent log lines. The Jaeger services list is non-empty. If the Jaeger list is still empty after this many requests across Tasks 3, 6, and 7 combined, that's a real finding to record in Step 4 below, not something to keep silently retrying.

- [ ] **Step 4: Record implementation findings back into the design doc**

Open [docs/superpowers/specs/2026-08-24-k3s-phase-k-observability-design.md](../specs/2026-08-24-k3s-phase-k-observability-design.md)'s "已知限制" section and add findings from this plan's execution:
- The actual Jaeger service name(s) that showed up for mesh traffic (Task 3 Step 6 / Task 7 Step 3), since the design doc didn't predict this in advance
- Whether Task 3's tracing worked on the first attempt or needed a fix (e.g. a provider-name mismatch) — if it needed a fix, note what the actual mismatch was, so a future reader doesn't have to re-derive it
- The final confirmed NodePort assignments if any differed from the Global Constraints table (e.g. a last-minute collision found in Task 1 Step 1 that forced different numbers)

```bash
git add docs/superpowers/specs/2026-08-24-k3s-phase-k-observability-design.md
git commit -m "Record Phase K implementation findings in the design doc

Closes the open items in 已知限制 about actual Jaeger service naming
and whether the tracing wiring worked on the first attempt."
git push
```

- [ ] **Step 5: Final check — confirm this plan's file list matches what actually landed**

```bash
git log --oneline --stat -8 -- vps_oracle/k3s/apps/mesh-observability/ vps_oracle/k3s/argocd/apps/mesh-observability.yaml vps_oracle/k3s/istio/istiod-values.yaml vps_oracle/k3s/apps/hello/k8s/waypoint-metrics-service.yaml vps_oracle/k3s/apps/hello/k8s/pr-lanes-telemetry.yaml vps_oracle/compose/monitoring/
```

Expected: commits from Tasks 1-7, touching exactly the files listed across this plan's Files sections — `mesh-observability/k8s/` (namespace, configmaps, loki, promtail, jaeger, istiod-metrics-service, ztunnel-metrics-service), `argocd/apps/mesh-observability.yaml`, `istio/istiod-values.yaml` (modified), `hello/k8s/waypoint-metrics-service.yaml`, `hello/k8s/pr-lanes-telemetry.yaml`, and the three `compose/monitoring/` files. No other file touched — confirms the plan stayed inside its stated scope, and in particular that nothing under `vps_oracle/k3s/apps/lab-environment/` appears anywhere in this list.

---

## Self-Review Notes

- **Spec coverage:** every item in the design doc's 驗證清單 maps to a task here — item 1 (namespace/Application/pods) is Task 1 Step 5 + Task 2/3 Step 5; item 2 (quota isolation) is Task 1 Step 5 and Task 7 Step 1; item 3 (network fix minimal check) is Task 5 Step 3; item 4 (Prometheus targets UP) is Task 6 Step 5; item 5 (Grafana datasource connectivity) is Task 6 Step 6; item 6 (metrics/logs/traces visible for real traffic) is Task 7 Step 3; item 7 (`lab-environment` unchanged) is Task 7 Step 2; item 8 (all Applications healthy) is Task 7 Step 1. The design doc's "元件與設定" table row for the network-priority fix maps directly to Task 5; the istiod/ztunnel/waypoint metrics row maps to Task 4; the Istio tracing row maps to Task 3.
- **Placeholder scan:** no TBD/TODO. Task 3 Step 6 and Task 7 Step 3 explicitly instruct recording the *actual* observed Jaeger service name rather than assuming one in advance — that's an honestly-framed unknown with a concrete resolution step (Task 7 Step 4), not a placeholder.
- **Type/name consistency:** `zipkin-mesh-observability` (the extensionProvider name) is spelled identically in Task 3 Step 2 (`istiod-values.yaml`) and Step 3 (`pr-lanes-telemetry.yaml`'s `providers[].name`) — a mismatch here is called out explicitly in Task 3 Step 6 as the most likely failure mode. NodePort numbers (`30110`-`30114`) are consistent across Global Constraints, Task 4's two Services, Task 2/3's Loki/Jaeger Services, and Task 6's Prometheus/Grafana config. Service/selector names (`istiod-metrics`, `ztunnel-metrics`, `waypoint-metrics`, `loki`, `jaeger`, `jaeger-query`) match between each Task 2-4 creation step and Task 6/7's consuming steps. `mesh-observability-quota`'s hard limits in Task 1 Step 2 match the combined Loki/Jaeger/Promtail resource requests/limits written in Task 2/3.
