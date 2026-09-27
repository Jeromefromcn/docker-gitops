# Lab Demo Runbook Framework (Sub-project 2a) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `docs/demo/` — a runbook of eight live-demoable lab scenarios backed by helpers that bound every scenario in its own time window, collect infrastructure-layer evidence, and reset + verify — plus the shared kube-state-metrics and lab capacity alerts the scenarios rely on.

**Architecture:** One cluster-wide kube-state-metrics (ArgoCD Helm app, pinned to vps_oracle) feeds the lab Prometheus, which also scrapes cAdvisor through the API server; lab Grafana gets five provisioned capacity alerts. Three bash helpers (`demo-window`, `demo-evidence`, `demo-reset`) share `lib.sh` and source one `scenarios/<name>.sh` per scenario, which defines `start_*` / `evidence_*` / `reset_*` functions. Runbook pages hold the verbatim `kubectl`/`git`/`curl` main actions and one helper call per bookkeeping step.

**Tech Stack:** bash + jq + curl, kubectl, `argocd --core`, kubeseal, Prometheus / Loki (via Grafana's datasource proxy) / Jaeger HTTP APIs, Grafana 11.1 alert provisioning, kube-state-metrics Helm chart 8.6.0, k6 2.3.0 (Docker image).

**Spec:** `docs/superpowers/specs/2026-09-27-lab-demo-runbook-framework-design.md`

## Global Constraints

- Work happens in the main checkout on `main` (the demo flows being built are main-branch GitOps flows — approving this plan is the instruction to commit to `main`). Before every commit: `git pull --rebase --autostash`; add explicit paths only, never `git add -A` (other sessions commit in this checkout).
- **Stop point:** every `git push` that changes anything under `k3s/` is a deploy that recreates containers — get the user's confirmation before each one (project CLAUDE.md). Pure docs/helper pushes need no confirmation.
- Demo commits use the subject prefix `demo:` exactly as written in the runbook; they go to `main`, no demo branch, no targetRevision switching.
- Capacity alerts have **no contact point** — lab Grafana only.
- kube-state-metrics: namespace `kube-system`, `nodeSelector: kubernetes.io/hostname: instance-20260321-2043` (vps_oracle), NodePort **30115**, chart `prometheus-community/kube-state-metrics` **8.6.0**.
- Load generator runs on vps_oracle only (`docker run --network host grafana/k6:2.3.0`), never on vps-oracle2.
- Every `demo-evidence` must pass with **≥ 2 pieces and ≥ 1 from an infrastructure layer** (`envoy ztunnel argocd kyverno sealed-secrets cadvisor kubernetes`); any failed piece fails the run.
- Scenario resets verify in the same command; baseline = all Consul `chaos/` keys `false`, business Deployments ready at git's replica count, `lab-environment` `Synced/Healthy`, generator all-200 over the last 30 s.
- Never commit a plaintext password; the new DB password lives only in a shell variable and the SealedSecret.
- Commit messages, code comments and runbook text: English. Commit trailer: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Any subPath-mounted ConfigMap change bumps that Deployment's `lab.jerome/config-rev` (prometheus, grafana).

## Review Focus

1. **Another commit lands on `main` between a scenario's push and its evidence run** — evidence must still pass, because ArgoCD checks look for the demo SHA in the history deployed inside the window rather than comparing the live revision. Pinned by Task 13 Step 3 (re-run 02's evidence after 07's revert has landed).
2. **A lab endpoint (Prometheus/Grafana/Consul/Jaeger) is unreachable** — `demo-evidence` must exit non-zero with an "aborted" message, never print `== OK`. Pinned by Task 4 test `query failure aborts`.
3. **A scenario is re-run in the same session** — `demo-window start` must replace the old window (no stale `WINDOW_END`). Pinned by Task 4 test `restart clears end`.
4. **A chaos toggle left on for a service other than the one being reset** — `demo-reset` must still fail. Pinned by Task 4 test `reset fails on any chaos key` (uses a customers key while resetting an unrelated scenario).
5. **Evidence collected before `demo-window stop`** — must refuse (exit 2) instead of querying an open-ended window. Pinned by Task 4 test `evidence refuses open window`.

---

### Task 1: Shared kube-state-metrics

**Files:**
- Create: `k3s/argocd/apps/kube-state-metrics.yaml`
- Create: `k3s/kube-state-metrics/values.yaml`
- Create: `k3s/kube-state-metrics/README.md`

**Interfaces:**
- Produces: Service `kube-system/kube-state-metrics` port 8080 (ClusterIP DNS `kube-state-metrics.kube-system.svc:8080`), NodePort 30115 on every node. Metrics used later: `kube_pod_status_phase`, `kube_resourcequota`, `kube_pod_container_status_restarts_total`, `kube_pod_container_status_last_terminated_reason`.

- [ ] **Step 1: Confirm the NodePort is free**

Run: `kubectl get svc -A -o jsonpath='{range .items[*]}{.spec.ports[*].nodePort}{" "}{end}' | tr ' ' '\n' | grep -x 30115 || echo free`
Expected: `free`

- [ ] **Step 2: Write the values file**

`k3s/kube-state-metrics/values.yaml`:
```yaml
fullnameOverride: kube-state-metrics

# vps_oracle, not vps-oracle2: oracle2's CPU requests are the lab's next
# ceiling, and a metrics source should not share a failure domain with the
# chaos node it reports on.
nodeSelector:
  kubernetes.io/hostname: instance-20260321-2043

# 30115 is reserved for the vps_oracle compose Prometheus. It is not wired
# yet: that container is on a Docker bridge and needs an npm-nodeport-relay
# instance first (roadmap follow-up "Production monitoring consumes KSM").
service:
  type: NodePort
  nodePort: 30115

resources:
  requests:
    cpu: 10m
    memory: 48Mi
  limits:
    cpu: 100m
    memory: 128Mi
```

- [ ] **Step 3: Write the ArgoCD Application**

`k3s/argocd/apps/kube-state-metrics.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kube-state-metrics
  namespace: argocd
spec:
  project: default
  sources:
    - repoURL: https://prometheus-community.github.io/helm-charts
      chart: kube-state-metrics
      targetRevision: "8.6.0"
      helm:
        releaseName: kube-state-metrics
        valueFiles:
          - $values/k3s/kube-state-metrics/values.yaml
    - repoURL: https://github.com/Jeromefromcn/docker-gitops.git
      targetRevision: main
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: kube-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

- [ ] **Step 4: Write the README**

`k3s/kube-state-metrics/README.md`:
```markdown
# kube-state-metrics

One cluster-wide instance (Helm chart `prometheus-community/kube-state-metrics`,
values here, Application `k3s/argocd/apps/kube-state-metrics.yaml`), shared by
every Prometheus that needs Kubernetes object state. KSM is a per-cluster
singleton by convention: running one per consumer only multiplies API-server
watches for the same data.

- **Placement:** pinned to vps_oracle (`instance-20260321-2043`). vps-oracle2's
  CPU requests are the lab's ceiling, and KSM should keep reporting when the
  chaos node is the thing that broke.
- **Consumers:**
  - lab Prometheus (`k3s/apps/lab-environment/`) — scrapes
    `kube-state-metrics.kube-system.svc:8080` and keeps only
    `namespace="lab-environment"`.
  - vps_oracle compose Prometheus — **not wired yet.** NodePort 30115 is
    reserved for it; it needs an `npm-nodeport-relay` instance first
    (`vps_oracle/host-native/npm-nodeport-relay/README.md`).
- **Check:** `curl -s http://10.0.0.95:30115/metrics | grep -c '^kube_pod_info'`
```

- [ ] **Step 5: Render locally to catch value typos**

Run: `helm template ksm kube-state-metrics --repo https://prometheus-community.github.io/helm-charts --version 8.6.0 -f k3s/kube-state-metrics/values.yaml | grep -E 'nodePort: 30115|kubernetes.io/hostname: instance-20260321-2043'`
Expected: both lines printed. (Use `--repo` — do not `helm repo add`; the helm repo list is a tracked dotfile under `vps_oracle/dotfiles/`.)

- [ ] **Step 6: Commit, then STOP for confirmation and push**

```bash
git pull --rebase --autostash
git add k3s/argocd/apps/kube-state-metrics.yaml k3s/kube-state-metrics/
git commit -m "feat(k3s): add a shared cluster-wide kube-state-metrics

One instance on vps_oracle, consumed by the lab Prometheus now and
reserved (NodePort 30115) for the compose Prometheus later.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
Ask the user to confirm, then `git push`.

- [ ] **Step 7: Verify live**

```bash
argocd app get root --core --refresh >/dev/null; sleep 60
argocd app get kube-state-metrics --core -o json | jq -r '.status.sync.status+"/"+.status.health.status'
kubectl -n kube-system get pod -l app.kubernetes.io/name=kube-state-metrics -o wide
curl -s http://10.0.0.95:30115/metrics | grep -c '^kube_resourcequota{.*namespace="lab-environment"'
```
Expected: `Synced/Healthy`; pod Running on `instance-20260321-2043`; count ≥ 4.

---

### Task 2: Lab Prometheus scrapes kube-state-metrics and cAdvisor

**Files:**
- Modify: `k3s/apps/lab-environment/k8s/configmaps.yaml` (append two jobs to `prometheus.yml`)
- Modify: `k3s/apps/lab-environment/k8s/prometheus.yaml` (ClusterRole + binding; `lab.jerome/config-rev` "2" → "3")
- Modify: `k3s/apps/lab-environment/README.md` (isolation wording)

**Interfaces:**
- Consumes: Task 1's `kube-state-metrics.kube-system.svc:8080`.
- Produces: in the lab Prometheus — KSM series (label `namespace="lab-environment"` only); cAdvisor series `container_cpu_cfs_throttled_periods_total`, `container_cpu_cfs_periods_total`, `container_cpu_usage_seconds_total`, `container_memory_working_set_bytes` for lab containers plus root cgroup `id="/"`, each with a `node` label.

- [ ] **Step 1: Append the two scrape jobs**

At the end of `prometheus.yml` in `configmaps.yaml` (after the `envoy-stats` job, same indentation):
```yaml
      # Kubernetes object state from the shared cluster-wide KSM
      # (k3s/kube-state-metrics/). Only this namespace's series are kept:
      # the isolation that matters is the alert pipeline, not the source.
      - job_name: kube-state-metrics
        static_configs:
          - targets: ["kube-state-metrics.kube-system.svc:8080"]
        metric_relabel_configs:
          - source_labels: [namespace]
            action: keep
            regex: lab-environment

      # cAdvisor through the API server's node proxy (no kubelet port
      # exposure needed). Keeps lab containers plus each node's root cgroup
      # (id="/"), which is where node-level CPU saturation is read from.
      - job_name: kubelet-cadvisor
        scheme: https
        tls_config:
          ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
        authorization:
          credentials_file: /var/run/secrets/kubernetes.io/serviceaccount/token
        kubernetes_sd_configs:
          - role: node
        relabel_configs:
          - target_label: __address__
            replacement: kubernetes.default.svc:443
          - source_labels: [__meta_kubernetes_node_name]
            regex: (.+)
            target_label: __metrics_path__
            replacement: /api/v1/nodes/$1/proxy/metrics/cadvisor
          - source_labels: [__meta_kubernetes_node_name]
            target_label: node
        metric_relabel_configs:
          - source_labels: [__name__]
            action: keep
            regex: container_cpu_cfs_throttled_periods_total|container_cpu_cfs_periods_total|container_cpu_usage_seconds_total|container_memory_working_set_bytes
          - source_labels: [namespace, id]
            separator: ";"
            action: keep
            regex: "lab-environment;.*|;/"
```

- [ ] **Step 2: Add the RBAC and bump config-rev**

In `prometheus.yaml`, after the `prometheus-discovery` RoleBinding:
```yaml
---
# Cluster-scoped because nodes are: node discovery for the cAdvisor job and
# read-only access to each kubelet's /metrics/cadvisor via the API server.
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: lab-prometheus-cadvisor
rules:
  - apiGroups: [""]
    resources: ["nodes"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["nodes/proxy"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: lab-prometheus-cadvisor
subjects:
  - kind: ServiceAccount
    name: prometheus
    namespace: lab-environment
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: lab-prometheus-cadvisor
```
Change `lab.jerome/config-rev: "2"` to `"3"`.

- [ ] **Step 3: Validate the config offline**

```bash
python3 -c "import yaml;d=[x for x in yaml.safe_load_all(open('k3s/apps/lab-environment/k8s/configmaps.yaml')) if x and x['metadata']['name']=='prometheus-config'][0];open('/tmp/claude-1001/prom.yml','w').write(d['data']['prometheus.yml'])"
docker run --rm -v /tmp/claude-1001/prom.yml:/p.yml --entrypoint promtool prom/prometheus:v2.53.0 check config /p.yml
```
Expected: `SUCCESS`, or failures that name only `/var/run/secrets/kubernetes.io/serviceaccount/...` (those files exist only in-cluster). Any YAML, relabel-regex or unknown-field error is a real failure.

- [ ] **Step 4: Rewrite the README's isolation sentence**

In `k3s/apps/lab-environment/README.md`, replace "no cross-namespace scraping." in the opening paragraph with:
```markdown
no cross-namespace *alerting*. It does read two shared, read-only sources
— the cluster-wide kube-state-metrics (`k3s/kube-state-metrics/`, filtered
to this namespace) and cAdvisor through the API server — because sharing a
metrics source does not put chaos drills into the real alert pipeline.
```

- [ ] **Step 5: Commit, STOP for confirmation, push**

```bash
git pull --rebase --autostash
git add k3s/apps/lab-environment/k8s/configmaps.yaml k3s/apps/lab-environment/k8s/prometheus.yaml k3s/apps/lab-environment/README.md
git commit -m "feat(lab-environment): scrape kube-state-metrics and cAdvisor

Pending pods, restarts, OOMKills and CPU throttling were invisible to
the lab Prometheus; these are the signals its capacity alerts need.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 6: Verify live (wait ~60 s after the prometheus pod restarts)**

```bash
P=http://10.0.0.95:30093/api/v1
curl -s $P/targets | jq -r '.data.activeTargets[] | select(.labels.job|test("kube-state|cadvisor")) | "\(.labels.job) \(.health) \(.lastError)"'
curl -s -G $P/query --data-urlencode 'query=count(kube_pod_info)' | jq -r '.data.result[0].value[1]'
curl -s -G $P/query --data-urlencode 'query=count by (namespace) (kube_pod_info)' | jq -r '.data.result[].metric.namespace'
curl -s -G $P/query --data-urlencode 'query=sum by (node) (rate(container_cpu_usage_seconds_total{id="/"}[2m]))' | jq -r '.data.result[] | "\(.metric.node) \(.value[1])"'
curl -s -G $P/query --data-urlencode 'query=count(container_cpu_cfs_periods_total{namespace="lab-environment"})' | jq -r '.data.result[0].value[1]'
```
Expected: 3 targets `up` (1 KSM, 2 cAdvisor nodes) with empty lastError; pod count ≈ number of lab pods; the only namespace is `lab-environment`; two nodes with CPU values; a non-zero container count.

---

### Task 3: Lab capacity alerts and dashboard row

**Files:**
- Modify: `k3s/apps/lab-environment/k8s/configmaps.yaml` (`grafana-provisioning`: add `alerting.yml`)
- Modify: `k3s/apps/lab-environment/k8s/grafana.yaml` (mount it; config-rev "1" → "2")
- Modify: `k3s/apps/lab-environment/k8s/grafana-dashboards.yaml` (capacity row at y=24)
- Modify: `k3s/apps/lab-environment/README.md` (short "Capacity alerts" section)

**Interfaces:**
- Consumes: Task 2's series.
- Produces: Grafana alert rules titled exactly `Lab Pod Pending`, `Lab Quota Near Limit`, `Lab CPU Throttling`, `Lab Container Restarts`, `Lab OOMKilled` (folder `Lab Capacity`), readable at `http://10.0.0.95:30094/api/prometheus/grafana/api/v1/alerts`.

- [ ] **Step 1: Add the rules file to `grafana-provisioning`**

New key under `data:` in the `grafana-provisioning` ConfigMap:
```yaml
  # Lab capacity alerts. No contact point on purpose: they show in this
  # Grafana only — the inspector already pages for Pending/FailedCreate/quota,
  # and chaos drills must stay out of the real alert pipeline. To page later,
  # add a contact point + notification policy; these rules do not change.
  alerting.yml: |
    apiVersion: 1
    groups:
      - orgId: 1
        name: lab_capacity
        folder: Lab Capacity
        interval: 30s
        rules:
          - uid: lab_pod_pending
            title: Lab Pod Pending
            condition: B
            for: 3m
            noDataState: OK
            annotations:
              summary: "A lab-environment pod has been Pending for 3 minutes (quota or node requests exhausted?)"
            data:
              - refId: A
                datasourceUid: prometheus
                relativeTimeRange: {from: 300, to: 0}
                model: {refId: A, instant: true, expr: 'sum(kube_pod_status_phase{namespace="lab-environment", phase="Pending"})'}
              - refId: B
                datasourceUid: '__expr__'
                model: {refId: B, type: threshold, expression: A, conditions: [{evaluator: {type: gt, params: [0]}}]}
          - uid: lab_quota_near_limit
            title: Lab Quota Near Limit
            condition: B
            for: 2m
            noDataState: OK
            annotations:
              summary: "lab-environment-quota requests above 90% of hard"
            data:
              - refId: A
                datasourceUid: prometheus
                relativeTimeRange: {from: 300, to: 0}
                model: {refId: A, instant: true, expr: 'max(max by (resource) (kube_resourcequota{namespace="lab-environment", type="used"}) / max by (resource) (kube_resourcequota{namespace="lab-environment", type="hard"}))'}
              - refId: B
                datasourceUid: '__expr__'
                model: {refId: B, type: threshold, expression: A, conditions: [{evaluator: {type: gt, params: [0.9]}}]}
          - uid: lab_cpu_throttling
            title: Lab CPU Throttling
            condition: B
            for: 10m
            noDataState: OK
            annotations:
              summary: "A lab container spent over 50% of its CFS periods throttled for 10 minutes"
            data:
              - refId: A
                datasourceUid: prometheus
                relativeTimeRange: {from: 600, to: 0}
                model: {refId: A, instant: true, expr: 'max(rate(container_cpu_cfs_throttled_periods_total{namespace="lab-environment", container!=""}[5m]) / rate(container_cpu_cfs_periods_total{namespace="lab-environment", container!=""}[5m]))'}
              - refId: B
                datasourceUid: '__expr__'
                model: {refId: B, type: threshold, expression: A, conditions: [{evaluator: {type: gt, params: [0.5]}}]}
          - uid: lab_container_restarts
            title: Lab Container Restarts
            condition: B
            for: 0s
            noDataState: OK
            annotations:
              summary: "A lab container restarted in the last 10 minutes"
            data:
              - refId: A
                datasourceUid: prometheus
                relativeTimeRange: {from: 600, to: 0}
                model: {refId: A, instant: true, expr: 'sum(increase(kube_pod_container_status_restarts_total{namespace="lab-environment"}[10m]))'}
              - refId: B
                datasourceUid: '__expr__'
                model: {refId: B, type: threshold, expression: A, conditions: [{evaluator: {type: gt, params: [0]}}]}
          - uid: lab_oomkilled
            title: Lab OOMKilled
            condition: B
            for: 0s
            noDataState: OK
            annotations:
              summary: "A lab container was OOMKilled and restarted in the last 10 minutes"
            data:
              - refId: A
                datasourceUid: prometheus
                relativeTimeRange: {from: 600, to: 0}
                model: {refId: A, instant: true, expr: 'count(max by (pod, container) (kube_pod_container_status_last_terminated_reason{namespace="lab-environment", reason="OOMKilled"}) and on (pod, container) (increase(kube_pod_container_status_restarts_total{namespace="lab-environment"}[10m]) > 0))'}
              - refId: B
                datasourceUid: '__expr__'
                model: {refId: B, type: threshold, expression: A, conditions: [{evaluator: {type: gt, params: [0]}}]}
```

- [ ] **Step 2: Mount it in grafana.yaml and bump config-rev**

Add under `volumeMounts` (after `dashboards-provider`):
```yaml
            - name: alerting
              mountPath: /etc/grafana/provisioning/alerting/alerting.yml
              subPath: alerting.yml
```
and under `volumes`:
```yaml
        - name: alerting
          configMap:
            name: grafana-provisioning
```
Change `lab.jerome/config-rev: "1"` to `"2"`.

- [ ] **Step 3: Add the capacity row to Lab Mesh Overview**

In `grafana-dashboards.yaml`, after the "Upstream retries" panel (add a comma after its closing `}`):
```json
        {"type": "timeseries", "title": "Quota: requests used / hard",
         "gridPos": {"x": 0, "y": 24, "w": 8, "h": 8},
         "datasource": {"type": "prometheus", "uid": "prometheus"},
         "fieldConfig": {"defaults": {"unit": "percentunit", "max": 1}},
         "targets": [{"expr": "max by (resource) (kube_resourcequota{namespace=\"lab-environment\", type=\"used\"}) / max by (resource) (kube_resourcequota{namespace=\"lab-environment\", type=\"hard\"})", "legendFormat": "{{resource}}"}]},
        {"type": "timeseries", "title": "CPU throttling ratio by container",
         "gridPos": {"x": 8, "y": 24, "w": 8, "h": 8},
         "datasource": {"type": "prometheus", "uid": "prometheus"},
         "fieldConfig": {"defaults": {"unit": "percentunit"}},
         "targets": [{"expr": "max by (pod, container) (rate(container_cpu_cfs_throttled_periods_total{namespace=\"lab-environment\", container!=\"\"}[5m]) / rate(container_cpu_cfs_periods_total{namespace=\"lab-environment\", container!=\"\"}[5m]))", "legendFormat": "{{pod}}/{{container}}"}]},
        {"type": "timeseries", "title": "Container restarts (10m)",
         "gridPos": {"x": 16, "y": 24, "w": 8, "h": 8},
         "datasource": {"type": "prometheus", "uid": "prometheus"},
         "targets": [{"expr": "sum by (pod, container) (increase(kube_pod_container_status_restarts_total{namespace=\"lab-environment\"}[10m]))", "legendFormat": "{{pod}}/{{container}}"}]}
```
Validate: `python3 -c "import yaml,json;d=[x for x in yaml.safe_load_all(open('k3s/apps/lab-environment/k8s/grafana-dashboards.yaml')) if x][0];print(len(json.loads(d['data']['lab-mesh-overview.json'])['panels']))"` → `9`.

- [ ] **Step 4: README section**

Append to `k3s/apps/lab-environment/README.md` before its last section:
```markdown
## Capacity alerts

Five Grafana-managed rules (folder *Lab Capacity*, `configmaps.yaml` →
`alerting.yml`): Pod Pending 3m, Quota Near Limit >90% 2m, CPU Throttling
>50% 10m, Container Restarts, OOMKilled. They have **no contact point** —
they are visible in this Grafana only; the inspector is what pages. They
exist because the quota sizes requests only and limits are overcommitted,
so these are how a capacity problem surfaces. The Lab Mesh Overview's
bottom row plots the same signals.
```

- [ ] **Step 5: Commit, STOP for confirmation, push; wait for grafana to restart**

```bash
git pull --rebase --autostash
git add k3s/apps/lab-environment/k8s/configmaps.yaml k3s/apps/lab-environment/k8s/grafana.yaml k3s/apps/lab-environment/k8s/grafana-dashboards.yaml k3s/apps/lab-environment/README.md
git commit -m "feat(lab-environment): add capacity alerts and a capacity dashboard row

Lab Grafana only, no contact point. Each rule maps to a failure the lab
has actually had: the quota deadlock, CFS-throttled startups, OOMKills.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 6: Verify the rules loaded and are all Normal**

```bash
curl -s http://10.0.0.95:30094/api/prometheus/grafana/api/v1/rules | jq -r '.data.groups[] | select(.name=="lab_capacity") | .rules[] | "\(.name) \(.state) \(.health)"'
```
Expected: five lines, each `inactive ok`.

- [ ] **Step 7: Fire every rule for real, then clean up**

```bash
cat > /tmp/claude-1001/alert-fire.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: alert-test-pending, namespace: lab-environment, labels: {trivy-operator.skip: "true"}}
spec:
  nodeSelector: {lab.jerome/does-not-exist: "true"}
  containers:
    - {name: c, image: busybox:1.36, command: [sleep, "3600"], resources: {requests: {cpu: 10m, memory: 16Mi}, limits: {memory: 32Mi}}}
---
apiVersion: v1
kind: Pod
metadata: {name: alert-test-quota, namespace: lab-environment, labels: {trivy-operator.skip: "true"}}
spec:
  containers:
    - {name: c, image: busybox:1.36, command: [sleep, "3600"], resources: {requests: {cpu: 600m, memory: 16Mi}, limits: {memory: 32Mi}}}
---
apiVersion: v1
kind: Pod
metadata: {name: alert-test-oom, namespace: lab-environment, labels: {trivy-operator.skip: "true"}}
spec:
  containers:
    - {name: c, image: busybox:1.36, command: [sh, -c, "x=$(dd if=/dev/zero bs=1M count=64 2>/dev/null | tr '\\0' a); sleep 3600"], resources: {requests: {cpu: 10m, memory: 16Mi}, limits: {memory: 32Mi}}}
---
apiVersion: v1
kind: Pod
metadata: {name: alert-test-throttle, namespace: lab-environment, labels: {trivy-operator.skip: "true"}}
spec:
  containers:
    - {name: c, image: busybox:1.36, command: [sh, -c, "while :; do :; done"], resources: {requests: {cpu: 10m, memory: 16Mi}, limits: {cpu: 100m, memory: 32Mi}}}
EOF
kubectl apply -f /tmp/claude-1001/alert-fire.yaml
kubectl -n lab-environment describe resourcequota | tail -3
```
If the quota pod is refused at admission, lower its CPU request so `used/hard` lands between 0.9 and 1.0 (read the current `used` from the describe output) and re-apply. Poll every minute until all five are `firing` (throttling needs ~11 min):
```bash
curl -s http://10.0.0.95:30094/api/prometheus/grafana/api/v1/alerts | jq -r '.data.alerts[] | "\(.labels.alertname) \(.state)"' | sort | uniq -c
```
Expected: all five alertnames in the firing state (Grafana's Prometheus-compatible endpoint prints `Alerting` or `firing` depending on version; `Pending` means not yet). Then:
```bash
kubectl delete -f /tmp/claude-1001/alert-fire.yaml --wait
```
Poll until the alerts endpoint lists none of the five (restarts/OOMKilled clear 10 min after the last restart). Record the fire and resolve times in the ledger.

---

### Task 4: Demo helpers (TDD)

**Files:**
- Create: `k3s/apps/lab-environment/demo/lib.sh`
- Create: `k3s/apps/lab-environment/demo/demo-window`
- Create: `k3s/apps/lab-environment/demo/demo-evidence`
- Create: `k3s/apps/lab-environment/demo/demo-reset`
- Create: `k3s/apps/lab-environment/demo/scenarios/preflight.sh`
- Test: `k3s/apps/lab-environment/tests/test-demo-helpers.sh`

**Interfaces:**
- Produces (used by every scenario file):
  - Scenario file `scenarios/<name>.sh` may define `start_<fn>`, `evidence_<fn>`, `reset_<fn>` where `<fn>` is the scenario name with `-` → `_`; may set `WINDOW_FROM=<other-scenario>` to reuse that scenario's window.
  - Variables available to scenario functions: `WINDOW_START`, `WINDOW_END` (epoch seconds), `WINDOW_FILE` (append `KEY=value` lines in `start_*` to carry values to `evidence_*`), `STATE_DIR`, `REPO_ROOT`, `LAB_K8S`, `NS`, `PROM`, `GRAFANA`, `JAEGER`, `CONSUL`, `INGRESS`.
  - Functions: `record <layer> ok|fail <text>`, `rec_if <layer> <text> <test-cmd...>`, `note <text>`, `iso <epoch>`, `prom <promql> [time]` → first value or `none`, `prom_vector <label> <promql> [time]` → lines `value label`, `loki_count <logql-selector-with-pipeline> <start> <end>` → integer, `loki_by <label> <logql> <start> <end>` → lines `value label`, `jaeger_spans <traceid>` → `N spans: svc, svc`, `pg <db> <sql>` → single value, `git_replicas <deployment>` → integer, `baseline_check`, `wait_baseline`.
  - CLI: `demo-window start|stop <s>`, `demo-evidence <s>` (exit 0 OK / 1 insufficient / 2 usage), `demo-reset <s>` (exit 0 baseline restored / 1 not).

- [ ] **Step 1: Write the failing tests**

`k3s/apps/lab-environment/tests/test-demo-helpers.sh`:
```bash
#!/bin/bash
# Behaviour tests for the demo helpers against stubbed curl/kubectl/argocd.
# No cluster access: every external call goes to a stub in $WORK/bin.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
DEMO=$HERE/../demo
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export DEMO_STATE_DIR=$WORK/state DEMO_SCENARIO_DIR=$WORK/scenarios DEMO_RESET_TIMEOUT=0
export FAKE_LOG=$WORK/calls.log FAKE_DEPLOYS=$WORK/deploys
mkdir -p "$WORK/bin" "$DEMO_SCENARIO_DIR"
export PATH=$WORK/bin:$PATH

cat > "$WORK/bin/curl" <<'EOF'
#!/bin/bash
echo "curl $*" >> "$FAKE_LOG"
case "$*" in
  *FAILME*) exit 22 ;;
  *"/v1/kv/chaos/"*)
    if [ -n "${FAKE_CHAOS_ON:-}" ]; then v=dHJ1ZQ==; else v=ZmFsc2U=; fi
    echo "[{\"Key\":\"${FAKE_CHAOS_ON:-chaos/visits-service/redis-timeout}\",\"Value\":\"$v\"}]" ;;
  *"/loki/api/v1/query"*) echo '{"data":{"result":[{"metric":{},"value":[0,"7"]}]}}' ;;
  *) echo '{"data":{"result":[]}}' ;;
esac
EOF
cat > "$WORK/bin/kubectl" <<'EOF'
#!/bin/bash
echo "kubectl $*" >> "$FAKE_LOG"
case "$*" in
  *" get deploy "*) d=$(sed -E 's/.* get deploy ([^ ]+).*/\1/' <<< "$*"); grep "^$d " "$FAKE_DEPLOYS" | cut -d' ' -f2- ;;
  *"logs deploy/traffic-generator"*) for i in 1 2 3; do echo "2026-09-27T00:00:0${i}+00:00 ${FAKE_GEN_CODE:-200} /api/vet/vets"; done ;;
esac
EOF
cat > "$WORK/bin/argocd" <<'EOF'
#!/bin/bash
echo "{\"status\":{\"sync\":{\"status\":\"${FAKE_SYNC:-Synced}\"},\"health\":{\"status\":\"Healthy\"}}}"
EOF
chmod +x "$WORK/bin/"*

# Fixture: every business Deployment ready at the replica count git declares.
: > "$FAKE_DEPLOYS"
for d in api-gateway customers-service vets-service visits-service; do
  r=$(grep -m1 -E '^\s+replicas:' "$HERE/../k8s/$d.yaml" | awk '{print $2}')
  echo "$d $r $r" >> "$FAKE_DEPLOYS"
done

cp "$DEMO/scenarios/preflight.sh" "$DEMO_SCENARIO_DIR/"   # created in Step 4; the reset tests use it
cat > "$DEMO_SCENARIO_DIR/t1.sh" <<'EOF'
evidence_t1() {
  n=$(loki_count '{service="x"}' "$WINDOW_START" "$WINDOW_END")
  record envoy ok "loki said $n"
  record argocd ok "second infra piece"
}
reset_t1() { touch "$STATE_DIR/reset-called"; }
EOF
cat > "$DEMO_SCENARIO_DIR/one.sh" <<'EOF'
evidence_one() { record envoy ok "only piece"; }
EOF
cat > "$DEMO_SCENARIO_DIR/apponly.sh" <<'EOF'
evidence_apponly() { record app ok "a"; record postgres ok "b"; }
EOF
cat > "$DEMO_SCENARIO_DIR/withfail.sh" <<'EOF'
evidence_withfail() { record envoy ok "a"; record argocd ok "b"; rec_if app "c" [ 1 -eq 2 ]; }
EOF
cat > "$DEMO_SCENARIO_DIR/borrow.sh" <<'EOF'
WINDOW_FROM=t1
evidence_borrow() { record envoy ok "start $WINDOW_START"; record kubernetes ok "end $WINDOW_END"; }
EOF
cat > "$DEMO_SCENARIO_DIR/qfail.sh" <<'EOF'
evidence_qfail() { record envoy ok "a"; v=$(prom 'FAILME'); record argocd ok "never $v"; }
EOF

fails=0
check() { # check <name> <expected-exit> <cmd...>
  local name=$1 want=$2 got=0; shift 2
  "$@" > "$WORK/out" 2>&1 || got=$?
  if [ "$got" = "$want" ]; then echo "PASS $name"; else echo "FAIL $name (exit $got, want $want)"; sed 's/^/    /' "$WORK/out"; fails=$((fails+1)); fi
}
has() { grep -qF -- "$2" "$1" || { echo "FAIL expected '$2' in $1"; fails=$((fails+1)); }; }

# --- demo-window ---------------------------------------------------------
check "unknown scenario" 2 "$DEMO/demo-window" start nosuch
has "$WORK/out" "unknown scenario"
check "stop without start" 2 "$DEMO/demo-window" stop one
DEMO_NOW=1000 check "start" 0 "$DEMO/demo-window" start t1
check "evidence refuses open window" 2 "$DEMO/demo-evidence" t1
DEMO_NOW=1300 check "stop" 0 "$DEMO/demo-window" stop t1
has "$DEMO_STATE_DIR/t1.window" "WINDOW_START=1000"
has "$DEMO_STATE_DIR/t1.window" "WINDOW_END=1300"
DEMO_NOW=1400 check "restart" 0 "$DEMO/demo-window" start one
DEMO_NOW=1500 "$DEMO/demo-window" stop one >/dev/null
DEMO_NOW=2000 "$DEMO/demo-window" start one >/dev/null
if grep -q WINDOW_END "$DEMO_STATE_DIR/one.window"; then echo "FAIL restart clears end"; fails=$((fails+1)); else echo "PASS restart clears end"; fi
DEMO_NOW=2100 "$DEMO/demo-window" stop one >/dev/null

# --- demo-evidence -------------------------------------------------------
: > "$FAKE_LOG"
check "two infra pieces pass" 0 "$DEMO/demo-evidence" t1
has "$WORK/out" "== OK"
has "$FAKE_LOG" "[300s]"
has "$FAKE_LOG" "time=1300000000000"
check "one piece is insufficient" 1 "$DEMO/demo-evidence" one
for s in apponly withfail; do
  DEMO_NOW=1 "$DEMO/demo-window" start $s >/dev/null; DEMO_NOW=2 "$DEMO/demo-window" stop $s >/dev/null
done
check "app-only evidence is insufficient" 1 "$DEMO/demo-evidence" apponly
check "a failed piece fails the run" 1 "$DEMO/demo-evidence" withfail
check "WINDOW_FROM borrows a window" 0 "$DEMO/demo-evidence" borrow
has "$WORK/out" "start 1000"
DEMO_NOW=1 "$DEMO/demo-window" start qfail >/dev/null; DEMO_NOW=2 "$DEMO/demo-window" stop qfail >/dev/null
check "query failure aborts" 1 "$DEMO/demo-evidence" qfail
has "$WORK/out" "aborted"
if grep -q "== OK" "$WORK/out"; then echo "FAIL query failure printed OK"; fails=$((fails+1)); fi
DEMO_SAVE_DIR=$WORK/saved; mkdir -p "$DEMO_SAVE_DIR"
DEMO_SAVE_DIR=$DEMO_SAVE_DIR check "save copies output" 0 "$DEMO/demo-evidence" t1
has "$DEMO_SAVE_DIR/t1.txt" "== OK"

# --- demo-reset ----------------------------------------------------------
check "reset at baseline" 0 "$DEMO/demo-reset" t1
[ -f "$DEMO_STATE_DIR/reset-called" ] && echo "PASS reset hook ran" || { echo "FAIL reset hook ran"; fails=$((fails+1)); }
FAKE_CHAOS_ON=chaos/customers-service/slow-query-enabled check "reset fails on any chaos key" 1 "$DEMO/demo-reset" preflight
has "$WORK/out" "chaos/customers-service/slow-query-enabled"
sed -i 's/^customers-service .*/customers-service 4 5/' "$FAKE_DEPLOYS"
check "reset fails on replica mismatch" 1 "$DEMO/demo-reset" preflight
sed -i 's/^customers-service .*/customers-service 5 5/' "$FAKE_DEPLOYS"
FAKE_GEN_CODE=503 check "reset fails on generator errors" 1 "$DEMO/demo-reset" preflight
FAKE_SYNC=OutOfSync check "reset fails when ArgoCD is not synced" 1 "$DEMO/demo-reset" preflight

[ $fails -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash k3s/apps/lab-environment/tests/test-demo-helpers.sh`
Expected: FAIL lines (helpers do not exist yet), non-zero exit.

- [ ] **Step 3: Write lib.sh**

`k3s/apps/lab-environment/demo/lib.sh`:
```bash
# Shared by demo-window, demo-evidence and demo-reset. Sourced, not run.
# Runs on vps_oracle: its kubectl context plus the lab NodePorts.
set -euo pipefail

DEMO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$DEMO_DIR/../../../.." && pwd)
LAB_K8S=$DEMO_DIR/../k8s
STATE_DIR=${DEMO_STATE_DIR:-$HOME/.local/state/lab-demo}
SCENARIO_DIR=${DEMO_SCENARIO_DIR:-$DEMO_DIR/scenarios}
NODE=${LAB_NODE_IP:-10.0.0.95}
PROM=http://$NODE:30093
GRAFANA=http://$NODE:30094
JAEGER=http://$NODE:30095
CONSUL=http://$NODE:30092
INGRESS=http://$NODE:30097
NS=lab-environment
BUSINESS="api-gateway customers-service vets-service visits-service"
# Evidence from these layers is the platform's own record, not the app's.
INFRA_LAYERS=" envoy ztunnel argocd kyverno sealed-secrets cadvisor kubernetes "
mkdir -p "$STATE_DIR"

die() { echo "demo: $*" >&2; exit 2; }
now() { echo "${DEMO_NOW:-$(date +%s)}"; }
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
fn_name() { echo "${1//-/_}"; }

scenario_file() {
  local f="$SCENARIO_DIR/$1.sh"
  [ -f "$f" ] || die "unknown scenario '$1' (known: $(cd "$SCENARIO_DIR" && ls ./*.sh | sed 's|^\./||; s|\.sh$||' | tr '\n' ' '))"
  echo "$f"
}
window_file() { echo "$STATE_DIR/$1.window"; }

# Sources <name>'s window file; refuses a missing or still-open window.
load_window() {
  local f; f=$(window_file "$1")
  [ -f "$f" ] || die "no window for '$1' — run: demo-window start $1"
  WINDOW_START='' WINDOW_END=''
  # shellcheck disable=SC1090
  . "$f"
  [ -n "$WINDOW_END" ] || die "window for '$1' is still open — run: demo-window stop $1"
}

# --- evidence tally (a file, so evidence functions may run in a subshell) --
record() {
  local layer=$1 status=$2; shift 2
  printf '  [%-14s] %s  %s\n' "$layer" "$([ "$status" = ok ] && echo PASS || echo FAIL)" "$*"
  echo "$status $layer" >> "$TALLY"
}
rec_if() {
  local layer=$1 text=$2; shift 2
  if "$@"; then record "$layer" ok "$text"; else record "$layer" fail "$text"; fi
}
note() { printf '  [note          ]       %s\n' "$*"; }

# --- queries (curl -f: an unreachable endpoint aborts the evidence run) ----
prom() {
  curl -sf -G "$PROM/api/v1/query" --data-urlencode "query=$1" ${2:+--data-urlencode "time=$2"} \
    | jq -r '.data.result[0].value[1] // "none"'
}
prom_vector() {
  curl -sf -G "$PROM/api/v1/query" --data-urlencode "query=$2" ${3:+--data-urlencode "time=$3"} \
    | jq -r --arg l "$1" '.data.result[] | "\(.value[1]) \(.metric[$l])"'
}
loki_instant() {
  curl -sf -G "$GRAFANA/api/datasources/proxy/uid/loki/loki/api/v1/query" \
    --data-urlencode "query=$1" --data-urlencode "time=${2}000000000"
}
loki_count() {
  loki_instant "sum(count_over_time($1 [$(( $3 - $2 ))s]))" "$3" | jq -r '.data.result[0].value[1] // "0"'
}
loki_by() {
  loki_instant "sum by ($1) (count_over_time($2 [$(( $4 - $3 ))s]))" "$4" \
    | jq -r --arg l "$1" '.data.result[] | "\(.value[1]) \(.metric[$l])"'
}
# Jaeger fills a trace in over ~20 s; wait until the span count stops moving.
jaeger_spans() {
  local id=$1 last=-1 n same=0 i
  for i in $(seq 1 12); do
    n=$(curl -sf "$JAEGER/api/traces/$id" | jq '.data[0].spans | length' 2>/dev/null || echo 0)
    if [ "$n" = "$last" ] && [ "$n" -gt 0 ]; then same=$((same + 1)); [ $same -ge 2 ] && break; else same=0; fi
    last=$n; sleep "${JAEGER_POLL_SECONDS:-5}"
  done
  curl -sf "$JAEGER/api/traces/$id" | jq -r '"\(.data[0].spans | length) spans: \([.data[0].processes[].serviceName] | unique | join(", "))"'
}
# Local socket inside the postgres pod (pg_hba trust) — for reading data only.
pg() { kubectl -n "$NS" exec deploy/postgres -- psql -U petclinic -d "$1" -tAc "$2"; }
git_replicas() { grep -m1 -E '^\s+replicas:' "$LAB_K8S/$1.yaml" | awk '{print $2}'; }

# --- baseline ---------------------------------------------------------------
baseline_check() {
  local bad=0 on d got want st lines total non200
  on=$(curl -sf "$CONSUL/v1/kv/chaos/?recurse" | jq -r '.[] | select((.Value // "" | @base64d) != "false") | .Key')
  [ -z "$on" ] || { echo "chaos toggles still on: $on"; bad=1; }
  for d in $BUSINESS; do
    want=$(git_replicas "$d")
    got=$(kubectl -n "$NS" get deploy "$d" -o jsonpath='{.status.readyReplicas} {.spec.replicas}')
    [ "$got" = "$want $want" ] || { echo "$d ready/spec '$got', git wants $want"; bad=1; }
  done
  st=$(argocd app get lab-environment --core -o json | jq -r '.status.sync.status + "/" + .status.health.status')
  [ "$st" = "Synced/Healthy" ] || { echo "lab-environment is $st"; bad=1; }
  lines=$(kubectl -n "$NS" logs deploy/traffic-generator --since=30s)
  total=$(echo "$lines" | grep -c . || true)
  non200=$(echo "$lines" | awk 'NF && $2 != "200"' | grep -c . || true)
  { [ "$total" -gt 0 ] && [ "$non200" -eq 0 ]; } || { echo "generator last 30s: $total requests, $non200 non-200"; bad=1; }
  return $bad
}
wait_baseline() {
  local deadline=$(( $(date +%s) + ${DEMO_RESET_TIMEOUT:-180} ))
  while :; do
    if baseline_check > "$STATE_DIR/.baseline" 2>&1; then echo "baseline OK"; return 0; fi
    if [ "$(date +%s)" -ge "$deadline" ]; then sed 's/^/  /' "$STATE_DIR/.baseline"; echo "baseline NOT restored"; return 1; fi
    sleep 10
  done
}
```

- [ ] **Step 4: Write the three commands and the preflight scenario**

`demo/demo-window`:
```bash
#!/bin/bash
# demo-window start|stop <scenario> — records the scenario's UTC window.
. "$(dirname "$(readlink -f "$0")")/lib.sh"
[ $# -eq 2 ] || die "usage: demo-window start|stop <scenario>"
action=$1 s=$2
f=$(scenario_file "$s")
WINDOW_FILE=$(window_file "$s")
case $action in
  start)
    t=$(now)
    echo "WINDOW_START=$t" > "$WINDOW_FILE"
    # shellcheck disable=SC1090
    . "$f"
    fn="start_$(fn_name "$s")"
    if declare -F "$fn" >/dev/null; then "$fn"; fi
    echo "window $s started $(iso "$t")" ;;
  stop)
    [ -f "$WINDOW_FILE" ] || die "no window started for '$s'"
    t=$(now)
    sed -i '/^WINDOW_END=/d' "$WINDOW_FILE"
    echo "WINDOW_END=$t" >> "$WINDOW_FILE"
    echo "window $s stopped $(iso "$t")" ;;
  *) die "usage: demo-window start|stop <scenario>" ;;
esac
```

`demo/demo-evidence`:
```bash
#!/bin/bash
# demo-evidence <scenario> — runs the scenario's evidence over its window.
# Exit 0 only with >= 2 passing pieces, >= 1 of them infrastructure-layer,
# and no failed piece.
. "$(dirname "$(readlink -f "$0")")/lib.sh"
[ $# -eq 1 ] || die "usage: demo-evidence <scenario>"
s=$1
f=$(scenario_file "$s")
WINDOW_FROM=''
# shellcheck disable=SC1090
. "$f"
load_window "${WINDOW_FROM:-$s}"
fn="evidence_$(fn_name "$s")"
declare -F "$fn" >/dev/null || die "$f defines no $fn"
export TALLY; TALLY=$(mktemp "$STATE_DIR/.tally.XXXXXX")
out="$STATE_DIR/$s.evidence.txt"
{
  echo "== $s  window $(iso "$WINDOW_START") → $(iso "$WINDOW_END") ($(( WINDOW_END - WINDOW_START ))s)"
  set +e
  ( set -e; "$fn" )
  rc=$?
  set -e
  pass=$(grep -c '^ok ' "$TALLY" || true)
  failed=$(grep -c '^fail ' "$TALLY" || true)
  infra=0
  while read -r st layer; do
    [ "$st" = ok ] && case "$INFRA_LAYERS" in *" $layer "*) infra=$((infra + 1)) ;; esac
  done < "$TALLY"
  if [ "$rc" -ne 0 ]; then
    echo "== evidence aborted: a query or command failed (exit $rc)"
    verdict=1
  elif [ "$failed" -gt 0 ] || [ "$pass" -lt 2 ] || [ "$infra" -lt 1 ]; then
    echo "== INSUFFICIENT: $pass passed ($infra infrastructure-layer), $failed failed — need >= 2 with >= 1 infrastructure and none failed"
    verdict=1
  else
    echo "== OK: $pass passed ($infra infrastructure-layer)"
    verdict=0
  fi
  echo "$verdict" > "$TALLY.verdict"
} 2>&1 | tee "$out"
verdict=$(cat "$TALLY.verdict"); rm -f "$TALLY" "$TALLY.verdict"
if [ "$verdict" -eq 0 ] && [ -n "${DEMO_SAVE_DIR:-}" ]; then cp "$out" "$DEMO_SAVE_DIR/$s.txt"; fi
exit "$verdict"
```

`demo/demo-reset`:
```bash
#!/bin/bash
# demo-reset <scenario> — undoes the scenario and verifies the lab baseline
# in the same command, so a reset is never left to "a later step".
. "$(dirname "$(readlink -f "$0")")/lib.sh"
[ $# -eq 1 ] || die "usage: demo-reset <scenario>"
s=$1
f=$(scenario_file "$s")
# shellcheck disable=SC1090
. "$f"
fn="reset_$(fn_name "$s")"
if declare -F "$fn" >/dev/null; then "$fn" || { echo "reset step for $s failed"; exit 1; }; fi
wait_baseline
```

`demo/scenarios/preflight.sh`:
```bash
# Preflight has no action of its own: `demo-reset preflight` is the lab
# baseline check run before any demo.
```

Then: `chmod +x k3s/apps/lab-environment/demo/demo-*`

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bash k3s/apps/lab-environment/tests/test-demo-helpers.sh`
Expected: every line `PASS`, final `ALL PASS`.

- [ ] **Step 6: Lint, and check the live baseline once**

```bash
shellcheck -x -s bash k3s/apps/lab-environment/demo/lib.sh k3s/apps/lab-environment/demo/demo-* k3s/apps/lab-environment/tests/test-demo-helpers.sh || true   # if shellcheck is absent: docker run --rm -v "$PWD:/mnt" koalaman/shellcheck:stable -x ...
k3s/apps/lab-environment/demo/demo-reset preflight
```
Expected: no shellcheck errors (warnings reviewed); `baseline OK` against the live lab.

- [ ] **Step 7: Commit (no deploy — no stop point)**

```bash
git pull --rebase --autostash
git add k3s/apps/lab-environment/demo/ k3s/apps/lab-environment/tests/test-demo-helpers.sh
git commit -m "feat(lab-environment): add demo window/evidence/reset helpers

Each scenario gets its own recorded window, evidence that must include
an infrastructure-layer source, and a reset that verifies the baseline
in the same command — the two failures in the baseline ledger were a
misattributed time window and a forgotten chaos reset.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git push
```

---

### Task 5: Runbook skeleton and docs-layout rule

**Files:**
- Create: `docs/demo/README.md`
- Create: `docs/demo/00-preflight.md`
- Create: `docs/demo/evidence/.gitkeep`
- Modify: `.claude/rules/docs-layout.md`
- Modify: `k3s/apps/lab-environment/README.md` (pointer to the runbook)

**Interfaces:**
- Produces: the fixed scenario-page structure every later task follows — `## Purpose`, `## Preconditions`, `## Commands`, `## Expected result`, `## Evidence`, `## Talking points`, `## Reset`.

- [ ] **Step 1: Write `docs/demo/README.md`**

```markdown
# Lab demo runbook

Live demonstrations of SDLC capabilities on `lab-environment` (PetClinic
microservices on vps-oracle2). Each scenario is real platform behaviour,
backed by evidence from the infrastructure layer — Envoy, ztunnel, ArgoCD,
sealed-secrets, cAdvisor, Kubernetes — not by the app's own logs alone.

This directory describes **current state**: when the lab changes, the pages
change with it.

## How to run a scenario

Every page has the same sections: purpose → preconditions → commands →
expected result → evidence → talking points → reset. Paste the commands in
order from the repo root on vps_oracle. Main actions (`kubectl`, `git`,
`curl`) are written out in full; the bookkeeping is one helper call each:

| Helper | Does |
|---|---|
| `demo-window start/stop <s>` | Records the scenario's own UTC window — every query is bounded by it |
| `demo-evidence <s>` | Runs the scenario's evidence queries; fails unless ≥ 2 pieces pass, ≥ 1 from the infrastructure layer |
| `demo-reset <s>` | Undoes the scenario and verifies the lab baseline in the same command |

Run `demo-evidence` straight after `demo-window stop`: Jaeger keeps only
the last 5000 traces (~1 h at the generator's rate).

Git changes go to `main` for real, with a `demo:` subject prefix — there is
no demo branch. ArgoCD's `selfHeal` would revert a bare `kubectl` change
anyway, which scenario 07 demonstrates.

## Order

| # | Scenario | Why here |
|---|---|---|
| 00 | [Preflight](00-preflight.md) | Before anything |
| 01 | [Load balancing across 5 instances](01-load-balancing.md) | Read-only warm-up |
| 02 | [Zero-downtime rolling update](02-rolling-update.md) | Makes the commit 03 and 07 use |
| 03 | [Schema migration as a PreSync hook](03-schema-migration.md) | Reads 02's sync |
| 07 | [GitOps self-heal and rollback](07-gitops-selfheal-rollback.md) | Reverts 02's commit |
| 04 | [Zero trust: mTLS, identity authz, actuator lockdown](04-zero-trust.md) | |
| 05 | [App-level vs mesh-level resilience](05-app-vs-mesh-resilience.md) | |
| 06 | [Secret rotation](06-secret-rotation.md) | Riskiest mutation |
| 08 | [Load test: capacity baseline and bottleneck](08-load-test.md) | Overloads the node — always last |

`evidence/` holds the last rehearsal's `demo-evidence` output for every
scenario — the fallback if the live cluster misbehaves mid-interview.
```

- [ ] **Step 2: Write `docs/demo/00-preflight.md`**

```markdown
# 00 — Preflight

## Purpose
Start from a known-good lab so every later failure belongs to a scenario.

## Preconditions
On vps_oracle, repo root (`~/jerome/docker-gitops`), kubectl context `default`.

## Commands
```bash
git pull --ff-only
export PATH=$PWD/k3s/apps/lab-environment/demo:$PATH
demo-reset preflight
kubectl -n lab-environment get pods | grep -v -E 'Running|Completed'
argocd app list --core | grep -E 'lab-environment|sealed-secrets|kube-state-metrics'
```

## Expected result
`baseline OK`; only the header line from the pod filter; the three apps
`Synced  Healthy`.

## Evidence
None — this is the baseline every scenario is measured against. Open
Grafana (Lab Mesh Overview), Jaeger and the Grafana Alerting page in
browser tabs now.

## Talking points
- The lab is production-shaped on purpose: 5 customers / 3 gateway
  replicas, Istio ambient with a waypoint, STRICT mTLS, least-privilege
  authorization, resident timeouts/retries/outlier detection.
- Baseline is checked, not assumed: chaos toggles, replica counts vs git,
  ArgoCD sync, and 30 s of generator traffic.

## Reset
Nothing to reset.
```

- [ ] **Step 3: docs-layout rule**

In `.claude/rules/docs-layout.md`, add under "Inside `docs/`:" as the first bullet:
```markdown
- `demo/` — the live-demo runbook for `lab-environment`. **Current state, not history** — the one exception in `docs/`: it must change whenever the lab changes, like a README.
```

- [ ] **Step 4: Lab README pointer**

Append to the lab README's opening section: `Live-demo scenarios for this environment are in [docs/demo/](../../../docs/demo/README.md).`

- [ ] **Step 5: Commit and push (docs only)**

```bash
mkdir -p docs/demo/evidence && touch docs/demo/evidence/.gitkeep
git pull --rebase --autostash
git add docs/demo/ .claude/rules/docs-layout.md k3s/apps/lab-environment/README.md
git commit -m "docs(demo): add the lab demo runbook index and preflight

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git push
```

---

### Task 6: Scenario 01 — load balancing

**Files:**
- Create: `k3s/apps/lab-environment/demo/scenarios/load-balancing.sh`
- Create: `docs/demo/01-load-balancing.md`

**Interfaces:**
- Consumes: Task 4's `loki_by`, `prom_vector`, `rec_if`, `git_replicas`.

- [ ] **Step 1: Write the scenario file**

```bash
# 01 — per-request load balancing across the customers-service replicas.
evidence_load_balancing() {
  local range=$(( WINDOW_END - WINDOW_START )) want hosts pods n
  want=$(git_replicas customers-service)
  hosts=$(loki_by upstream_host '{service="istio-proxy"} | json | authority=~"customers-service.*"' "$WINDOW_START" "$WINDOW_END")
  echo "$hosts" | sed 's/^/      /'
  n=$(echo "$hosts" | grep -c . || true)
  rec_if envoy "waypoint spread customers-service requests over $n pods (want $want)" [ "$n" -eq "$want" ]
  pods=$(prom_vector pod "sum by (pod) (increase(http_server_requests_seconds_count{service=\"customers-service\", uri!~\"/actuator.*\"}[${range}s]))" "$WINDOW_END")
  echo "$pods" | sed 's/^/      /'
  n=$(echo "$pods" | awk '$1 > 0' | grep -c . || true)
  rec_if app "customers-service pods that served requests: $n (want $want)" [ "$n" -eq "$want" ]
}
```

- [ ] **Step 2: Write the runbook page**

```markdown
# 01 — Load balancing across 5 instances

## Purpose
Show per-request (L7) load balancing by the waypoint across all five
customers-service pods — not per-connection L4 balancing that pins a
keep-alive client to one pod.

## Preconditions
Preflight passed.

## Commands
```bash
demo-window start load-balancing
for i in $(seq 1 100); do curl -s -o /dev/null -w '%{http_code}\n' http://10.0.0.95:30097/api/customer/owners; done | sort | uniq -c
demo-window stop load-balancing
demo-evidence load-balancing
```

## Expected result
`100 200`. Evidence lists five upstream pod IPs with similar counts, and
five pods with non-zero request increases.

## Evidence
- **Envoy (waypoint access log):** requests to `customers-service` grouped
  by `upstream_host` — one line per pod.
- **App (Spring metrics):** per-pod request increase in the window.
- Grafana → Lab Mesh Overview → "customers-service RPS per pod".

## Talking points
- kube-proxy balances connections; a gateway holding keep-alive connections
  would stick to a few pods. The waypoint balances requests.
- The earlier Consul-based discovery registered every replica under the same
  instance ID, so a rolling update's deregistration deleted the new pods'
  entries (vets/visits went to 0 instances). Discovery is now Kubernetes
  Services only; Consul is config and chaos toggles.
- Five pods of the same JVM service on a 2-core node is deliberate: real
  load balancing needs real replicas.

## Reset
`demo-reset load-balancing` — nothing was changed; verifies the baseline.
```

- [ ] **Step 3: Run it live**

Run the page's commands exactly.
Expected: `== OK: 2 passed (1 infrastructure-layer)`. If the envoy piece shows fewer hosts, print the raw Loki lines for the window (`loki_by authority ...`) to confirm the `authority` value before changing the selector — do not loosen the check to pass.

- [ ] **Step 4: Reset, commit, push**

```bash
demo-reset load-balancing
git pull --rebase --autostash
git add k3s/apps/lab-environment/demo/scenarios/load-balancing.sh docs/demo/01-load-balancing.md
git commit -m "docs(demo): add the load-balancing scenario

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git push
```

---

### Task 7: Scenarios 02 + 03 — rolling update and PreSync schema migration

These share one live sync, so they are built and run together.

**Files:**
- Create: `k3s/apps/lab-environment/demo/scenarios/rolling-update.sh`
- Create: `k3s/apps/lab-environment/demo/scenarios/schema-migration.sh`
- Create: `docs/demo/02-rolling-update.md`
- Create: `docs/demo/03-schema-migration.md`

**Interfaces:**
- Produces: git commit with subject exactly `demo: rolling-restart customers-service` (Task 8 reverts it); `OWNERS_BEFORE` in the `rolling-update` window file (read by schema-migration via `WINDOW_FROM=rolling-update`).

- [ ] **Step 1: Write `rolling-update.sh`**

```bash
# 02 — zero-downtime rolling update triggered through git.
DEMO_COMMIT_SUBJECT='demo: rolling-restart customers-service'

start_rolling_update() {
  echo "OWNERS_BEFORE=$(pg customers 'select count(*) from owners')" >> "$WINDOW_FILE"
}

evidence_rolling_update() {
  local sha deployed ok want created non2xx total bad
  sha=$(git -C "$REPO_ROOT" log -1 --grep="^$DEMO_COMMIT_SUBJECT\$" --format=%H)
  # History, not the live revision: a later commit may already have landed.
  deployed=$(argocd app get lab-environment --core -o json \
    | jq -r --arg s "$(iso "$WINDOW_START")" '[.status.history[] | select(.deployedAt >= $s) | .revision] | join(" ")')
  ok=0; [ -n "$sha" ] && [[ " $deployed " == *" $sha "* ]] && ok=1
  rec_if argocd "ArgoCD deployed the demo commit ${sha:0:7} inside the window" [ $ok = 1 ]
  want=$(git_replicas customers-service)
  created=$(kubectl -n "$NS" get pods -l app=customers-service -o json | jq --arg s "$(iso "$WINDOW_START")" \
    '[.items[] | select(.metadata.creationTimestamp >= $s) | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length')
  rec_if kubernetes "customers-service pods replaced in the window and Ready: $created (want $want)" [ "$created" -eq "$want" ]
  non2xx=$(loki_count '{service="istio-proxy"} | json | response_code!~"2.."' "$WINDOW_START" "$WINDOW_END")
  rec_if envoy "non-2xx responses at ingress + waypoint during the rollout: $non2xx (want 0)" [ "$non2xx" -eq 0 ]
  total=$(loki_count '{service="traffic-generator"}' "$WINDOW_START" "$WINDOW_END")
  bad=$(loki_count '{service="traffic-generator"} !~ " 200 "' "$WINDOW_START" "$WINDOW_END")
  ok=0; [ "$total" -gt 0 ] && [ "$bad" -eq 0 ] && ok=1
  rec_if app "generator requests during the rollout: $total, non-200: $bad (want 0)" [ $ok = 1 ]
}

reset_rolling_update() {
  kubectl -n "$NS" rollout status deploy/customers-service --timeout=6m
}
```

- [ ] **Step 2: Write `schema-migration.sh`**

```bash
# 03 — no action of its own: reads the PreSync hook out of 02's sync.
WINDOW_FROM=rolling-update

evidence_schema_migration() {
  local sha op hook oprev ok done_at first_pod owners
  sha=$(git -C "$REPO_ROOT" log -1 --grep='^demo: rolling-restart customers-service$' --format=%H)
  op=$(argocd app get lab-environment --core -o json | jq -c '.status.operationState')
  hook=$(echo "$op" | jq -r '[.syncResult.resources[] | select(.kind == "Job" and .name == "db-init")][0] | "\(.syncPhase)/\(.hookPhase)"')
  oprev=$(echo "$op" | jq -r '.syncResult.revision')
  ok=0; [ "$hook" = "PreSync/Succeeded" ] && [ "$oprev" = "$sha" ] && ok=1
  rec_if argocd "sync of ${sha:0:7} ran db-init as $hook (want PreSync/Succeeded; last op revision ${oprev:0:7})" [ $ok = 1 ]
  done_at=$(kubectl -n "$NS" get job db-init -o jsonpath='{.status.completionTime}')
  first_pod=$(kubectl -n "$NS" get pods -l app=customers-service -o json | jq -r '[.items[].metadata.creationTimestamp] | min')
  ok=0; [[ "$done_at" > "$(iso "$WINDOW_START")" ]] && ! [[ "$done_at" > "$first_pod" ]] && ok=1
  rec_if kubernetes "db-init completed $done_at, first new customers pod $first_pod (hook first)" [ $ok = 1 ]
  owners=$(pg customers 'select count(*) from owners')
  ok=0; [ -n "${OWNERS_BEFORE:-}" ] && [ "$owners" = "$OWNERS_BEFORE" ] && ok=1
  rec_if postgres "owners before/after the re-run: ${OWNERS_BEFORE:-?}/$owners (idempotent)" [ $ok = 1 ]
  kubectl -n "$NS" logs job/db-init | grep applying | sed 's/^/      /'
}
```
Note: the argocd check here compares the *last operation's* revision, so 03's evidence must run right after 02's (before 07 pushes). The page says so.

- [ ] **Step 3: Write `docs/demo/02-rolling-update.md`**

```markdown
# 02 — Zero-downtime rolling update

## Purpose
Roll all five customers-service pods through git while live traffic flows,
with zero failed requests.

## Preconditions
Preflight passed. Working tree clean (`git status`).

## Commands
```bash
git pull --ff-only
demo-window start rolling-update
F=k3s/apps/lab-environment/k8s/customers-service.yaml
cur=$(grep -oP 'lab.jerome/rollout-rev: "\K[0-9]+' $F)
sed -i "s|lab.jerome/rollout-rev: \"$cur\"|lab.jerome/rollout-rev: \"$((cur + 1))\"|" $F
git diff
git commit -m "demo: rolling-restart customers-service" -- $F
git push
argocd app get lab-environment --core --refresh >/dev/null
kubectl -n lab-environment rollout status deploy/customers-service --timeout=6m
demo-window stop rolling-update
demo-evidence rolling-update
```

## Expected result
`rollout status` walks 5 → 5 one pod at a time (maxSurge 1, maxUnavailable
0) and finishes in ~3 minutes. Evidence: demo commit deployed, five new
Ready pods, zero non-2xx at the mesh, zero generator errors.

## Evidence
- **ArgoCD:** the demo commit in the app's history inside the window.
- **Kubernetes:** five customers pods created in the window, all Ready.
- **Envoy:** non-2xx count at ingress + waypoint = 0.
- **App:** traffic-generator lines in Loki — all 200.

## Talking points
- `maxSurge: 1 / maxUnavailable: 0` + readiness on the actuator readiness
  group + PDB `minAvailable: 3`: capacity never drops below five.
- The annotation bump is how you restart without a new image; ArgoCD would
  revert a `kubectl rollout restart` as drift.
- Measured history: the first rolling update under Consul discovery threw
  `000`/`405` for ~25 s because every replica shared one Consul instance ID;
  the 405 was the gateway forwarding GET to a POST-only `/fallback`.
- A release touching four Deployments at once deadlocked the namespace
  quota on 2026-09-25 (surge pods + the PreSync hook); the quota is now
  derived from the release peak.

## Reset
Leave the commit — scenario 07 reverts it. `demo-reset rolling-update`
waits for the rollout and verifies the baseline.
```

- [ ] **Step 4: Write `docs/demo/03-schema-migration.md`**

```markdown
# 03 — Schema migration as a PreSync hook

## Purpose
Show that the schema job runs *before* the new pods, on every sync, and is
idempotent — using 02's sync, without inventing a schema change.

## Preconditions
Scenario 02 just finished. Run this before scenario 07 pushes anything:
the ArgoCD check reads the app's last operation.

## Commands
```bash
argocd app get lab-environment --core -o json | jq -r '.status.operationState.syncResult.resources[] | select(.hookPhase) | select(.syncPhase=="PreSync") | "\(.syncPhase) \(.kind)/\(.name) \(.hookPhase)"'
kubectl -n lab-environment logs job/db-init
demo-evidence schema-migration
```

## Expected result
PreSync lists `ServiceAccount/db-init`, `ConfigMap/db-init-sql`,
`Job/db-init`, all `Succeeded`; the job log shows `applying customers.sql`,
`vets.sql`, `visits.sql`; owners count unchanged.

## Evidence
- **ArgoCD:** `db-init` ran as `PreSync/Succeeded` in the sync of 02's commit.
- **Kubernetes:** job completion time precedes the first new customers pod.
- **Postgres:** owners count identical before and after (idempotent SQL).

## Talking points
- Apps run with `SPRING_SQL_INIT_MODE=never`; schema is owned by one Job,
  not raced by five replicas.
- Idempotent by construction: `CREATE TABLE IF NOT EXISTS`, `ON CONFLICT DO
  NOTHING`, `setval(...)` so sequences never rewind over app rows —
  covered by `tests/test-db-init.sh` against a throwaway postgres.
- Pitfall hit: hook pods run before the same sync applies normal resources,
  so the Job's ServiceAccount and SQL ConfigMap are themselves PreSync hooks
  at wave -1. Tidying the Job to -1 too would remove the ordering.
- Honest limit: this is idempotent SQL, not versioned migrations (no
  Flyway/Liquibase) — an accepted gap.

## Reset
`demo-reset schema-migration` — verifies the baseline.
```

- [ ] **Step 5: Commit the files (no push yet), STOP for confirmation of the live demo push**

```bash
git pull --rebase --autostash
git add k3s/apps/lab-environment/demo/scenarios/rolling-update.sh k3s/apps/lab-environment/demo/scenarios/schema-migration.sh docs/demo/02-rolling-update.md docs/demo/03-schema-migration.md
git commit -m "docs(demo): add the rolling-update and schema-migration scenarios

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git push
```
Tell the user the next step pushes a `demo:` commit that rolls customers-service; wait for confirmation.

- [ ] **Step 6: Run 02 then 03 live, exactly as written**

Expected: both `== OK`. Record the rollout duration and generator totals in the ledger. If the envoy non-2xx piece fails, list the offending lines (`loki_by response_code ...`) and investigate before touching the check.

- [ ] **Step 7: Reset**

Run: `demo-reset rolling-update && demo-reset schema-migration`
Expected: `baseline OK` twice. (The demo commit stays for Task 8.)

---

### Task 8: Scenario 07 — GitOps self-heal and rollback

**Files:**
- Create: `k3s/apps/lab-environment/demo/scenarios/gitops-selfheal-rollback.sh`
- Create: `docs/demo/07-gitops-selfheal-rollback.md`

**Interfaces:**
- Consumes: Task 7's commit `demo: rolling-restart customers-service`.
- Produces: commit `Revert "demo: rolling-restart customers-service"`.

- [ ] **Step 1: Write the scenario file**

```bash
# 07 — selfHeal undoes a manual change; git revert is the rollback.
evidence_gitops_selfheal_rollback() {
  local ev ok revert deployed live gitrev
  ev=$(kubectl -n "$NS" get events --field-selector involvedObject.name=customers-service,reason=ScalingReplicaSet -o json \
    | jq -r --arg s "$(iso "$WINDOW_START")" '.items[] | select((.lastTimestamp // .eventTime) >= $s) | .message')
  echo "$ev" | sed 's/^/      /'
  ok=0; echo "$ev" | grep -qE 'Scaled down .* to 1( |$)' && echo "$ev" | grep -qE 'Scaled up .* to 5 from 1' && ok=1
  rec_if kubernetes "manual scale to 1, then restored to 5 by ArgoCD selfHeal" [ $ok = 1 ]
  revert=$(git -C "$REPO_ROOT" log -1 --grep='^Revert "demo: rolling-restart customers-service"$' --format=%H)
  deployed=$(argocd app get lab-environment --core -o json \
    | jq -r --arg s "$(iso "$WINDOW_START")" '[.status.history[] | select(.deployedAt >= $s) | .revision] | join(" ")')
  ok=0; [ -n "$revert" ] && [[ " $deployed " == *" $revert "* ]] && ok=1
  rec_if argocd "ArgoCD deployed the revert ${revert:0:7} inside the window" [ $ok = 1 ]
  live=$(kubectl -n "$NS" get deploy customers-service -o jsonpath='{.spec.template.metadata.annotations.lab\.jerome/rollout-rev}')
  gitrev=$(grep -oP 'lab.jerome/rollout-rev: "\K[0-9]+' "$LAB_K8S/customers-service.yaml")
  rec_if kubernetes "live rollout-rev $live equals git's $gitrev after the revert" [ "$live" = "$gitrev" ]
}

reset_gitops_selfheal_rollback() {
  kubectl -n "$NS" rollout status deploy/customers-service --timeout=6m
}
```

- [ ] **Step 2: Write the runbook page**

```markdown
# 07 — GitOps self-heal and rollback

## Purpose
Show that git is the only way to change the lab: a manual change is undone
within seconds, and rollback is a `git revert`, not a `kubectl` command.

## Preconditions
Scenario 02's `demo:` commit is on `main` and deployed.

## Commands
```bash
git pull --ff-only
demo-window start gitops-selfheal-rollback
# 1. Drift: someone scales by hand
kubectl -n lab-environment scale deploy/customers-service --replicas=1
kubectl -n lab-environment get deploy customers-service -w    # Ctrl-C when READY is 5/5 again
# 2. Rollback: revert 02's commit through git
SHA=$(git log -1 --grep='^demo: rolling-restart customers-service$' --format=%H)
git show --stat $SHA
git revert --no-edit $SHA
git push
argocd app get lab-environment --core --refresh >/dev/null
kubectl -n lab-environment rollout status deploy/customers-service --timeout=6m
demo-window stop gitops-selfheal-rollback
demo-evidence gitops-selfheal-rollback
```

## Expected result
The Deployment drops to 1 and ArgoCD scales it back to 5 within seconds.
The revert rolls the pods again and restores the previous `rollout-rev`.

## Evidence
- **Kubernetes:** `ScalingReplicaSet` events — down to 1, then up to 5.
- **ArgoCD:** the revert commit in the app history inside the window.
- **Kubernetes:** live `rollout-rev` equals git's.

## Talking points
- `selfHeal: true` makes git the source of truth for *runtime* state, not
  just for deploys; drift is a bug, not an emergency lever.
- Rollback = `git revert`: audited, reviewable, and the same pipeline as a
  deploy. There is no out-of-band "undo" path to forget about.
- The manual scale-down briefly violated the PDB's intent (`scale` does not
  consult PDBs — only evictions do); selfHeal is what bounded the damage.

## Reset
`demo-reset gitops-selfheal-rollback` — waits for the rollout, verifies the baseline.
```

- [ ] **Step 3: Commit, push the docs, STOP for confirmation of the live push**

```bash
git pull --rebase --autostash
git add k3s/apps/lab-environment/demo/scenarios/gitops-selfheal-rollback.sh docs/demo/07-gitops-selfheal-rollback.md
git commit -m "docs(demo): add the GitOps self-heal and rollback scenario

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git push
```

- [ ] **Step 4: Run live exactly as written, then reset**

Expected: `== OK: 3 passed (3 infrastructure-layer)`; record self-heal latency (scale → 5/5) and any generator errors during the scale-down in the ledger. Then `demo-reset gitops-selfheal-rollback` → `baseline OK`.

---

### Task 9: Scenario 04 — zero trust

**Files:**
- Create: `k3s/apps/lab-environment/demo/scenarios/zero-trust.sh`
- Create: `docs/demo/04-zero-trust.md`

- [ ] **Step 1: Write the scenario file**

```bash
# 04 — mTLS, identity-based authorization, actuator lockdown.
evidence_zero_trust() {
  local range=$(( WINDOW_END - WINDOW_START )) n denied rej
  n=$(loki_count '{service="istio-proxy"} | json | response_code="403"' "$WINDOW_START" "$WINDOW_END")
  rec_if envoy "403s logged at ingress/waypoint: $n (want >= 2: wrong caller, actuator)" [ "$n" -ge 2 ]
  denied=$(prom "sum(increase(envoy_http_rbac{authz_enforce_result=\"denied\"}[${range}s]))" "$WINDOW_END")
  rec_if envoy "Envoy RBAC enforce denials: $denied (want > 0)" awk "BEGIN { exit !(\"$denied\" != \"none\" && $denied + 0 > 0) }"
  rej=$(kubectl -n istio-system logs -l app=ztunnel --tail=-1 --since-time="$(iso "$WINDOW_START")" | grep -c 'policy rejection' || true)
  rec_if ztunnel "ztunnel L4 policy rejections: $rej (want >= 1: pod-IP bypass, postgres)" [ "$rej" -ge 1 ]
}

reset_zero_trust() {
  kubectl -n default delete pod mtls-probe --ignore-not-found
}
```
If `denied` is `none`, the awk expression receives a bare word; guard it by testing `"$denied" != "none"` first as written.

- [ ] **Step 2: Write the runbook page**

```markdown
# 04 — Zero trust: mTLS, identity authz, actuator lockdown

## Purpose
Show that the network grants nothing by default: callers are authorized by
workload identity (SPIFFE), at L7 in the waypoint and at L4 in ztunnel.

## Preconditions
Preflight passed.

## Commands
```bash
demo-window start zero-trust
# a. Right network, wrong identity: the generator may not call customers-service
kubectl -n lab-environment exec deploy/traffic-generator -- curl -s -o /dev/null -w 'wrong caller -> %{http_code}\n' http://customers-service:8081/owners
# b. Actuator is locked at the edge
curl -s -o /dev/null -w 'actuator via ingress -> %{http_code}\n' http://10.0.0.95:30097/actuator/env
# c. Plaintext from outside the mesh to a STRICT pod
CIP=$(kubectl -n lab-environment get pod -l app=customers-service -o jsonpath='{.items[0].status.podIP}')
kubectl run -n default mtls-probe --rm -i --restart=Never --image=curlimages/curl:8.10.1 -- curl -s -m 5 -o /dev/null -w 'plaintext from outside the mesh -> %{http_code}\n' http://$CIP:8081/actuator/health; echo "exit=$?"
# d. Inside the mesh, bypassing the waypoint by pod IP
kubectl -n lab-environment exec deploy/traffic-generator -- curl -s -m 5 -o /dev/null http://$CIP:8081/owners; echo "pod IP bypass exit=$?"
# e. Data stores accept only their clients
kubectl -n lab-environment exec deploy/traffic-generator -- curl -s -m 5 http://postgres:5432; echo "postgres exit=$?"
demo-window stop zero-trust
demo-evidence zero-trust
```

## Expected result
a `403`; b `403`; c `000` with non-zero exit; d exit `56` (reset); e exit
`56` (an allowed TCP connect to postgres would give `52` — connected, empty reply).

## Evidence
- **Envoy:** 403s in the ingress/waypoint access log; `envoy_http_rbac`
  denied counter increased.
- **ztunnel:** access log `connection closed due to policy rejection` for
  the pod-IP and postgres attempts.

## Talking points
- Policy is keyed on ServiceAccount principals, not IPs or labels. Every
  business workload has its own SA because the namespace-wide `sa/default`
  (postgres, redis, consul, grafana...) would make any policy on it too broad.
- Two layers: L7 policies in the waypoint (paths, methods, principals), L4
  in ztunnel (who may open a connection at all). The pod-IP call proves the
  waypoint cannot be bypassed.
- Pitfall: ztunnel exposes **no** authorization metrics — an L4 dry run gave
  no signal, so L4 was rolled out in stages and is observed by effect (exit
  56 vs 52, the ztunnel access log). The L7 layer was dry-run first
  (`envoy_http_rbac` shadow denials over a 15-minute window).
- Probes were not affected by STRICT mTLS — measured, not assumed.

## Reset
`demo-reset zero-trust` — removes a leftover probe pod, verifies the baseline.
```

- [ ] **Step 3: Run live, reset, commit, push**

Expected: the curl results listed above and `== OK: 3 passed (3 infrastructure-layer)`. Then:
```bash
demo-reset zero-trust
git pull --rebase --autostash
git add k3s/apps/lab-environment/demo/scenarios/zero-trust.sh docs/demo/04-zero-trust.md
git commit -m "docs(demo): add the zero-trust scenario

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git push
```

---

### Task 10: Scenario 05 — app-level vs mesh-level resilience

**Files:**
- Create: `k3s/apps/lab-environment/demo/scenarios/app-vs-mesh-resilience.sh`
- Create: `docs/demo/05-app-vs-mesh-resilience.md`

- [ ] **Step 1: Write the scenario file**

```bash
# 05 — the same Redis timeout seen through Envoy's timeouts and the
# gateway's Resilience4j circuit breaker.
evidence_app_vs_mesh_resilience() {
  local range=$(( WINDOW_END - WINDOW_START )) ut cust vis ok cb trace
  ut=$(loki_by upstream_cluster '{service="istio-proxy"} | json | response_flags="UT"' "$WINDOW_START" "$WINDOW_END")
  echo "$ut" | sed 's/^/      /'
  cust=$(echo "$ut" | grep -c 'customers-service' || true)
  vis=$(echo "$ut" | grep -c 'visits-service' || true)
  ok=0; [ "$cust" -ge 1 ] && [ "$vis" -ge 1 ] && ok=1
  rec_if envoy "UT logged against both customers-service and visits-service (the reporting hop is not only the faulty one)" [ $ok = 1 ]
  cb=$(prom "sum(increase(resilience4j_circuitbreaker_calls_seconds_count{service=\"api-gateway\", kind!=\"successful\"}[${range}s]))" "$WINDOW_END")
  rec_if app "api-gateway circuit-breaker non-successful calls: $cb (want > 0)" awk "BEGIN { exit !(\"$cb\" != \"none\" && $cb + 0 > 0) }"
  trace=$(curl -sf -G "$JAEGER/api/traces" --data-urlencode service=api-gateway \
    --data-urlencode "start=${WINDOW_START}000000" --data-urlencode "end=${WINDOW_END}000000" \
    --data-urlencode minDuration=900ms --data-urlencode limit=1 | jq -r '.data[0].traceID // empty')
  rec_if app "slow api-gateway trace in Jaeger: ${trace:-none}" [ -n "$trace" ]
  if [ -n "$trace" ]; then note "$(jaeger_spans "$trace")"; fi
}

reset_app_vs_mesh_resilience() {
  local i slow=0 r
  curl -sf -X PUT -d false "$CONSUL/v1/kv/chaos/visits-service/redis-timeout" >/dev/null
  sleep 10   # the fork's ChaosToggleWatcher polls every 5 s
  for i in $(seq 1 10); do
    r=$(curl -s -o /dev/null -w '%{http_code} %{time_total}' "$INGRESS/api/customer/owners/6/visits")
    case $r in "200 0."*) ;; *) slow=$((slow + 1)) ;; esac
  done
  [ $slow -eq 0 ] || { echo "visits path still degraded after reset: $slow/10 slow or failed"; return 1; }
}
```

- [ ] **Step 2: Write the runbook page**

```markdown
# 05 — App-level vs mesh-level resilience

## Purpose
Inject one fault (visits-service's Redis times out) and show two resilience
layers reacting differently: the gateway's Resilience4j fallback returns
200, Envoy's per-try timeout returns 504 — and the 504 is logged one hop
away from the cause.

## Preconditions
Preflight passed.

## Commands
```bash
demo-window start app-vs-mesh-resilience
curl -s -X PUT -d true http://10.0.0.95:30092/v1/kv/chaos/visits-service/redis-timeout; echo
sleep 10
for i in 1 2 3 4 5; do curl -s -o /dev/null -w 'gateway aggregation   %{http_code} %{time_total}s\n' http://10.0.0.95:30097/api/gateway/owners/6; done
for i in 1 2 3 4 5; do curl -s -o /dev/null -w 'customers aggregation %{http_code} %{time_total}s\n' http://10.0.0.95:30097/api/customer/owners/6/visits; done
demo-window stop app-vs-mesh-resilience
demo-reset app-vs-mesh-resilience
demo-evidence app-vs-mesh-resilience
```
(The reset runs before the evidence on purpose: the toggle must not stay on
while the evidence queries run.)

## Expected result
Gateway aggregation: `200` at ~1.03 s (visits omitted by the fallback).
Customers aggregation: `504` at ~1.01 s. Reset prints `baseline OK`.

## Evidence
- **Envoy:** `UT` (upstream timeout) at 1000 ms against `visits-service:8082`
  **and** against `customers-service:8081`.
- **App:** Resilience4j non-successful calls increased on api-gateway.
- **App (Jaeger):** a ≥ 900 ms api-gateway trace showing where the time went.

## Talking points
- Same fault, two answers, decided by *where the timeout sits*: the gateway
  path has an app-level fallback; the customers path only has the mesh's
  1 s `perTryTimeout`.
- **The reporting hop is not the faulty hop.** The 504 on the customers
  route is logged against `customers-service:8081` because customers was
  waiting on visits — an investigator reading only that line stops one hop
  short.
- The 1 s per-try timeout truncates every timeout-shaped symptom, so the
  injected delay's size is invisible in latency; nothing is retried
  (`retryOn` excludes timeouts and 5xx by design).
- The circuit breaker wraps only the visits call: a customers outage surfaces
  as Spring's default 500, not as a fallback. Knowing what is *not*
  protected is part of the design.
- Earlier misreading: a 6-minute aggregate of the generator log blamed the
  wrong scenario; per-scenario windows (what `demo-window` records) settled it.

## Reset
Already run inside the commands; `demo-reset app-vs-mesh-resilience` is
safe to repeat.
```

- [ ] **Step 3: Run live, commit, push**

Expected: the curl lines above and `== OK: 3 passed (1 infrastructure-layer)`. If the Resilience4j piece is `none`, list `resilience4j_circuitbreaker_calls_seconds_count{service="api-gateway"}` label sets in Prometheus and use the observed `kind` values — record the change in the ledger.
```bash
git pull --rebase --autostash
git add k3s/apps/lab-environment/demo/scenarios/app-vs-mesh-resilience.sh docs/demo/05-app-vs-mesh-resilience.md
git commit -m "docs(demo): add the app-vs-mesh resilience scenario

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git push
```

---

### Task 11: Scenario 06 — secret rotation

**Files:**
- Modify: `k3s/apps/lab-environment/k8s/vets-service.yaml`, `k3s/apps/lab-environment/k8s/visits-service.yaml` (add `lab.jerome/rollout-rev: "1"`)
- Modify: `k3s/apps/lab-environment/README.md` (rotation procedure + verification path)
- Create: `k3s/apps/lab-environment/demo/scenarios/secret-rotation.sh`
- Create: `docs/demo/06-secret-rotation.md`

**Interfaces:**
- Produces: commits `demo: rotate lab-db-credentials` and `demo: roll services onto the rotated DB password`.

Facts this task is built on (verified 2026-09-27):
- `psql -h postgres` from inside the postgres pod is now **reset by ztunnel** (postgres' own `sa/default` is not an allowed client), so the README's "verify over `psql -h postgres`" no longer reaches authentication. Connecting to the pod's own IP reaches the `host all all all scram-sha-256` line and gives a real `password authentication failed`.
- The `db-init` PreSync hook authenticates with the Secret over scram on every `lab-environment` sync. Therefore the Secret must already hold the new password, and the database must already accept it, before any commit that syncs `lab-environment`.
- The apps read the password from env at start; changing the Secret alone restarts nothing.

- [ ] **Step 1: Add rollout-rev to vets and visits**

In each file's pod template `annotations:` (after `prometheus.io/path`):
```yaml
        # Bump to roll the pods without a new image (e.g. after a secret rotation).
        lab.jerome/rollout-rev: "1"
```

- [ ] **Step 2: Correct the README's rotation paragraph**

Replace the rotation sentence and the `psql -h postgres` advice in `k3s/apps/lab-environment/README.md` with:
```markdown
To rotate: reseal the new password and push it (the Secret changes, nothing
restarts), `ALTER USER` to the new password, then bump `lab.jerome/rollout-rev`
on customers/vets/visits and push — in that order, because the `db-init`
PreSync hook authenticates with the Secret on every sync. Step by step:
[docs/demo/06-secret-rotation.md](../../../docs/demo/06-secret-rotation.md).
Verify against the pod's own IP (`psql -h $(hostname -i)` inside the postgres
pod): that path hits the scram line. `psql -h postgres` from the same pod is
now reset by ztunnel (postgres' `sa/default` is not an allowed client) and
the local socket matches `trust`, so neither proves anything.
```

- [ ] **Step 3: Write the scenario file**

```bash
# 06 — rotate the DB password through SealedSecrets and git.
OLD_PW_FILE_NAME=secret-rotation.old

start_secret_rotation() {
  ( umask 077; kubectl -n "$NS" get secret lab-db-credentials -o jsonpath='{.data.password}' | base64 -d > "$STATE_DIR/$OLD_PW_FILE_NAME" )
}

# Prints accepted / rejected / inconclusive for a password, over scram.
scram_try() {
  local user out
  user=$(kubectl -n "$NS" get secret lab-db-credentials -o jsonpath='{.data.username}' | base64 -d)
  out=$(kubectl -n "$NS" exec -i deploy/postgres -- sh -c \
    'read -r P; PGPASSWORD="$P" psql -h "$(hostname -i)" -U "$1" -d customers -tAc "select 1" 2>&1' _ "$user" <<< "$1" || true)
  case $out in
    1) echo accepted ;;
    *"password authentication failed"*) echo rejected ;;
    *) echo inconclusive ;;
  esac
}

evidence_secret_rotation() {
  local hist upd ok old new created d want c total bad
  hist=$(argocd app get sealed-secrets --core -o json \
    | jq -r --arg s "$(iso "$WINDOW_START")" '[.status.history[] | select(.deployedAt >= $s)] | length')
  rec_if argocd "sealed-secrets app deployments inside the window: $hist (want >= 1)" [ "$hist" -ge 1 ]
  upd=$(kubectl -n "$NS" get sealedsecret lab-db-credentials -o json \
    | jq -r '.status.conditions[] | select(.type == "Synced") | "\(.status) \(.lastUpdateTime)"')
  ok=0; [ "${upd%% *}" = True ] && [[ "${upd#* }" > "$(iso "$WINDOW_START")" ]] && ok=1
  rec_if sealed-secrets "controller re-unsealed lab-db-credentials in the window: $upd" [ $ok = 1 ]
  old=$(scram_try "$(cat "$STATE_DIR/$OLD_PW_FILE_NAME")")
  new=$(scram_try "$(kubectl -n "$NS" get secret lab-db-credentials -o jsonpath='{.data.password}' | base64 -d)")
  ok=0; [ "$old" = rejected ] && [ "$new" = accepted ] && ok=1
  rec_if postgres "over scram: old password $old, new password $new" [ $ok = 1 ]
  ok=1
  for d in customers-service vets-service visits-service; do
    want=$(git_replicas "$d")
    c=$(kubectl -n "$NS" get pods -l app="$d" -o json | jq --arg s "$(iso "$WINDOW_START")" \
      '[.items[] | select(.metadata.creationTimestamp >= $s) | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length')
    note "$d: $c/$want pods restarted onto the new Secret"
    [ "$c" -eq "$want" ] || ok=0
  done
  rec_if kubernetes "all three DB clients restarted in the window and Ready" [ $ok = 1 ]
  total=$(loki_count '{service="traffic-generator"}' "$WINDOW_START" "$WINDOW_END")
  bad=$(loki_count '{service="traffic-generator"} !~ " 200 "' "$WINDOW_START" "$WINDOW_END")
  note "generator during the rotation: $total requests, $bad non-200 (the measured error window)"
}

reset_secret_rotation() {
  rm -f "$STATE_DIR/$OLD_PW_FILE_NAME"
  local st
  st=$(argocd app get sealed-secrets --core -o json | jq -r '.status.sync.status + "/" + .status.health.status')
  [ "$st" = "Synced/Healthy" ] || { echo "sealed-secrets is $st"; return 1; }
  for d in customers-service vets-service visits-service; do kubectl -n "$NS" rollout status deploy/$d --timeout=8m; done
}
```

- [ ] **Step 4: Write the runbook page**

```markdown
# 06 — Secret rotation

## Purpose
Rotate the database password end to end — sealed in git, unsealed in the
cluster, switched in Postgres, rolled into the apps — without the password
ever touching git, a process list or the API audit trail in plaintext.

## Preconditions
Preflight passed; `kubeseal` on the PATH; working tree clean.

## Commands
```bash
git pull --ff-only
demo-window start secret-rotation
# 1. Seal a new password and ship it through git. The Secret changes; nothing restarts.
NEW=$(openssl rand -base64 24 | tr -d '/+=')
U=$(kubectl -n lab-environment get secret lab-db-credentials -o jsonpath='{.data.username}' | base64 -d)
kubectl -n lab-environment create secret generic lab-db-credentials \
  --from-literal=username="$U" --from-literal=password="$NEW" --dry-run=client -o yaml \
  | kubeseal --controller-namespace sealed-secrets --controller-name sealed-secrets --format yaml \
  > k3s/sealed-secrets/secrets/lab-db-credentials.sealed.yaml
git diff --stat
git commit -m "demo: rotate lab-db-credentials" -- k3s/sealed-secrets/secrets/lab-db-credentials.sealed.yaml
git push
argocd app get sealed-secrets --core --refresh >/dev/null
until [ "$(kubectl -n lab-environment get secret lab-db-credentials -o jsonpath='{.data.password}' | base64 -d)" = "$NEW" ]; do sleep 5; done; echo "Secret updated"
# 2. Switch Postgres to the new password (via stdin, never on a command line).
printf 'ALTER USER "%s" PASSWORD '"'"'%s'"'"';\n' "$U" "$NEW" | kubectl -n lab-environment exec -i deploy/postgres -- psql -U "$U" -d postgres
# 3. Roll the three DB clients onto the new env.
for d in customers-service vets-service visits-service; do
  F=k3s/apps/lab-environment/k8s/$d.yaml
  cur=$(grep -oP 'lab.jerome/rollout-rev: "\K[0-9]+' $F)
  sed -i "s|lab.jerome/rollout-rev: \"$cur\"|lab.jerome/rollout-rev: \"$((cur + 1))\"|" $F
done
git commit -m "demo: roll services onto the rotated DB password" -- k3s/apps/lab-environment/k8s/{customers,vets,visits}-service.yaml
git push
argocd app get lab-environment --core --refresh >/dev/null
for d in customers-service vets-service visits-service; do kubectl -n lab-environment rollout status deploy/$d --timeout=8m; done
unset NEW
demo-window stop secret-rotation
demo-evidence secret-rotation
```

## Expected result
`Secret updated`, `ALTER ROLE`, three completed rollouts. Evidence: old
password rejected, new accepted, all three clients restarted.

## Evidence
- **ArgoCD:** a sealed-secrets app deployment inside the window.
- **sealed-secrets:** the SealedSecret's `Synced` condition updated in the window.
- **Postgres (scram path):** old password rejected, new accepted.
- **Kubernetes:** every customers/vets/visits pod restarted in the window.
- Note: generator errors in the window — the measured cost of the rotation.

## Talking points
- Order is forced by the platform, not chosen: the `db-init` PreSync hook
  authenticates with the Secret on **every** sync, so the Secret and the
  database must both be on the new password before `lab-environment` syncs.
- Between step 2 and the end of step 3, old pods keep working on pooled
  connections (Hikari max 5); only a *new* connection with the old password
  fails. The note line is that window, measured.
- Verification pitfall: inside the postgres pod the local socket is `trust`
  and `-h postgres` is now reset by ztunnel — only the pod's own IP reaches
  the scram line. A check that "passes" on the wrong path proves nothing.
- The old plaintext password was rotated out of Consul KV in sub-project 1;
  no KV key contains a password.

## If interrupted
- After step 1 only: the next `lab-environment` sync's `db-init` fails
  authentication and the sync stalls. Finish step 2 (ALTER USER to the value
  now in the Secret: `kubectl -n lab-environment get secret lab-db-credentials
  -o jsonpath='{.data.password}' | base64 -d`), then step 3.
- After step 2: old pods keep running on pooled connections; finish step 3.

## Reset
`demo-reset secret-rotation` — deletes the saved old password, checks the
sealed-secrets app, waits for the three rollouts, verifies the baseline.
The rotation itself is not undone: the new password is simply current.
```

- [ ] **Step 5: Commit the prep (rollout-rev + README + files), STOP for confirmation, push**

The rollout-rev addition changes vets/visits pod templates → both roll once.
```bash
git pull --rebase --autostash
git add k3s/apps/lab-environment/k8s/vets-service.yaml k3s/apps/lab-environment/k8s/visits-service.yaml k3s/apps/lab-environment/README.md k3s/apps/lab-environment/demo/scenarios/secret-rotation.sh docs/demo/06-secret-rotation.md
git commit -m "docs(demo): add the secret-rotation scenario

vets and visits get the rollout-rev annotation customers already has, so
a rotation can roll all three DB clients through git. The README's
verification advice is corrected: -h postgres from the postgres pod is
now reset by ztunnel and never reaches scram.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
Ask the user, then `git push`; wait for vets/visits to finish rolling and `demo-reset preflight` → `baseline OK`.

- [ ] **Step 6: STOP for confirmation, then run the rotation live exactly as written**

Expected: `== OK` with 4 passed (3 infrastructure-layer). Record the generator error window from the note line in the ledger and in the page's "Expected result" if non-zero.

- [ ] **Step 7: Reset**

Run: `demo-reset secret-rotation` → `baseline OK`.

---

### Task 12: Scenario 08 — load test

**Files:**
- Create: `k3s/apps/lab-environment/demo/load/k6-steps.js`
- Create: `k3s/apps/lab-environment/demo/scenarios/load-test.sh`
- Create: `docs/demo/08-load-test.md`

- [ ] **Step 1: Write the k6 script**

```javascript
// Stepped open-model load: the arrival rate is fixed per step whatever the
// latency, so the knee shows as P99 departing while RPS keeps its target.
// Hard cap: 80 req/s, 80 VUs, 6 minutes.
import http from 'k6/http';

const BASE = __ENV.TARGET || 'http://10.0.0.95:30097';
const PATHS = ['/api/customer/owners', '/api/gateway/owners/6', '/api/vet/vets', '/api/customer/owners/3'];

export const options = {
  scenarios: {
    steps: {
      executor: 'ramping-arrival-rate',
      startRate: 5,
      timeUnit: '1s',
      preAllocatedVUs: 20,
      maxVUs: 80,
      stages: [
        { target: 5, duration: '1m' },
        { target: 10, duration: '1m' },
        { target: 20, duration: '1m' },
        { target: 40, duration: '1m' },
        { target: 60, duration: '1m' },
        { target: 80, duration: '1m' },
      ],
    },
  },
  summaryTrendStats: ['med', 'p(95)', 'p(99)', 'max'],
};

export default function () {
  http.get(BASE + PATHS[Math.floor(Math.random() * PATHS.length)], { timeout: '10s' });
}
```

- [ ] **Step 2: Write the scenario file**

```bash
# 08 — capacity baseline: where P99 departs, and what saturated.
evidence_load_test() {
  local range=$(( WINDOW_END - WINDOW_START )) rps p99 pts node thr ok alert
  rps=$(curl -sf -G "$PROM/api/v1/query_range" \
    --data-urlencode 'query=sum(rate(istio_requests_total{reporter="waypoint", destination_canonical_service="api-gateway"}[1m]))' \
    --data-urlencode "start=$WINDOW_START" --data-urlencode "end=$WINDOW_END" --data-urlencode step=60 \
    | jq -r '.data.result[0].values[]? | "\(.[0] | todate[11:16]) \(.[1] | tonumber | floor)"')
  p99=$(curl -sf -G "$PROM/api/v1/query_range" \
    --data-urlencode 'query=histogram_quantile(0.99, sum by (le) (rate(istio_request_duration_milliseconds_bucket{reporter="waypoint", destination_canonical_service="api-gateway"}[1m])))' \
    --data-urlencode "start=$WINDOW_START" --data-urlencode "end=$WINDOW_END" --data-urlencode step=60 \
    | jq -r '.data.result[0].values[]? | "\(.[0] | todate[11:16]) \(.[1])"')
  echo "      minute  rps   p99(ms)"
  join <(echo "$rps") <(echo "$p99") | awk '{printf "      %s  %4s  %s\n", $1, $2, $3}'
  pts=$(echo "$p99" | grep -c . || true)
  rec_if envoy "waypoint RPS and P99 per minute over the run: $pts points (want >= 5)" [ "$pts" -ge 5 ]
  node=$(prom "max_over_time(sum(rate(container_cpu_usage_seconds_total{id=\"/\", node=\"vps-oracle2\"}[1m]))[${range}s:30s])" "$WINDOW_END")
  thr=$(prom "max_over_time(max(rate(container_cpu_cfs_throttled_periods_total{namespace=\"lab-environment\", container!=\"\"}[1m]) / rate(container_cpu_cfs_periods_total{namespace=\"lab-environment\", container!=\"\"}[1m]))[${range}s:30s])" "$WINDOW_END")
  ok=0; awk "BEGIN { exit !((\"$node\" != \"none\" && $node + 0 >= 1.6) || (\"$thr\" != \"none\" && $thr + 0 >= 0.5)) }" && ok=1
  rec_if cadvisor "peak node CPU $node of 2 cores; peak container throttling $thr (want node >= 1.6 or throttling >= 0.5)" [ $ok = 1 ]
  alert=$(curl -sf "$GRAFANA/api/prometheus/grafana/api/v1/alerts" | jq -r '[.data.alerts[] | select(.labels.alertname == "Lab CPU Throttling") | .state] | join(",")')
  note "Lab CPU Throttling alert state: ${alert:-inactive} (needs 10 min sustained; a 6-min run usually leaves it pending)"
}

reset_load_test() {
  docker rm -f lab-k6 >/dev/null 2>&1 || true
}
```

- [ ] **Step 3: Write the runbook page**

```markdown
# 08 — Load test: capacity baseline and bottleneck

## Purpose
Find the request rate at which P99 departs, and prove from the platform's
own metrics what saturated — a capacity number with a cause, not a guess.

## Preconditions
Scenarios 01–06 are done (this overloads the node; nothing runs after it).
**This will likely fire the production `Lab API Down` alert (Telegram)** —
a real load test runs under real alerting. The load comes from vps_oracle:
a generator on vps-oracle2 would share the 2 cores it is measuring.

## Commands
```bash
demo-window start load-test
docker run --rm --name lab-k6 --network host \
  -v "$PWD/k3s/apps/lab-environment/demo/load:/scripts:ro" \
  grafana/k6:2.3.0 run /scripts/k6-steps.js
demo-window stop load-test
demo-evidence load-test
```
(`--network host`: a Docker-bridge container cannot reach a k3s NodePort
on this host — see `vps_oracle/host-native/npm-nodeport-relay/`.)

## Expected result
k6 steps 5 → 80 req/s over 6 minutes. The evidence table shows RPS
tracking the target while P99 stays flat, then P99 climbing from one step
on — that step is the knee. The cAdvisor line names what saturated.

## Evidence
- **Envoy:** waypoint RPS and P99 per minute for api-gateway.
- **cAdvisor:** peak node CPU on vps-oracle2 and peak per-container
  throttling. Five 1000m-limit JVMs on 2 cores usually saturate the node
  before any single container hits its limit.
- Notes: the `Lab CPU Throttling` state; k6's own summary above.
- Grafana → Lab Mesh Overview: P99 panel and the capacity row.

## Talking points
- Open model (fixed arrival rate): a closed model would slow its own
  request rate as latency grows and hide the knee.
- Knee → headroom: steady traffic is ~1 req/s; the knee is the number
  capacity planning starts from.
- What the lab cannot show yet, and why: overload protection (rate limiting
  and outlier ejection shielding `/api/vet/vets`) is sub-project 2c;
  horizontal autoscaling is blocked because the node's CPU requests are
  already near its 2 cores.
- If the bottleneck is not CPU, the evidence fails on purpose — the runbook
  then records what it actually was.

## Reset
`demo-reset load-test` — removes a leftover k6 container, verifies the
baseline (JVMs may need a minute to settle).
```

- [ ] **Step 4: Run live**

Run the page's commands. Expected: `== OK: 2 passed (2 infrastructure-layer)`.
If P99 never departs within 80 req/s, raise the last two stages (e.g. 120, 160 req/s, `maxVUs: 160`), note why in the script comment, and re-run. If the cAdvisor piece fails, the bottleneck is not CPU: check the Hikari pool (max 5) via `hikaricp_connections_pending` and Envoy `UO`/`UT` flags, then rewrite the page's talking points and the evidence to what it actually is. Record the measured knee in the page's "Expected result".

- [ ] **Step 5: Reset, commit, push**

```bash
demo-reset load-test
git pull --rebase --autostash
git add k3s/apps/lab-environment/demo/load/k6-steps.js k3s/apps/lab-environment/demo/scenarios/load-test.sh docs/demo/08-load-test.md
git commit -m "docs(demo): add the load-test scenario

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git push
```

---

### Task 13: Full rehearsal and close-out

**Files:**
- Create: `docs/demo/evidence/<scenario>.txt` (8 files, via `DEMO_SAVE_DIR`)
- Modify: `docs/superpowers/specs/2026-09-25-lab-sdlc-demo-roadmap.md` (2a status)
- Modify: `docs/superpowers/specs/2026-09-27-lab-demo-runbook-framework-design.md` (append "Implementation results")

- [ ] **Step 1: STOP — confirm the rehearsal with the user**

It pushes four `demo:` commits (02, 06 ×2) and one revert (07), rolls customers three times and vets/visits once, and fires the `Lab API Down` Telegram alert during 08.

- [ ] **Step 2: Rehearse 00 → 08 in the README's order, saving evidence**

```bash
export DEMO_SAVE_DIR=$PWD/docs/demo/evidence
```
Then run every page's Commands and Reset exactly as written, in order 00, 01, 02, 03, 07, 04, 05, 06, 08. Each `demo-evidence` must print `== OK` (it copies its output to `docs/demo/evidence/` only then).

- [ ] **Step 3: Pin Review Focus 1 — evidence survives a later commit**

After 07's revert has landed, re-run: `demo-evidence rolling-update`
Expected: still `== OK` (the ArgoCD piece reads history, not the live revision).

- [ ] **Step 4: Verify the baseline and the acceptance list**

```bash
demo-reset preflight
git log --oneline -8 | grep -E 'demo:|Revert "demo'
ls docs/demo/evidence/*.txt | wc -l
curl -s http://10.0.0.95:30094/api/prometheus/grafana/api/v1/rules | jq -r '.data.groups[] | select(.name=="lab_capacity") | .rules[] | "\(.name) \(.state)"'
curl -s -o /dev/null -w '%{http_code}\n' http://10.0.0.95:30115/metrics
bash k3s/apps/lab-environment/tests/test-demo-helpers.sh | tail -1
```
Expected: `baseline OK`; the demo commits and revert listed; `8`; five rules (state `inactive` once load-test's throttling has cleared); `200`; `ALL PASS`.

- [ ] **Step 5: Record results and update the roadmap**

Append to the 2a spec an `## Implementation results (<date>)` section: one table row per acceptance criterion (PASS/FAIL + evidence), the measured numbers (rollout duration, self-heal latency, rotation error window, load-test knee and saturating resource), and every deviation from this plan with its reason. In the roadmap, set row 2a's status to `**Done <date>**` with links to the spec and this plan, and move any findings that belong to 2b/2c into their notes.

- [ ] **Step 6: Commit and push**

```bash
git pull --rebase --autostash
git add docs/demo/evidence/ docs/superpowers/specs/2026-09-27-lab-demo-runbook-framework-design.md docs/superpowers/specs/2026-09-25-lab-sdlc-demo-roadmap.md
git commit -m "docs(demo): record the 2a rehearsal and mark the sub-project done

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git push
```
