# lab-environment Production Baseline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn `lab-environment` into a production-shaped K8s + Istio Ambient + config-center stack (multi-instance, K8s-native discovery, sealed secrets, resident resilience/authz policies) where every request is traceable through logs, traces and metrics.

**Architecture:** Staged rollout through GitOps (docker-gitops `main` → ArgoCD). App-side changes live in two sibling repos (the PetClinic fork and the MCP toolkit) and ship as immutable, SHA-tagged local images imported into vps-oracle2's containerd. Each stage is verified live before the next.

**Tech Stack:** k3s 1.36, ArgoCD 3.5, Istio 1.30.3 Ambient (ztunnel + waypoint + Gateway API v1.6.1 standard), SealedSecrets, Spring Boot 4.0.1 / Spring Cloud 2025.1.0, Python 3.12 + httpx (MCP toolkit), Prometheus 2.53, Grafana 11.1, Loki/Promtail 3.1, Jaeger all-in-one 1.60.

**Spec:** `docs/superpowers/specs/2026-09-25-lab-mesh-production-baseline-design.md`

## Global Constraints

- Repos: docker-gitops `/home/ubuntu/jerome/docker-gitops`; fork `/home/ubuntu/jerome/spring-petclinic-microservices`; toolkit `/home/ubuntu/jerome/ops-agent-toolkit-mcp`; lab `/home/ubuntu/jerome/lab-environment`.
- Lab manifests: `k3s/apps/lab-environment/k8s/` (plain directory Application `lab-environment`, automated `prune`/`selfHeal`, tracks `main`).
- **Git first**: never `kubectl apply/patch/edit/scale` anything ArgoCD manages. Edit → commit → push → `argocd app sync lab-environment` (run `kubectl config set-context --current --namespace=argocd && argocd login --core` once per shell if needed) → verify. The only exception is the throwaway `lab-spike*` namespaces in Task 1, which no Application manages.
- docker-gitops work happens on branch `lab-mesh-baseline` in worktree `/home/ubuntu/jerome/docker-gitops-lab-mesh`. **A push to `main` is a deploy that recreates containers: before every merge to `main`, show the diff summary to the user and get explicit confirmation.** Merge with `git -C /home/ubuntu/jerome/docker-gitops pull --ff-only && git merge --ff-only lab-mesh-baseline && git push` from the main checkout (rebase the branch first if `main` moved — other sessions commit to `main`).
- Fork, toolkit and lab repos: work on a feature branch (`k8s-native-discovery`, `k8s-service-health`, `lab-mesh-baseline` respectively). Merging them to their `main` needs the user's confirmation.
- Commit messages, code comments, docs: English only. One logical change per commit. End every commit message with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Every new container sets `TZ=Asia/Hong_Kong`. Every new lab Pod template carries label `trivy-operator.skip: "true"` (nothing consumes lab scan reports).
- Never add a toleration/nodeSelector for vps-oracle2 in manifests — the Kyverno mutate policy `lab-environment-on-oracle2` injects it for every Pod in `lab-environment`.
- Plaintext secrets never enter git; use `kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets --format yaml`.
- Images: `ops-lab/<service>:<12-char git sha>`; build on vps_oracle with `lab-environment/scripts/build.sh`, import with `lab-environment/scripts/push-to-k3s.sh`. Never reference `:dev` in manifests after Task 2.
- Replicas: `customers-service` 5, `api-gateway` 3, everything else 1.
- Service ports: api-gateway 8080, customers-service 8081, visits-service 8082, vets-service 8083.
- Retry policy (GET, internal hops only): `attempts: 2`, `perTryTimeout: 1s`, `retryOn: "connect-failure,refused-stream,unavailable,503"`, `timeout: 3s`. Non-GET: `attempts: 0`, `timeout: 5s`. Edge (api-gateway) never retries: `attempts: 0`, `timeout: 5s`.
- Outlier detection: `consecutive5xxErrors: 5, interval: 10s, baseEjectionTime: 30s, maxEjectionPercent: 50`. Connection pool: `tcp.maxConnections: 100, http.http1MaxPendingRequests: 100, http.http2MaxRequests: 200`.
- Waypoint and ingress proxies: 2 replicas each, requests `100m/128Mi`, limits `500m/256Mi`.
- vps-oracle2 memory guard: after every scale-up, `ssh vps-oracle2 free -m` must show `available` ≥ 1024 MB; otherwise stop and report.

## Review Focus

1. Kubernetes API returns 403/5xx to `get_service_health` → the tool must raise, never report `registered: False` (an RBAC bug must not look like "service gone"). Test in Task 9.
2. A service scaled to 0 → `registered: True`, `instance_count: 0`, not an exception. Test in Task 9.
3. Rows the app inserted after seeding survive a `db-init` rerun and the identity sequence is not reset (next insert does not collide). Test in Task 4.
4. All 5 customers pods deleted at once → the stack converges with no manual step; traffic-generator errors stop within 3 minutes. Check in Task 16.
5. Consul pod restarts → running business pods keep serving (config imported at startup, toggles keep last state); generator shows no 5xx. Check in Task 16.

---

## File map

**docker-gitops** (`k3s/apps/lab-environment/k8s/` unless noted)

| File | Responsibility | Task |
|---|---|---|
| `api-gateway.yaml`, `customers-service.yaml`, `vets-service.yaml`, `visits-service.yaml` | business Deployments/Services: image tag, env, SA, probes, strategy, replicas, prometheus annotations, waypoint labels | 2,3,4,5,7,10,11,12 |
| `postgres.yaml` | password from Secret | 3 |
| `db-init.yaml` (new) | idempotent schema/seed SQL ConfigMap + SA + PreSync Job | 4 |
| `tests/test-db-init.sh` (new, `k3s/apps/lab-environment/tests/`) | runs the db-init SQL against a throwaway postgres, twice | 4 |
| `prometheus.yaml`, `configmaps.yaml` | Prometheus SA/RBAC, pod SD, Envoy scrape; promtail JSON stage; Grafana datasources | 5,13 |
| `traffic-generator.yaml` (new) | resident ~2 rps browsing load | 6 |
| `pdb.yaml` (new) | PodDisruptionBudgets | 7 |
| `namespace.yaml` | quota; ambient label | 7,11 |
| `serviceaccounts.yaml` (new) | per-workload identities | 11 |
| `mcp-toolkit.yaml` | SA + Role for K8s health reads | 10 |
| `jaeger.yaml` | OTLP receiver + port 4317 | 11 |
| `waypoint.yaml` (new) | waypoint Gateway + params ConfigMap | 11 |
| `telemetry.yaml` (new) | tracing + access-log providers for the namespace | 11 |
| `ingress.yaml` (new) | ingress Gateway + params + HTTPRoute | 12 |
| `grafana.yaml`, `grafana-dashboards.yaml` (new) | dashboard mount + "Lab Mesh Overview" | 13 |
| `mtls.yaml`, `authz.yaml` (new) | PeerAuthentication STRICT, AuthorizationPolicies | 14 |
| `resilience.yaml` (new) | VirtualServices + DestinationRules | 15 |
| `k3s/istio/istiod-values.yaml` | `otel-lab` + `lab-json-accesslog` extension providers | 11 |
| `k3s/sealed-secrets/secrets/lab-db-credentials.sealed.yaml` (new), `.../README.md` | DB credentials | 3 |
| `k3s/apps/lab-environment/README.md` | current-state docs | 16 |

**fork**: gateway `ApiGatewayApplication.java`, `application/CustomersServiceClient.java`, `application/VisitsServiceClient.java`, `application.yml`, `pom.xml`, tests; customers `CustomersServiceApplication.java`, `config/RestTemplateConfig.java`, `web/VisitsServiceClient.java`, `application.yml`, `pom.xml`, test; vets/visits `*Application.java`, `pom.xml`; `CHANGES.md`. (Task 8)

**toolkit**: `settings.py`, `k8s.py` (new), `tools/discovery.py`, `tools/metrics.py`, `tests/` (new), `requirements-dev.txt` (new), `README.md`. (Task 9)

**lab**: `scripts/build.sh`, `scripts/push-to-k3s.sh` (new), `scripts/init-consul-kv.sh`, `CLAUDE.md`. (Tasks 2, 3, 8)

---

### Task 1: Verification spikes (throwaway namespaces)

Answers spec spikes 1, 3 and 8 before anything depends on them. Spikes 2 and 5 are gates inside Task 11, 4 inside Task 10, 6 inside Task 12, 7 inside Task 3. Nothing here is committed except the result notes.

**Files:**
- Create (scratch, not committed): `$SCRATCH/spike.yaml` where `SCRATCH=/tmp/claude-1001/-home-ubuntu-jerome-docker-gitops/c67e71ef-a1f5-4c3c-99a4-48fd2c7e583b/scratchpad`
- Modify: `docs/superpowers/specs/2026-09-25-lab-mesh-production-baseline-design.md` (append results under "Verification spikes")

**Interfaces:**
- Produces: confirmed (or refuted) mechanics for workload-selector STRICT, `infrastructure.parametersRef` (replicas/resources/NodePort), and ingress-HTTPRoute + waypoint-VirtualService coexistence via `istio.io/ingress-use-waypoint`.

- [ ] **Step 1: Confirm spike NodePort is free**

Run: `kubectl get svc -A -o jsonpath='{range .items[*]}{.spec.ports[*].nodePort}{"\n"}{end}' | tr ' ' '\n' | grep -x 30198 || echo FREE`
Expected: `FREE`

- [ ] **Step 2: Write the spike manifest**

```yaml
# $SCRATCH/spike.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: lab-spike
  labels:
    istio.io/dataplane-mode: ambient
---
apiVersion: v1
kind: Namespace
metadata:
  name: lab-spike-out
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: waypoint-params
  namespace: lab-spike
data:
  deployment: |
    spec:
      replicas: 2
      template:
        spec:
          containers:
            - name: istio-proxy
              resources:
                requests: {cpu: 100m, memory: 128Mi}
                limits: {cpu: 500m, memory: 256Mi}
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: waypoint
  namespace: lab-spike
  labels:
    istio.io/waypoint-for: service
spec:
  gatewayClassName: istio-waypoint
  infrastructure:
    parametersRef:
      group: ""
      kind: ConfigMap
      name: waypoint-params
  listeners:
    - name: mesh
      port: 15008
      protocol: HBONE
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: ingress-params
  namespace: lab-spike
data:
  service: |
    spec:
      type: NodePort
      ports:
        - name: http
          port: 80
          nodePort: 30198
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: spike-ingress
  namespace: lab-spike
spec:
  gatewayClassName: istio
  infrastructure:
    parametersRef:
      group: ""
      kind: ConfigMap
      name: ingress-params
  listeners:
    - name: http
      port: 80
      protocol: HTTP
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: echo
  namespace: lab-spike
spec:
  parentRefs:
    - name: spike-ingress
  rules:
    - backendRefs:
        - name: echo
          port: 8080
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: echo
  namespace: lab-spike
spec:
  replicas: 1
  selector: {matchLabels: {app: echo}}
  template:
    metadata: {labels: {app: echo}}
    spec:
      containers:
        - name: echo
          image: mccutchen/go-httpbin:v2.15.0
          ports: [{containerPort: 8080}]
---
apiVersion: v1
kind: Service
metadata:
  name: echo
  namespace: lab-spike
  labels:
    istio.io/use-waypoint: waypoint
    istio.io/ingress-use-waypoint: "true"
spec:
  selector: {app: echo}
  ports: [{name: http, port: 8080, targetPort: 8080}]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: echo-strict
  namespace: lab-spike
spec:
  replicas: 1
  selector: {matchLabels: {app: echo-strict}}
  template:
    metadata: {labels: {app: echo-strict}}
    spec:
      containers:
        - name: echo
          image: mccutchen/go-httpbin:v2.15.0
          ports: [{containerPort: 8080}]
---
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: echo-strict
  namespace: lab-spike
spec:
  selector:
    matchLabels: {app: echo-strict}
  mtls:
    mode: STRICT
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: echo
  namespace: lab-spike
spec:
  hosts: [echo.lab-spike.svc.cluster.local]
  http:
    - headers:
        response:
          set: {x-vs-applied: "true"}
      route:
        - destination: {host: echo.lab-spike.svc.cluster.local}
---
apiVersion: v1
kind: Pod
metadata:
  name: client
  namespace: lab-spike-out
spec:
  containers:
    - name: curl
      image: curlimages/curl:8.10.1
      command: ["sleep", "3600"]
---
apiVersion: v1
kind: Pod
metadata:
  name: client
  namespace: lab-spike
spec:
  containers:
    - name: curl
      image: curlimages/curl:8.10.1
      command: ["sleep", "3600"]
```

- [ ] **Step 3: Apply and wait**

Run: `kubectl apply -f $SCRATCH/spike.yaml && kubectl -n lab-spike wait --for=condition=Ready pod --all --timeout=180s && kubectl -n lab-spike-out wait --for=condition=Ready pod/client --timeout=120s`
Expected: all pods `condition met`.

- [ ] **Step 4: Spike 3 — parametersRef**

Run:
```bash
kubectl -n lab-spike get deploy waypoint -o jsonpath='{.spec.replicas} {.spec.template.spec.containers[0].resources}{"\n"}'
kubectl -n lab-spike get svc spike-ingress-istio -o jsonpath='{.spec.type} {range .spec.ports[*]}{.name}={.port}/{.nodePort} {end}{"\n"}'
```
Expected: `2 {"limits":{"cpu":"500m","memory":"256Mi"},"requests":{"cpu":"100m","memory":"128Mi"}}` and `NodePort ... http=80/30198 ...`. Record any other ports the generated Service exposes (e.g. `status-port`) — Task 12 must not collide with lab NodePorts 30092–30097.

- [ ] **Step 5: Spike 1 — workload-selector STRICT**

Run:
```bash
STRICT_IP=$(kubectl -n lab-spike get pod -l app=echo-strict -o jsonpath='{.items[0].status.podIP}')
PERM_IP=$(kubectl -n lab-spike get pod -l app=echo -o jsonpath='{.items[0].status.podIP}')
kubectl -n lab-spike-out exec client -- curl -s -m 5 -o /dev/null -w 'permissive %{http_code}\n' http://$PERM_IP:8080/get
kubectl -n lab-spike-out exec client -- curl -s -m 5 -o /dev/null -w 'strict %{http_code}\n' http://$STRICT_IP:8080/get; echo "exit=$?"
kubectl -n lab-spike exec client -- curl -s -m 5 -o /dev/null -w 'strict-from-mesh %{http_code}\n' http://$STRICT_IP:8080/get
```
Expected: `permissive 200`; strict from outside fails (`000` / non-zero exit, connection reset); `strict-from-mesh 200`.

- [ ] **Step 6: Spike 8 — ingress HTTPRoute + waypoint VirtualService**

Run: `kubectl -n lab-spike exec client -- curl -s -D - -o /dev/null http://spike-ingress-istio.lab-spike/get | grep -i -E '^HTTP|x-vs-applied'`
Expected: `HTTP/1.1 200` and `x-vs-applied: true` (ingress honoured the HTTPRoute AND traffic went through the waypoint where the VirtualService applied). If the header is missing, repeat after removing the `istio.io/ingress-use-waypoint` label to learn whether that label is what routes ingress traffic via the waypoint.

- [ ] **Step 7: Clean up**

Run: `kubectl delete -f $SCRATCH/spike.yaml --wait=true`
Expected: namespaces `lab-spike` and `lab-spike-out` deleted.

- [ ] **Step 8: Record results and commit**

Create the worktree first (all docker-gitops commits from here on happen there):
```bash
cd /home/ubuntu/jerome/docker-gitops && git pull --ff-only && git worktree add ../docker-gitops-lab-mesh -b lab-mesh-baseline
```
In the worktree's spec, under "Verification spikes", append after the list:
```markdown
### Spike results (Task 1, <date>)

- Spike 1: <PASS/FAIL + one-line observation>
- Spike 3: <PASS/FAIL + replicas/resources/ports observed>
- Spike 8: <PASS/FAIL + whether `istio.io/ingress-use-waypoint` was required>
```
Filling these three lines with the observed results is the step's deliverable. If any spike FAILED, stop the plan and return to the spec (the design changes).

```bash
cd /home/ubuntu/jerome/docker-gitops-lab-mesh
git add docs/superpowers/specs/2026-09-25-lab-mesh-production-baseline-design.md
git commit -m "docs(lab-environment): record mesh verification spike results

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Backups and immutable image tags

**Files:**
- Modify: `lab-environment/scripts/build.sh`
- Create: `lab-environment/scripts/push-to-k3s.sh`
- Modify: `k8s/api-gateway.yaml`, `k8s/customers-service.yaml`, `k8s/vets-service.yaml`, `k8s/visits-service.yaml`, `k8s/mcp-toolkit.yaml` (image lines)

**Interfaces:**
- Produces: `build.sh` prints `FORK_TAG=<sha12>` and `MCP_TAG=<sha12>`; `push-to-k3s.sh <image:tag>...` imports images into vps-oracle2's k3s containerd. Later tasks call both.

- [ ] **Step 1: Back up postgres and Consul KV**

```bash
mkdir -p /home/ubuntu/backups
kubectl -n lab-environment exec deploy/postgres -- pg_dumpall -U petclinic > /home/ubuntu/backups/lab-environment-pg-2026-09-25.sql
kubectl -n lab-environment exec deploy/consul -- consul kv export > /home/ubuntu/backups/lab-environment-consul-kv-2026-09-25.json
ls -la /home/ubuntu/backups/lab-environment-*-2026-09-25.*
grep -c 'INSERT\|COPY' /home/ubuntu/backups/lab-environment-pg-2026-09-25.sql
```
Expected: both files non-empty; the dump contains `COPY` statements for owners/pets/vets/visits.

- [ ] **Step 2: Branch the lab repo and make build.sh tag by SHA**

```bash
cd /home/ubuntu/jerome/lab-environment && git checkout -b lab-mesh-baseline
```
In `scripts/build.sh`, after the `if [ ! -d "$MCP_DIR" ] ... fi` block insert:
```bash
# Immutable tags: a tag must identify exactly one commit, so refuse to build
# from a dirty tree.
for repo in "$FORK_DIR" "$MCP_DIR"; do
  if [ -n "$(git -C "$repo" status --porcelain)" ]; then
    echo "error: '$repo' has uncommitted changes; commit first so the image tag means something." >&2
    exit 1
  fi
done
FORK_TAG=$(git -C "$FORK_DIR" rev-parse --short=12 HEAD)
MCP_TAG=$(git -C "$MCP_DIR" rev-parse --short=12 HEAD)
```
Replace the tagging loop body and the mcp build with:
```bash
for module in "${!SERVICES[@]}"; do
  service="${SERVICES[$module]}"
  src="ops-lab/${module}:latest"
  for tag in dev "$FORK_TAG"; do
    echo "Tagging $src -> ops-lab/${service}:${tag}"
    docker tag "$src" "ops-lab/${service}:${tag}"
  done
done

echo "Building mcp-toolkit from $MCP_DIR"
docker build -t ops-lab/mcp-toolkit:dev -t "ops-lab/mcp-toolkit:${MCP_TAG}" "$MCP_DIR"

echo "FORK_TAG=${FORK_TAG}"
echo "MCP_TAG=${MCP_TAG}"
```

- [ ] **Step 3: Write push-to-k3s.sh**

```bash
#!/bin/bash
# Imports local ops-lab images into vps-oracle2's k3s containerd (the lab's
# node). Usage: scripts/push-to-k3s.sh ops-lab/customers-service:<tag> ...
# Uses `k3s ctr`, not plain `ctr` — on oracle2 plain ctr is docker's
# containerd, a different store.
set -euo pipefail

if [ "$#" -eq 0 ]; then
  echo "usage: $0 <image:tag>..." >&2
  exit 1
fi

for image in "$@"; do
  case "$image" in
    *:dev|*:latest) echo "error: refusing mutable tag '$image'" >&2; exit 1 ;;
  esac
  echo "Importing $image"
  docker save "$image" | ssh vps-oracle2 'sudo k3s ctr -n k8s.io images import -'
done

ssh vps-oracle2 'sudo k3s ctr -n k8s.io images ls -q' | grep -F -f <(printf '%s\n' "$@")
```
Run: `chmod +x scripts/push-to-k3s.sh && bash -n scripts/build.sh && bash -n scripts/push-to-k3s.sh && scripts/push-to-k3s.sh ops-lab/x:dev; echo "exit=$?"`
Expected: `error: refusing mutable tag 'ops-lab/x:dev'`, `exit=1`.

- [ ] **Step 4: Build current code and import**

Run: `cd /home/ubuntu/jerome/lab-environment && ./scripts/build.sh 2>&1 | tail -5`
Expected: ends with `FORK_TAG=<12 hex>` and `MCP_TAG=<12 hex>`. Then:
```bash
FORK_TAG=<value>; MCP_TAG=<value>
./scripts/push-to-k3s.sh ops-lab/api-gateway:$FORK_TAG ops-lab/customers-service:$FORK_TAG ops-lab/vets-service:$FORK_TAG ops-lab/visits-service:$FORK_TAG ops-lab/mcp-toolkit:$MCP_TAG
```
Expected: final `grep` prints all five `docker.io/ops-lab/...:<tag>` refs.

- [ ] **Step 5: Commit lab repo**

```bash
git add scripts/build.sh scripts/push-to-k3s.sh
git commit -m "Tag images with source git SHA and add a k3s import script

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 6: Point manifests at the SHA tags**

In the worktree, replace `image: ops-lab/<svc>:dev` with `image: ops-lab/<svc>:<FORK_TAG>` in the four business manifests and `ops-lab/mcp-toolkit:<MCP_TAG>` in `mcp-toolkit.yaml`. Check: `grep -rn 'ops-lab/' k3s/apps/lab-environment/k8s/ | grep ':dev'` → no output.

- [ ] **Step 7: Commit, confirm with user, deploy, verify**

```bash
git add k3s/apps/lab-environment/k8s/
git commit -m "feat(lab-environment): pin ops-lab images to immutable SHA tags

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
After user confirmation, merge to `main` (see Global Constraints), `argocd app sync lab-environment`, then:
Run: `kubectl -n lab-environment get pods -o jsonpath='{range .items[*]}{.spec.containers[0].image}{"\n"}{end}' | grep ops-lab | sort -u && curl -s -o /dev/null -w '%{http_code}\n' http://10.0.0.95:30097/api/customer/owners`
Expected: five SHA-tagged images, `200`.

---

### Task 3: DB credentials to SealedSecret, with rotation

**Files:**
- Create: `k3s/sealed-secrets/secrets/lab-db-credentials.sealed.yaml`
- Modify: `k3s/sealed-secrets/secrets/README.md`, `k8s/postgres.yaml`, `k8s/customers-service.yaml`, `k8s/vets-service.yaml`, `k8s/visits-service.yaml`
- Modify: `lab-environment/scripts/init-consul-kv.sh`, `lab-environment/CLAUDE.md`

**Interfaces:**
- Produces: Secret `lab-environment/lab-db-credentials` with keys `username`, `password`. Services read `DATA_DB_PASSWORD`; Task 4's Job reads `PGUSER`/`PGPASSWORD` from the same Secret.

- [ ] **Step 1: Generate and seal**

```bash
cd /home/ubuntu/jerome/docker-gitops-lab-mesh
PW=$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | cut -c1-32)
echo "$PW" | grep -Eq '^[A-Za-z0-9]{32}$' && echo PW_OK
kubectl create secret generic lab-db-credentials -n lab-environment \
  --from-literal=username=petclinic --from-literal=password="$PW" \
  --dry-run=client -o json \
  | kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets --format yaml \
  > k3s/sealed-secrets/secrets/lab-db-credentials.sealed.yaml
grep -qF "$PW" k3s/sealed-secrets/secrets/lab-db-credentials.sealed.yaml && echo STOP || echo NO_PLAINTEXT
```
Expected: `PW_OK`, `NO_PLAINTEXT`. (Alphanumeric-only is deliberate: the value is later embedded in SQL and URLs.) Keep `$PW` only in this shell — it is not written anywhere else.

- [ ] **Step 2: Inventory row and first deploy (Secret only)**

Add to the inventory table in `k3s/sealed-secrets/secrets/README.md` a row: `lab-db-credentials | lab-environment | PostgreSQL user/password for the lab (postgres, business services, db-init Job)`. Commit:
```bash
git add k3s/sealed-secrets/secrets/
git commit -m "feat(sealed-secrets): add lab-environment DB credentials

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
After user confirmation, merge to `main`, `argocd app sync sealed-secrets`.
Run: `kubectl -n lab-environment get secret lab-db-credentials -o jsonpath='{.data.password}' | base64 -d | grep -qx "$PW" && echo SECRET_OK`
Expected: `SECRET_OK`.

- [ ] **Step 3: Switch consumers to the Secret (commit, do not merge yet)**

`postgres.yaml` — replace the `POSTGRES_USER`/`POSTGRES_PASSWORD` values:
```yaml
            - name: POSTGRES_USER
              valueFrom:
                secretKeyRef: {name: lab-db-credentials, key: username}
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef: {name: lab-db-credentials, key: password}
```
In each of `customers-service.yaml`, `vets-service.yaml`, `visits-service.yaml` add to `env`:
```yaml
            # Overrides nothing: the Consul KV key config/<svc>/data/db.password
            # is deleted; the password lives only in this SealedSecret.
            - name: DATA_DB_PASSWORD
              valueFrom:
                secretKeyRef: {name: lab-db-credentials, key: password}
```
```bash
git add k3s/apps/lab-environment/k8s/
git commit -m "feat(lab-environment): read DB password from lab-db-credentials

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 4: Rotation window (user confirms first — new DB connections fail for ~2 min)**

```bash
printf "ALTER USER petclinic WITH PASSWORD '%s';\n" "$PW" \
  | kubectl -n lab-environment exec -i deploy/postgres -- psql -U petclinic -d postgres
for s in customers-service vets-service visits-service; do
  kubectl -n lab-environment exec deploy/consul -- consul kv delete config/$s/data/db.password
done
```
Expected: `ALTER ROLE`, three `Success! Deleted key`. Immediately merge Step 3's commit to `main` and `argocd app sync lab-environment`.

- [ ] **Step 5: Verify (spec spike 7 + acceptance 7)**

```bash
kubectl -n lab-environment rollout status deploy/customers-service deploy/vets-service deploy/visits-service deploy/postgres --timeout=300s
curl -s -o /dev/null -w '%{http_code}\n' http://10.0.0.95:30097/api/customer/owners
kubectl -n lab-environment exec deploy/postgres -- env PGPASSWORD=petclinic psql -h 127.0.0.1 -U petclinic -d customers -c 'select 1' 2>&1 | tail -1
kubectl -n lab-environment exec deploy/consul -- consul kv get -recurse config/ | grep -c password
grep -n 'petclinic' k3s/apps/lab-environment/k8s/postgres.yaml
```
Expected: rollouts complete; `200`; `password authentication failed`; `0`; no `POSTGRES_PASSWORD` literal.

- [ ] **Step 6: Stop seeding the password (lab repo)**

In `lab-environment/scripts/init-consul-kv.sh` delete the line `put "config/$service/data/db.password" "petclinic"` and add above the loop:
```bash
# db.password is deliberately NOT seeded: on k3s it comes from the
# lab-db-credentials SealedSecret as DATA_DB_PASSWORD (docker-gitops repo).
```
In `lab-environment/CLAUDE.md`'s contract table, change the static-config key list to drop `db.password` and append: "`db.password` is not in KV — it comes from the `lab-db-credentials` Secret as env `DATA_DB_PASSWORD`."
```bash
cd /home/ubuntu/jerome/lab-environment
git add scripts/init-consul-kv.sh CLAUDE.md
git commit -m "Stop seeding the DB password into Consul KV

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Idempotent db-init PreSync Job

**Files:**
- Create: `k3s/apps/lab-environment/tests/test-db-init.sh`
- Create: `k8s/db-init.yaml`
- Modify: `k8s/customers-service.yaml`, `k8s/vets-service.yaml`, `k8s/visits-service.yaml` (env)

**Interfaces:**
- Consumes: Secret `lab-db-credentials` (Task 3).
- Produces: ConfigMap `db-init-sql` keys `customers.sql`, `vets.sql`, `visits.sql`; ServiceAccount `db-init` (Task 14's postgres policy allows it).

- [ ] **Step 1: Write the failing test**

```bash
#!/bin/bash
# Runs db-init.yaml's SQL against a throwaway postgres:16 container:
# legacy state (fork's original DROP/CREATE seed) -> db-init twice ->
# app-style insert -> db-init again. Asserts seed counts, that app rows
# survive, and that identity sequences are never reset.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
MANIFEST="$HERE/../k8s/db-init.yaml"
FORK=${FORK_DIR:-/home/ubuntu/jerome/spring-petclinic-microservices}
NAME=db-init-test-$$
WORK=$(mktemp -d)
trap 'docker rm -f $NAME >/dev/null 2>&1; rm -rf "$WORK"' EXIT

python3 - "$MANIFEST" "$WORK" <<'EOF'
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
cm = next(d for d in docs if d["kind"] == "ConfigMap" and d["metadata"]["name"] == "db-init-sql")
for key, sql in cm["data"].items():
    open(f"{sys.argv[2]}/{key}", "w").write(sql)
EOF

docker run -d --name $NAME -e POSTGRES_PASSWORD=t -e POSTGRES_USER=petclinic postgres:16 >/dev/null
until docker exec $NAME pg_isready -U petclinic >/dev/null 2>&1; do sleep 1; done
sleep 2
q() { docker exec -i $NAME psql -v ON_ERROR_STOP=1 -qtA -U petclinic -d "$1"; }
for db in customers vets visits; do echo "CREATE DATABASE $db;" | q postgres; done

for svc in customers vets visits; do
  cat "$FORK/spring-petclinic-$svc-service/src/main/resources/db/postgresql/schema.sql" \
      "$FORK/spring-petclinic-$svc-service/src/main/resources/db/postgresql/data.sql" | q $svc >/dev/null
done

run_init() { for db in customers vets visits; do q $db < "$WORK/$db.sql" >/dev/null; done; }
run_init; run_init

expect() { local got; got=$(echo "$2" | q $1); [ "$got" = "$3" ] || { echo "FAIL $1: $2 -> $got (want $3)"; exit 1; }; }
expect customers "SELECT count(*) FROM types" 6
expect customers "SELECT count(*) FROM owners" 10
expect customers "SELECT count(*) FROM pets" 13
expect vets "SELECT count(*) FROM vets" 6
expect vets "SELECT count(*) FROM specialties" 3
expect vets "SELECT count(*) FROM vet_specialties" 5
expect visits "SELECT count(*) FROM visits" 4

expect customers "INSERT INTO owners (first_name,last_name,address,city,telephone) VALUES ('T','T','a','c','1') RETURNING id" 11
run_init
expect customers "SELECT count(*) FROM owners" 11
expect customers "INSERT INTO owners (first_name,last_name,address,city,telephone) VALUES ('U','U','a','c','2') RETURNING id" 12
expect visits "INSERT INTO visits (pet_id,visit_date,description) VALUES (1,'2026-01-01','x') RETURNING id" 5
run_init
expect visits "SELECT count(*) FROM visits" 5
echo "PASS"
```
Run: `chmod +x k3s/apps/lab-environment/tests/test-db-init.sh && k3s/apps/lab-environment/tests/test-db-init.sh`
Expected: FAIL — `FileNotFoundError` for `db-init.yaml`.

- [ ] **Step 2: Write db-init.yaml**

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: db-init
  namespace: lab-environment
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: db-init-sql
  namespace: lab-environment
data:
  # Idempotent rewrite of the fork's db/postgresql/{schema,data}.sql, which
  # DROP and re-seed on every app start (fatal with several replicas).
  # Tables are only created when missing, seed rows only inserted when
  # missing, and sequences only ever move forward — rerunning this on every
  # ArgoCD sync is a no-op. Tested by ../tests/test-db-init.sh.
  customers.sql: |
    CREATE TABLE IF NOT EXISTS types (
      id   INTEGER GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
      name VARCHAR(80)
    );
    CREATE INDEX IF NOT EXISTS types_name ON types (name);
    CREATE TABLE IF NOT EXISTS owners (
      id         INTEGER GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
      first_name VARCHAR(30),
      last_name  VARCHAR(30),
      address    VARCHAR(255),
      city       VARCHAR(80),
      telephone  VARCHAR(20)
    );
    CREATE INDEX IF NOT EXISTS owners_last_name ON owners (last_name);
    CREATE TABLE IF NOT EXISTS pets (
      id         INTEGER GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
      name       VARCHAR(30),
      birth_date DATE,
      type_id    INTEGER NOT NULL,
      owner_id   INTEGER NOT NULL,
      CONSTRAINT fk_pets_owners FOREIGN KEY (owner_id) REFERENCES owners (id),
      CONSTRAINT fk_pets_types FOREIGN KEY (type_id) REFERENCES types (id)
    );
    CREATE INDEX IF NOT EXISTS pets_name ON pets (name);
    INSERT INTO types VALUES
      (1, 'cat'), (2, 'dog'), (3, 'lizard'), (4, 'snake'), (5, 'bird'), (6, 'hamster')
    ON CONFLICT (id) DO NOTHING;
    INSERT INTO owners VALUES
      (1, 'George', 'Franklin', '110 W. Liberty St.', 'Madison', '6085551023'),
      (2, 'Betty', 'Davis', '638 Cardinal Ave.', 'Sun Prairie', '6085551749'),
      (3, 'Eduardo', 'Rodriquez', '2693 Commerce St.', 'McFarland', '6085558763'),
      (4, 'Harold', 'Davis', '563 Friendly St.', 'Windsor', '6085553198'),
      (5, 'Peter', 'McTavish', '2387 S. Fair Way', 'Madison', '6085552765'),
      (6, 'Jean', 'Coleman', '105 N. Lake St.', 'Monona', '6085552654'),
      (7, 'Jeff', 'Black', '1450 Oak Blvd.', 'Monona', '6085555387'),
      (8, 'Maria', 'Escobito', '345 Maple St.', 'Madison', '6085557683'),
      (9, 'David', 'Schroeder', '2749 Blackhawk Trail', 'Madison', '6085559435'),
      (10, 'Carlos', 'Estaban', '2335 Independence La.', 'Waunakee', '6085555487')
    ON CONFLICT (id) DO NOTHING;
    INSERT INTO pets VALUES
      (1, 'Leo', '2010-09-07', 1, 1), (2, 'Basil', '2012-08-06', 6, 2),
      (3, 'Rosy', '2011-04-17', 2, 3), (4, 'Jewel', '2010-03-07', 2, 3),
      (5, 'Iggy', '2010-11-30', 3, 4), (6, 'George', '2010-01-20', 4, 5),
      (7, 'Samantha', '2012-09-04', 1, 6), (8, 'Max', '2012-09-04', 1, 6),
      (9, 'Lucky', '2011-08-06', 5, 7), (10, 'Mulligan', '2007-02-24', 2, 8),
      (11, 'Freddy', '2010-03-09', 5, 9), (12, 'Lucky', '2010-06-24', 2, 10),
      (13, 'Sly', '2012-06-08', 1, 10)
    ON CONFLICT (id) DO NOTHING;
    SELECT setval(pg_get_serial_sequence('types', 'id'), (SELECT max(id) FROM types));
    SELECT setval(pg_get_serial_sequence('owners', 'id'), (SELECT max(id) FROM owners));
    SELECT setval(pg_get_serial_sequence('pets', 'id'), (SELECT max(id) FROM pets));
  vets.sql: |
    CREATE TABLE IF NOT EXISTS vets (
      id         INTEGER GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
      first_name VARCHAR(30),
      last_name  VARCHAR(30)
    );
    CREATE INDEX IF NOT EXISTS vets_last_name ON vets (last_name);
    CREATE TABLE IF NOT EXISTS specialties (
      id   INTEGER GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
      name VARCHAR(80)
    );
    CREATE INDEX IF NOT EXISTS specialties_name ON specialties (name);
    CREATE TABLE IF NOT EXISTS vet_specialties (
      vet_id       INTEGER NOT NULL,
      specialty_id INTEGER NOT NULL,
      UNIQUE (vet_id, specialty_id),
      CONSTRAINT fk_vet_specialties_vets FOREIGN KEY (vet_id) REFERENCES vets (id),
      CONSTRAINT fk_vet_specialties_specialties FOREIGN KEY (specialty_id) REFERENCES specialties (id)
    );
    INSERT INTO vets VALUES
      (1, 'James', 'Carter'), (2, 'Helen', 'Leary'), (3, 'Linda', 'Douglas'),
      (4, 'Rafael', 'Ortega'), (5, 'Henry', 'Stevens'), (6, 'Sharon', 'Jenkins')
    ON CONFLICT (id) DO NOTHING;
    INSERT INTO specialties VALUES (1, 'radiology'), (2, 'surgery'), (3, 'dentistry')
    ON CONFLICT (id) DO NOTHING;
    INSERT INTO vet_specialties VALUES (2, 1), (3, 2), (3, 3), (4, 2), (5, 1)
    ON CONFLICT DO NOTHING;
    SELECT setval(pg_get_serial_sequence('vets', 'id'), (SELECT max(id) FROM vets));
    SELECT setval(pg_get_serial_sequence('specialties', 'id'), (SELECT max(id) FROM specialties));
  visits.sql: |
    CREATE TABLE IF NOT EXISTS visits (
      id          INTEGER GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
      pet_id      INTEGER NOT NULL,
      visit_date  DATE,
      description VARCHAR(8192)
    );
    CREATE INDEX IF NOT EXISTS visits_pet_id ON visits (pet_id);
    INSERT INTO visits VALUES
      (1, 7, '2013-01-01', 'rabies shot'), (2, 8, '2013-01-02', 'rabies shot'),
      (3, 8, '2013-01-03', 'neutered'), (4, 7, '2013-01-04', 'spayed')
    ON CONFLICT (id) DO NOTHING;
    SELECT setval(pg_get_serial_sequence('visits', 'id'), (SELECT max(id) FROM visits));
---
apiVersion: batch/v1
kind: Job
metadata:
  name: db-init
  namespace: lab-environment
  annotations:
    # Schema/seed runs before every sync of this Application, decoupled
    # from app startup (the services run with SPRING_SQL_INIT_MODE=never).
    argocd.argoproj.io/hook: PreSync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
spec:
  backoffLimit: 6
  activeDeadlineSeconds: 600
  template:
    metadata:
      labels:
        app: db-init
        trivy-operator.skip: "true"
    spec:
      serviceAccountName: db-init
      restartPolicy: Never
      enableServiceLinks: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 999
      containers:
        - name: db-init
          image: postgres:16
          command: ["/bin/bash", "-ec"]
          args:
            - |
              until pg_isready -h postgres -U "$PGUSER" -q; do echo waiting for postgres; sleep 3; done
              for db in customers vets visits; do
                echo "applying $db.sql"
                psql -v ON_ERROR_STOP=1 -h postgres -d "$db" -f "/sql/$db.sql"
              done
          env:
            - name: TZ
              value: "Asia/Hong_Kong"
            - name: PGUSER
              valueFrom:
                secretKeyRef: {name: lab-db-credentials, key: username}
            - name: PGPASSWORD
              valueFrom:
                secretKeyRef: {name: lab-db-credentials, key: password}
          volumeMounts:
            - name: sql
              mountPath: /sql
          resources:
            requests: {cpu: 50m, memory: 64Mi}
            limits: {cpu: 200m, memory: 128Mi}
      volumes:
        - name: sql
          configMap:
            name: db-init-sql
```

- [ ] **Step 3: Run the test**

Run: `k3s/apps/lab-environment/tests/test-db-init.sh`
Expected: `PASS`.

- [ ] **Step 4: Stop apps from initialising the schema**

Add to `env` in `customers-service.yaml`, `vets-service.yaml`, `visits-service.yaml`:
```yaml
            # Schema/seed is owned by the db-init PreSync Job (db-init.yaml);
            # the fork's own init DROPs tables on every start.
            - name: SPRING_SQL_INIT_MODE
              value: "never"
```

- [ ] **Step 5: Commit, confirm, deploy, verify persistence**

```bash
git add k3s/apps/lab-environment/tests/test-db-init.sh k3s/apps/lab-environment/k8s/
git commit -m "feat(lab-environment): move schema init to an idempotent PreSync Job

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
After user confirmation merge + `argocd app sync lab-environment`, then:
```bash
kubectl -n lab-environment logs job/db-init | tail -5
curl -s -X POST -H 'Content-Type: application/json' http://10.0.0.95:30097/api/customer/owners \
  -d '{"firstName":"Persist","lastName":"Check","address":"1 Test St","city":"Test","telephone":"1234567890"}' -o /dev/null -w '%{http_code}\n'
kubectl -n lab-environment delete pod -l app=customers-service --wait=true
kubectl -n lab-environment rollout status deploy/customers-service --timeout=300s
curl -s http://10.0.0.95:30097/api/customer/owners | grep -o '"lastName":"Check"'
kubectl -n lab-environment exec deploy/postgres -- psql -U petclinic -d customers -c "DELETE FROM owners WHERE last_name='Check'"
```
Expected: log ends with `applying visits.sql` output and no error; `201`; after the pod restart `"lastName":"Check"` is still returned (before this task a restart would have wiped it); `DELETE 1`.

---

### Task 5: Prometheus per-pod scraping

**Files:**
- Modify: `k8s/prometheus.yaml`, `k8s/configmaps.yaml` (`prometheus-config`), the four business manifests (pod annotations)

**Interfaces:**
- Produces: business metrics carry labels `service` (= pod label `app`), `pod`, `instance` (= `<pod>:<port>`). Task 9's `query_metric` filters on `service`. Job `envoy-stats` is added in Task 13.

- [ ] **Step 1: RBAC and SA in prometheus.yaml**

Prepend:
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: prometheus
  namespace: lab-environment
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: prometheus-discovery
  namespace: lab-environment
rules:
  - apiGroups: [""]
    resources: ["pods", "endpoints", "services"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: prometheus-discovery
  namespace: lab-environment
subjects:
  - kind: ServiceAccount
    name: prometheus
    namespace: lab-environment
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: prometheus-discovery
---
```
In the Deployment pod spec add `serviceAccountName: prometheus`, and under `template.metadata` add:
```yaml
      annotations:
        # prometheus.yml is mounted via subPath, which never hot-reloads.
        # Bump this whenever prometheus-config changes.
        lab.jerome/config-rev: "1"
```

- [ ] **Step 2: Replace the spring-boot-services job**

In `configmaps.yaml` replace the whole `spring-boot-services` job with:
```yaml
      # Business services expose Spring Boot Actuator's Prometheus endpoint.
      # Discovered per pod (a Service-name target would hit one random
      # replica per scrape). Opt-in via prometheus.io/* pod annotations.
      - job_name: spring-boot-services
        kubernetes_sd_configs:
          - role: pod
            namespaces:
              names: [lab-environment]
        relabel_configs:
          - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
            action: keep
            regex: "true"
          - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
            target_label: __metrics_path__
            regex: (.+)
          - source_labels: [__address__, __meta_kubernetes_pod_annotation_prometheus_io_port]
            regex: '([^:]+)(?::\d+)?;(\d+)'
            replacement: '$1:$2'
            target_label: __address__
          - source_labels: [__meta_kubernetes_pod_label_app]
            target_label: service
          - source_labels: [__meta_kubernetes_pod_name]
            target_label: pod
          - source_labels: [__meta_kubernetes_pod_name, __meta_kubernetes_pod_annotation_prometheus_io_port]
            separator: ":"
            target_label: instance
          - target_label: env
            replacement: lab
```

- [ ] **Step 3: Annotate business pods**

In each business Deployment's `template.metadata` add (port per Global Constraints):
```yaml
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8081"
        prometheus.io/path: /actuator/prometheus
```

- [ ] **Step 4: Validate and commit**

Run: `python3 -c "import yaml; cm=[d for d in yaml.safe_load_all(open('k3s/apps/lab-environment/k8s/configmaps.yaml')) if d and d['metadata']['name']=='prometheus-config'][0]; jobs=[j['job_name'] for j in yaml.safe_load(cm['data']['prometheus.yml'])['scrape_configs']]; print('YAML_OK', jobs)"`
Expected: `YAML_OK [...]` listing `prometheus`, `consul`, `spring-boot-services`.
```bash
git add k3s/apps/lab-environment/k8s/
git commit -m "feat(lab-environment): scrape business services per pod via kubernetes_sd

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 5: Deploy and verify**

After user confirmation merge + sync:
Run: `curl -s http://10.0.0.95:30093/api/v1/targets | python3 -c "import json,sys; [print(t['labels'].get('service'), t['labels'].get('pod'), t['health']) for t in json.load(sys.stdin)['data']['activeTargets'] if t['labels']['job']=='spring-boot-services']"`
Expected: four lines, one per service, each with a pod name and `up`.

---

### Task 6: Resident traffic generator

**Files:**
- Create: `k8s/traffic-generator.yaml`

**Interfaces:**
- Produces: Deployment `traffic-generator` (SA `traffic-generator`, created here); log line format `<iso8601> <http_code> <path>` — Tasks 7, 12 and 16 count codes from it. Env `TARGET_URL` is switched to the ingress in Task 12.

- [ ] **Step 1: Write the manifest**

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: traffic-generator
  namespace: lab-environment
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: traffic-generator
  namespace: lab-environment
data:
  run.sh: |
    #!/bin/sh
    # ~2 rps of browsing traffic: owner list, owner detail (gateway
    # aggregation -> customers -> visits), single owner, vet list. One log
    # line per request so error counts are provable from Loki.
    i=0
    while true; do
      i=$((i + 1))
      id=$(( (i % 10) + 1 ))
      case $((i % 4)) in
        0) path="/api/customer/owners" ;;
        1) path="/api/gateway/owners/$id" ;;
        2) path="/api/vet/vets" ;;
        *) path="/api/customer/owners/$id" ;;
      esac
      code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$TARGET_URL$path")
      echo "$(date -Iseconds) $code $path"
      sleep 0.5
    done
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: traffic-generator
  namespace: lab-environment
  labels:
    app: traffic-generator
spec:
  replicas: 1
  selector:
    matchLabels:
      app: traffic-generator
  template:
    metadata:
      labels:
        app: traffic-generator
        trivy-operator.skip: "true"
    spec:
      serviceAccountName: traffic-generator
      enableServiceLinks: false
      containers:
        - name: traffic-generator
          image: curlimages/curl:8.10.1
          command: ["/bin/sh", "/opt/run.sh"]
          env:
            - name: TZ
              value: "Asia/Hong_Kong"
            - name: TARGET_URL
              value: "http://api-gateway:8080"
          volumeMounts:
            - name: script
              mountPath: /opt
          resources:
            requests: {cpu: 25m, memory: 32Mi}
            limits: {cpu: 100m, memory: 64Mi}
      volumes:
        - name: script
          configMap:
            name: traffic-generator
```

- [ ] **Step 2: Commit, confirm, deploy, verify**

```bash
git add k3s/apps/lab-environment/k8s/traffic-generator.yaml
git commit -m "feat(lab-environment): add a resident ~2 rps traffic generator

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
After merge + sync, wait 60s:
Run: `kubectl -n lab-environment logs deploy/traffic-generator --since=60s | awk '{print $2}' | sort | uniq -c`
Expected: ~100–120 requests, all `200`. If any path returns non-200 at baseline, stop and investigate before continuing (it would poison every later zero-error check).

---

### Task 7: Rolling updates, quota, PDBs, scale-out

**Files:**
- Modify: `k8s/namespace.yaml` (quota), four business manifests (strategy, replicas)
- Create: `k8s/pdb.yaml`

**Interfaces:**
- Produces: customers-service ×5, api-gateway ×3; quota with headroom for the mesh pods added in Tasks 11–12.

- [ ] **Step 1: Raise the quota**

Replace the `hard:` block in `namespace.yaml`:
```yaml
  hard:
    # 2026-09-25 production baseline: customers x5 + api-gateway x3 (JVMs,
    # request == limit), 2 waypoint + 2 ingress Envoys, traffic generator,
    # db-init Job, plus one rolling-update surge JVM (768Mi / 1000m).
    requests.cpu: "2"
    requests.memory: 10Gi
    limits.cpu: "15"
    limits.memory: 10Gi
```

- [ ] **Step 2: RollingUpdate for the four business Deployments**

Replace `strategy: {type: Recreate}` in each with:
```yaml
  strategy:
    type: RollingUpdate
    rollingUpdate:
      # One extra pod at a time: zero downtime, and never more than one JVM
      # booting at once on the 2-core node.
      maxSurge: 1
      maxUnavailable: 0
```
Commit and deploy this plus the quota (no replica change yet):
```bash
git add k3s/apps/lab-environment/k8s/
git commit -m "feat(lab-environment): rolling updates and quota headroom for scale-out

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
After confirmation merge + sync. Verify: `kubectl -n lab-environment get deploy -o custom-columns=N:.metadata.name,S:.spec.strategy.type | grep -E 'gateway|service'` → four `RollingUpdate`.

- [ ] **Step 3: Scale step 1 (customers 3, gateway 2)**

Set `replicas: 3` in `customers-service.yaml`, `replicas: 2` in `api-gateway.yaml`; commit (`feat(lab-environment): scale customers to 3 and api-gateway to 2`), merge, sync.
Run: `kubectl -n lab-environment rollout status deploy/customers-service deploy/api-gateway --timeout=600s && ssh vps-oracle2 free -m | awk '/Mem/{print "available_mb=" $7}'`
Expected: rollouts complete; `available_mb` ≥ 1024 (else stop, report).

- [ ] **Step 4: Scale step 2 (customers 5, gateway 3) + PDBs**

Set `replicas: 5` / `replicas: 3`. Create `pdb.yaml`:
```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: customers-service
  namespace: lab-environment
spec:
  minAvailable: 3
  selector:
    matchLabels:
      app: customers-service
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: api-gateway
  namespace: lab-environment
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app: api-gateway
```
Commit (`feat(lab-environment): scale customers to 5 and api-gateway to 3 with PDBs`), merge, sync.
Run: `kubectl -n lab-environment rollout status deploy/customers-service deploy/api-gateway --timeout=900s && ssh vps-oracle2 free -m | awk '/Mem/{print "available_mb=" $7}' && kubectl -n lab-environment get pdb`
Expected: 5/5 and 3/3 ready; `available_mb` ≥ 1024; PDBs `ALLOWED DISRUPTIONS` 2 and 1.

- [ ] **Step 5: Verify per-pod scraping and no errors**

```bash
curl -s 'http://10.0.0.95:30093/api/v1/query?query=count%20by%20(service)(up%7Bjob%3D%22spring-boot-services%22%7D)' | python3 -m json.tool | grep -A1 '"service"'
kubectl -n lab-environment logs deploy/traffic-generator --since=15m | awk '{print $2}' | sort | uniq -c
```
Expected: customers-service 5, api-gateway 3, others 1; generator codes all `200` (still Consul discovery at this point — Consul load-balances across all instances).

---

### Task 8: Fork — K8s-native service discovery

**Files (all in `/home/ubuntu/jerome/spring-petclinic-microservices`):**
- Modify: `spring-petclinic-api-gateway/src/main/java/org/springframework/samples/petclinic/api/ApiGatewayApplication.java`
- Modify: `spring-petclinic-api-gateway/src/main/java/org/springframework/samples/petclinic/api/application/CustomersServiceClient.java`
- Modify: `spring-petclinic-api-gateway/src/main/java/org/springframework/samples/petclinic/api/application/VisitsServiceClient.java`
- Create: `spring-petclinic-api-gateway/src/test/java/org/springframework/samples/petclinic/api/application/CustomersServiceClientTest.java`
- Modify: `spring-petclinic-api-gateway/src/test/java/org/springframework/samples/petclinic/api/application/VisitsServiceClientIntegrationTest.java`
- Modify: `spring-petclinic-api-gateway/src/main/resources/application.yml`, `spring-petclinic-api-gateway/pom.xml`
- Modify: `spring-petclinic-customers-service/src/main/java/org/springframework/samples/petclinic/customers/CustomersServiceApplication.java`, `.../customers/config/RestTemplateConfig.java`, `.../customers/web/VisitsServiceClient.java`, its test, `application.yml`, `pom.xml`
- Modify: `spring-petclinic-vets-service/.../VetsServiceApplication.java`, `pom.xml`; `spring-petclinic-visits-service/.../VisitsServiceApplication.java`, `pom.xml`
- Modify: `CHANGES.md`

**Interfaces:**
- Produces: properties `petclinic.services.customers-url`, `petclinic.services.visits-url`, `petclinic.services.vets-url` (base URLs, no trailing slash). Constructors: gateway `CustomersServiceClient(WebClient.Builder, String customersUrl)`, gateway `VisitsServiceClient(WebClient.Builder, String visitsUrl)`, customers `VisitsServiceClient(RestTemplate, ChaosToggles, String visitsUrl)`.

- [ ] **Step 1: Branch**

Run: `cd /home/ubuntu/jerome/spring-petclinic-microservices && git checkout -b k8s-native-discovery`

- [ ] **Step 2: Failing test — gateway CustomersServiceClient uses the configured URL**

```java
package org.springframework.samples.petclinic.api.application;

import mockwebserver3.MockResponse;
import mockwebserver3.MockWebServer;
import mockwebserver3.RecordedRequest;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.samples.petclinic.api.dto.OwnerDetails;
import org.springframework.web.reactive.function.client.WebClient;

import java.io.IOException;

import static org.junit.jupiter.api.Assertions.assertEquals;

class CustomersServiceClientTest {

    private MockWebServer server;
    private CustomersServiceClient client;

    @BeforeEach
    void setUp() throws IOException {
        server = new MockWebServer();
        server.start();
        String baseUrl = server.url("/").toString().replaceAll("/$", "");
        client = new CustomersServiceClient(WebClient.builder(), baseUrl);
    }

    @AfterEach
    void shutdown() {
        server.close();
    }

    @Test
    void getOwnerCallsConfiguredBaseUrl() throws InterruptedException {
        server.enqueue(new MockResponse.Builder()
            .addHeader("Content-Type", "application/json")
            .body("{\"id\":7,\"firstName\":\"Jeff\",\"lastName\":\"Black\",\"address\":\"a\",\"city\":\"c\",\"telephone\":\"1\",\"pets\":[]}")
            .build());

        OwnerDetails owner = client.getOwner(7).block();

        RecordedRequest request = server.takeRequest();
        assertEquals("/owners/7", request.getTarget());
        assertEquals(7, owner.id());
    }
}
```
Check the `mockwebserver3` API names against the existing `VisitsServiceClientIntegrationTest` imports (`MockWebServer`, `MockResponse.Builder`) and `RecordedRequest` accessor (`getTarget()` in mockwebserver3 5.x; if the local version exposes `getPath()` instead, use that). Check `OwnerDetails` is a record with `id()` (`grep -n 'record OwnerDetails' -r spring-petclinic-api-gateway/src/main`).
Run: `./mvnw -q -pl spring-petclinic-api-gateway test -Dtest=CustomersServiceClientTest`
Expected: compilation FAIL — no constructor `CustomersServiceClient(WebClient.Builder, String)`.

- [ ] **Step 3: Implement gateway clients**

`CustomersServiceClient.java` body:
```java
@Component
public class CustomersServiceClient {

    private final WebClient.Builder webClientBuilder;
    private final String customersUrl;

    public CustomersServiceClient(WebClient.Builder webClientBuilder,
                                  @Value("${petclinic.services.customers-url}") String customersUrl) {
        this.webClientBuilder = webClientBuilder;
        this.customersUrl = customersUrl;
    }

    public Mono<OwnerDetails> getOwner(final int ownerId) {
        return webClientBuilder.build().get()
            .uri(customersUrl + "/owners/{ownerId}", ownerId)
            .retrieve()
            .bodyToMono(OwnerDetails.class);
    }
}
```
(add `import org.springframework.beans.factory.annotation.Value;`)

`VisitsServiceClient.java` (gateway) — remove the `hostname` field and `setHostname`; body:
```java
@Component
public class VisitsServiceClient {

    private final WebClient.Builder webClientBuilder;
    private final String visitsUrl;

    public VisitsServiceClient(WebClient.Builder webClientBuilder,
                               @Value("${petclinic.services.visits-url}") String visitsUrl) {
        this.webClientBuilder = webClientBuilder;
        this.visitsUrl = visitsUrl;
    }

    public Mono<Visits> getVisitsForPets(final List<Integer> petIds) {
        return webClientBuilder.build()
            .get()
            .uri(visitsUrl + "/pets/visits?petId={petId}", joinIds(petIds))
            .retrieve()
            .bodyToMono(Visits.class);
    }

    private String joinIds(List<Integer> petIds) {
        return petIds.stream().map(Object::toString).collect(joining(","));
    }
}
```
In `VisitsServiceClientIntegrationTest.setUp()` replace the two construction lines with:
```java
        visitsServiceClient = new VisitsServiceClient(WebClient.builder(),
            server.url("/").toString().replaceAll("/$", ""));
```

- [ ] **Step 4: Remove client-side load balancing from the gateway**

In `ApiGatewayApplication.java`: delete `@EnableDiscoveryClient`, the `loadBalancedRestTemplate()` bean (unused), the `loadBalancedWebClientBuilder()` bean (so Spring Boot's auto-configured, observation-instrumented `WebClient.Builder` is injected — this is what keeps `traceparent` propagating), and the now-unused imports (`EnableDiscoveryClient`, `LoadBalanced`, `RestTemplate`, `WebClient`).

In the gateway `application.yml`:
- delete the `- name: Retry` default filter block (5 lines: name + args retries/statuses/methods);
- delete the whole `genai-service` route (never deployed; `lb://` has no resolver any more);
- change route URIs: `uri: ${petclinic.services.vets-url}`, `uri: ${petclinic.services.visits-url}`, `uri: ${petclinic.services.customers-url}`;
- add at top level (after `server:` block of the default profile):
```yaml
# Downstream base URLs: K8s Service DNS. Load balancing, retries and
# circuit breaking between services belong to the mesh (Envoy), not to a
# client-side load balancer.
petclinic:
  services:
    customers-url: http://customers-service:8081
    visits-url: http://visits-service:8082
    vets-url: http://vets-service:8083
```
In the gateway `pom.xml` delete the `spring-cloud-starter-consul-discovery` `<dependency>` block.

- [ ] **Step 5: Run gateway tests**

Run: `./mvnw -q -pl spring-petclinic-api-gateway test`
Expected: PASS, including `ApiGatewayApplicationTests.contextLoads` (proves an auto-configured `WebClient.Builder` exists without the custom bean). If `contextLoads` fails for a missing `WebClient.Builder`, add `spring-boot-starter-webclient` as a dependency (it exists in the local Maven repo) and rerun.

- [ ] **Step 6: Failing test — customers VisitsServiceClient uses the configured URL**

In `VisitsServiceClientTest` (customers) change construction to
`client = new VisitsServiceClient(restTemplate, chaosToggles, "http://visits.example:8082");`
and both `requestTo("http://visits-service/pets/visits?...")` to `requestTo("http://visits.example:8082/pets/visits?petId=111,222")` / `requestTo("http://visits.example:8082/pets/visits?petId=111")`.
Run: `./mvnw -q -pl spring-petclinic-customers-service test -Dtest=VisitsServiceClientTest`
Expected: compilation FAIL (constructor arity).

- [ ] **Step 7: Implement customers changes**

`VisitsServiceClient.java` (customers): replace the `VISITS_SERVICE_URL` constant and constructor with:
```java
    private final RestTemplate restTemplate;
    private final ChaosToggles chaosToggles;
    private final String visitsUrl;

    VisitsServiceClient(RestTemplate restTemplate, ChaosToggles chaosToggles,
                        @Value("${petclinic.services.visits-url}") String visitsUrl) {
        this.restTemplate = restTemplate;
        this.chaosToggles = chaosToggles;
        this.visitsUrl = visitsUrl;
    }
```
and the call to `restTemplate.getForObject(visitsUrl + "/pets/visits?petId={petIds}", VisitsWireResponse.class, joinIds(petIds));` (add the `Value` import).
`RestTemplateConfig.java`: remove `@LoadBalanced` and its import (keep building from the injected `RestTemplateBuilder` — it carries the observation instrumentation).
`CustomersServiceApplication.java`: remove `@EnableDiscoveryClient` and its import.
customers `application.yml`, default profile, add:
```yaml
petclinic:
  services:
    visits-url: http://visits-service:8082
```
customers `pom.xml`: delete the `spring-cloud-starter-consul-discovery` dependency.
If any other customers test constructs `VisitsServiceClient` (`grep -rn 'new VisitsServiceClient' spring-petclinic-customers-service/src/test`), add the third argument there too.

- [ ] **Step 8: vets and visits**

Remove `@EnableDiscoveryClient` (+ import) from `VetsServiceApplication.java` and `VisitsServiceApplication.java`; delete `spring-cloud-starter-consul-discovery` from both poms.

- [ ] **Step 9: Verify ConsulClient survives (spec spike 4) and run all tests**

Run:
```bash
./mvnw -q -pl spring-petclinic-customers-service,spring-petclinic-visits-service dependency:tree -Dincludes=org.springframework.cloud:spring-cloud-consul-core,com.ecwid.consul:consul-api | grep -E 'consul-core|consul-api'
./mvnw -q -pl spring-petclinic-api-gateway,spring-petclinic-customers-service,spring-petclinic-vets-service,spring-petclinic-visits-service test
grep -rn 'LoadBalanced\|EnableDiscoveryClient\|lb://\|consul-discovery' spring-petclinic-{api-gateway,customers-service,vets-service,visits-service}/src spring-petclinic-{api-gateway,customers-service,vets-service,visits-service}/pom.xml
```
Expected: both modules still resolve `spring-cloud-consul-core` and `consul-api` (the `ConsulClient` bean for `ChaosToggleWatcher` comes from core, via the config starter); all tests PASS; final grep prints nothing.

- [ ] **Step 10: CHANGES.md and commit**

Append to `CHANGES.md`:
```markdown
## K8s-native service discovery (2026-09-25)

- Removed Consul discovery and Spring Cloud LoadBalancer from the four deployed services. Downstream calls use K8s Service DNS base URLs (`petclinic.services.*-url`); load balancing, retries and outlier detection move to the Istio mesh. Consul remains the config center (`config/` KV) and chaos-toggle store (`chaos/` KV).
- Gateway: removed the `Retry` default filter (it retried non-idempotent POSTs, and stacked with mesh retries it multiplies load); kept the Resilience4j `CircuitBreaker` + fallback. Removed the never-deployed `genai-service` route.
```
```bash
git add -A
git commit -m "Replace Consul discovery with K8s Service DNS in the deployed services

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 11: Update the cross-repo contract (lab repo)**

In `lab-environment/CLAUDE.md` contract table, change the "Service names" row's "Consumed by" to `K8s Service names (DNS), both KV conventions above` and add a row: `| Service discovery | K8s Service DNS (`http://<service>:<port>`), load balancing by the Istio mesh. Consul is config center + chaos toggles only — no service registration | fork (`petclinic.services.*-url`), MCP `get_service_health` (reads K8s) |`.
```bash
cd /home/ubuntu/jerome/lab-environment
git add CLAUDE.md
git commit -m "Record K8s-native discovery in the cross-repo contract

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: Toolkit — K8s-backed service health, service-label metrics

**Files (all in `/home/ubuntu/jerome/ops-agent-toolkit-mcp`):**
- Create: `k8s.py`, `tests/__init__.py`, `tests/test_discovery.py`, `tests/test_metrics.py`, `requirements-dev.txt`
- Modify: `settings.py`, `tools/discovery.py`, `tools/metrics.py`, `README.md`

**Interfaces:**
- Consumes: Prometheus label `service` (Task 5); RBAC from Task 10.
- Produces: `get_service_health(service: str) -> dict` with keys `service, registered, source, instance_count, healthy_instance_count, instances[] {pod, node, address, port, status ('passing'|'critical'), restart_count}`; internal `service_health(client: httpx.AsyncClient, namespace: str, service: str) -> dict`; `metrics.build_query(service: str, metric_name: str) -> str`.

- [ ] **Step 1: Branch and dev deps**

```bash
cd /home/ubuntu/jerome/ops-agent-toolkit-mcp && git checkout -b k8s-service-health
printf 'pytest>=8,<9\n' > requirements-dev.txt
.venv/bin/pip install -q -r requirements-dev.txt && .venv/bin/python -m pytest --version
```
Expected: `pytest 8.x`.

- [ ] **Step 2: Failing tests**

`tests/__init__.py`: empty. `tests/test_discovery.py`:
```python
import asyncio

import httpx
import pytest

from tools.discovery import service_health


def _client(slices, pods, status=200):
    def handler(request: httpx.Request) -> httpx.Response:
        if status != 200:
            return httpx.Response(status, json={"message": "forbidden"})
        if request.url.path.endswith("/endpointslices"):
            assert request.url.params["labelSelector"] == "kubernetes.io/service-name=customers-service"
            return httpx.Response(200, json={"items": slices})
        if request.url.path.endswith("/pods"):
            return httpx.Response(200, json={"items": pods})
        return httpx.Response(404)

    return httpx.AsyncClient(transport=httpx.MockTransport(handler), base_url="https://k8s.test")


def _pod(name, restarts):
    return {"metadata": {"name": name}, "status": {"containerStatuses": [{"restartCount": restarts}]}}


def _endpoint(name, ip, ready):
    return {
        "addresses": [ip],
        "conditions": {"ready": ready},
        "nodeName": "vps-oracle2",
        "targetRef": {"kind": "Pod", "name": name},
    }


def run(coro):
    return asyncio.run(coro)


def test_reports_each_instance_with_readiness_and_restarts():
    slices = [{"ports": [{"port": 8081}], "endpoints": [
        _endpoint("customers-b", "10.42.1.2", True),
        _endpoint("customers-a", "10.42.1.1", False),
    ]}]
    pods = [_pod("customers-a", 3), _pod("customers-b", 0), _pod("unrelated", 9)]

    async def go():
        async with _client(slices, pods) as c:
            return await service_health(c, "lab-environment", "customers-service")

    result = run(go())

    assert result["registered"] is True
    assert result["source"] == "kubernetes"
    assert result["instance_count"] == 2
    assert result["healthy_instance_count"] == 1
    assert result["instances"] == [
        {"pod": "customers-a", "node": "vps-oracle2", "address": "10.42.1.1", "port": 8081,
         "status": "critical", "restart_count": 3},
        {"pod": "customers-b", "node": "vps-oracle2", "address": "10.42.1.2", "port": 8081,
         "status": "passing", "restart_count": 0},
    ]


def test_scaled_to_zero_is_registered_with_no_instances():
    slices = [{"ports": [{"port": 8081}], "endpoints": None}]

    async def go():
        async with _client(slices, []) as c:
            return await service_health(c, "lab-environment", "customers-service")

    result = run(go())

    assert result["registered"] is True
    assert result["instance_count"] == 0
    assert result["healthy_instance_count"] == 0


def test_unknown_service_is_not_registered():
    async def go():
        async with _client([], []) as c:
            return await service_health(c, "lab-environment", "customers-service")

    assert run(go()) == {"service": "customers-service", "registered": False,
                         "source": "kubernetes", "instance_count": 0}


def test_api_error_raises_instead_of_reporting_unregistered():
    async def go():
        async with _client([], [], status=403) as c:
            return await service_health(c, "lab-environment", "customers-service")

    with pytest.raises(httpx.HTTPStatusError):
        run(go())
```
`tests/test_metrics.py`:
```python
from tools.metrics import build_query


def test_query_filters_on_service_label():
    assert build_query("customers-service", "http_server_requests_seconds_count") == \
        'http_server_requests_seconds_count{service="customers-service"}'
```
Run: `.venv/bin/python -m pytest -q`
Expected: FAIL — `ImportError: cannot import name 'service_health'` / `'build_query'`.

- [ ] **Step 3: Implement**

`settings.py` append:
```python
# In-cluster Kubernetes API access for get_service_health (service account
# token + CA mounted by the kubelet).
K8S_API_URL = os.environ.get("K8S_API_URL", "https://kubernetes.default.svc")
K8S_NAMESPACE = os.environ.get("K8S_NAMESPACE", "lab-environment")
K8S_SA_DIR = os.environ.get("K8S_SA_DIR", "/var/run/secrets/kubernetes.io/serviceaccount")
```
`k8s.py`:
```python
import httpx

from settings import HTTP_TIMEOUT_SECONDS, K8S_API_URL, K8S_SA_DIR


def k8s_client() -> httpx.AsyncClient:
    """AsyncClient for the in-cluster Kubernetes API, authenticated with the
    pod's service account token."""
    with open(f"{K8S_SA_DIR}/token") as f:
        token = f.read().strip()
    return httpx.AsyncClient(
        base_url=K8S_API_URL,
        headers={"Authorization": f"Bearer {token}"},
        verify=f"{K8S_SA_DIR}/ca.crt",
        timeout=HTTP_TIMEOUT_SECONDS,
    )
```
`tools/discovery.py`:
```python
import httpx

from audit import audited
from k8s import k8s_client
from settings import K8S_NAMESPACE


@audited
async def get_service_health(service: str) -> dict:
    """Check a service's instances and readiness as Kubernetes sees them
    (EndpointSlices + pods): one entry per pod with ready status and restarts."""
    async with k8s_client() as client:
        return await service_health(client, K8S_NAMESPACE, service)


async def service_health(client: httpx.AsyncClient, namespace: str, service: str) -> dict:
    slices_resp = await client.get(
        f"/apis/discovery.k8s.io/v1/namespaces/{namespace}/endpointslices",
        params={"labelSelector": f"kubernetes.io/service-name={service}"},
    )
    slices_resp.raise_for_status()
    slices = slices_resp.json().get("items", [])
    if not slices:
        return {"service": service, "registered": False, "source": "kubernetes", "instance_count": 0}

    pods_resp = await client.get(f"/api/v1/namespaces/{namespace}/pods")
    pods_resp.raise_for_status()
    pods = {p["metadata"]["name"]: p for p in pods_resp.json().get("items", [])}

    instances = []
    for s in slices:
        port = (s.get("ports") or [{}])[0].get("port")
        for ep in s.get("endpoints") or []:
            name = (ep.get("targetRef") or {}).get("name")
            statuses = pods.get(name, {}).get("status", {}).get("containerStatuses", [])
            instances.append(
                {
                    "pod": name,
                    "node": ep.get("nodeName"),
                    "address": (ep.get("addresses") or [None])[0],
                    "port": port,
                    "status": "passing" if (ep.get("conditions") or {}).get("ready") else "critical",
                    "restart_count": sum(cs.get("restartCount", 0) for cs in statuses),
                }
            )
    instances.sort(key=lambda i: i["pod"] or "")

    return {
        "service": service,
        "registered": True,
        "source": "kubernetes",
        "instance_count": len(instances),
        "healthy_instance_count": sum(1 for i in instances if i["status"] == "passing"),
        "instances": instances,
    }
```
`tools/metrics.py`: add below the imports
```python
def build_query(service: str, metric_name: str) -> str:
    # Prometheus discovers business pods via kubernetes_sd and labels each
    # series with `service` (the pod's app label) — see docker-gitops
    # k3s/apps/lab-environment/k8s/configmaps.yaml.
    return f'{metric_name}{{service="{service}"}}'
```
and replace the two-line comment + `query = f'...instance=~...'` inside `query_metric` with `query = build_query(service, metric_name)`.

- [ ] **Step 4: Run tests**

Run: `.venv/bin/python -m pytest -q`
Expected: `5 passed`.

- [ ] **Step 5: README and commit**

In `README.md`'s tool table change the `get_service_health` row to: `| \`get_service_health(service)\` | Kubernetes API | Per-instance readiness and restart counts (EndpointSlices + pods) |`, and the `query_metric` description note to mention the `service` label.
```bash
git add -A
git commit -m "Read service health from Kubernetes and filter metrics by service label

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: Deploy the discovery migration (no mesh yet)

**Files:**
- Modify: four business manifests (image tag, drop `SPRING_CLOUD_CONSUL_DISCOVERY_PREFER_IP_ADDRESS`), `k8s/mcp-toolkit.yaml` (tag, SA, RBAC)

**Interfaces:**
- Consumes: Task 8 fork commit, Task 9 toolkit commit, Task 2 scripts.
- Produces: running K8s-native discovery; ServiceAccount `mcp-toolkit`.

- [ ] **Step 1: Build and import from the feature branches**

```bash
cd /home/ubuntu/jerome/lab-environment && ./scripts/build.sh 2>&1 | tail -2
FORK_TAG=<printed>; MCP_TAG=<printed>
./scripts/push-to-k3s.sh ops-lab/api-gateway:$FORK_TAG ops-lab/customers-service:$FORK_TAG ops-lab/vets-service:$FORK_TAG ops-lab/visits-service:$FORK_TAG ops-lab/mcp-toolkit:$MCP_TAG
```
Expected: tags equal `git -C ../spring-petclinic-microservices rev-parse --short=12 HEAD` and the toolkit equivalent; five images listed on oracle2.

- [ ] **Step 2: Manifests**

In the worktree: set the new tags; delete the two-line `SPRING_CLOUD_CONSUL_DISCOVERY_PREFER_IP_ADDRESS` env entry from all four business manifests. In `mcp-toolkit.yaml` prepend:
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: mcp-toolkit
  namespace: lab-environment
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: mcp-toolkit-health
  namespace: lab-environment
rules:
  # get_service_health: read-only view of instances, nothing else.
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list"]
  - apiGroups: ["discovery.k8s.io"]
    resources: ["endpointslices"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: mcp-toolkit-health
  namespace: lab-environment
subjects:
  - kind: ServiceAccount
    name: mcp-toolkit
    namespace: lab-environment
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: mcp-toolkit-health
---
```
and add `serviceAccountName: mcp-toolkit` to its pod spec.
```bash
git add k3s/apps/lab-environment/k8s/
git commit -m "feat(lab-environment): deploy K8s-native discovery and K8s-backed health tool

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 3: Confirm, deploy, verify**

After user confirmation merge + sync; `kubectl -n lab-environment rollout status deploy/api-gateway deploy/customers-service deploy/vets-service deploy/visits-service deploy/mcp-toolkit --timeout=900s`. Then:
```bash
# business traffic still healthy through the rollout
kubectl -n lab-environment logs deploy/traffic-generator --since=20m | awk '{print $2}' | sort | uniq -c
# Consul no longer holds service registrations
curl -s http://10.0.0.95:30092/v1/catalog/services
# one trace spans gateway -> customers -> visits (trace propagation survived)
curl -s 'http://10.0.0.95:30095/api/traces?service=api-gateway&limit=50&lookback=10m' | python3 -c "
import json,sys
for t in json.load(sys.stdin)['data']:
    s={p['serviceName'] for p in t['processes'].values()}
    if {'api-gateway','customers-service','visits-service'} <= s: print('CONNECTED', t['traceID']); break
else: print('NOT FOUND')"
# chaos toggle still read from Consul (ConsulClient alive)
kubectl -n lab-environment exec deploy/consul -- consul kv put chaos/customers-service/slow-query-enabled true
sleep 8; curl -s -o /dev/null -w 'slow=%{time_total}\n' http://10.0.0.95:30097/api/customer/owners/1
kubectl -n lab-environment exec deploy/consul -- consul kv put chaos/customers-service/slow-query-enabled false
# health tool reads K8s
kubectl -n lab-environment exec deploy/mcp-toolkit -- python -c "import asyncio,json; from tools.discovery import get_service_health; print(json.dumps(asyncio.run(get_service_health('customers-service')))[:300])"
```
Expected: generator codes all `200` (a handful of non-200 during the api-gateway rollout means a regression — stop); catalog `{"consul":[]}`; `CONNECTED <id>`; `slow=` ≥ 3 s (slow-query toggle applied — verify the exact endpoint the toggle affects in `OwnerResource` if not); tool output shows `"source": "kubernetes"`, `"instance_count": 5, "healthy_instance_count": 5`.

- [ ] **Step 4: Merge app repos (user confirms)**

Ask the user, then in each of the fork, toolkit and lab repos: `git checkout main && git merge --ff-only <branch> && git push`.

---

### Task 11: Mesh onboarding — ambient, identities, waypoint, telemetry

**Files:**
- Modify: `k3s/istio/istiod-values.yaml`, `k8s/jaeger.yaml`, `k8s/namespace.yaml`, four business manifests (SA, Service label)
- Create: `k8s/serviceaccounts.yaml`, `k8s/waypoint.yaml`, `k8s/telemetry.yaml`

**Interfaces:**
- Produces: extension providers `otel-lab`, `lab-json-accesslog`; waypoint Gateway `waypoint` (SA `waypoint`, principal `cluster.local/ns/lab-environment/sa/waypoint`); SAs `api-gateway`, `customers-service`, `vets-service`, `visits-service`. Access-log JSON keys: `start_time, method, path, protocol, response_code, response_flags, duration_ms, upstream_service_time, upstream_cluster, upstream_host, attempts, trace_id, request_id, downstream_peer, route_name, authority`.

- [ ] **Step 1: Extension providers**

In `k3s/istio/istiod-values.yaml` under `meshConfig.extensionProviders` append:
```yaml
    # lab-environment: Envoy spans to the lab's own Jaeger over OTLP.
    # OpenTelemetry (W3C traceparent), not Zipkin (B3): Spring Boot 4
    # propagates W3C, so B3 would split Envoy and app spans into two traces.
    - name: otel-lab
      opentelemetry:
        service: jaeger.lab-environment.svc.cluster.local
        port: 4317
    # lab-environment: JSON access log with trace_id, so a log line links
    # to its Jaeger trace and upstream_host/attempts show LB and retries.
    - name: lab-json-accesslog
      envoyFileAccessLog:
        path: /dev/stdout
        logFormat:
          labels:
            start_time: "%START_TIME%"
            method: "%REQ(:METHOD)%"
            path: "%REQ(X-ENVOY-ORIGINAL-PATH?:PATH)%"
            protocol: "%PROTOCOL%"
            response_code: "%RESPONSE_CODE%"
            response_flags: "%RESPONSE_FLAGS%"
            duration_ms: "%DURATION%"
            upstream_service_time: "%RESP(X-ENVOY-UPSTREAM-SERVICE-TIME)%"
            upstream_cluster: "%UPSTREAM_CLUSTER%"
            upstream_host: "%UPSTREAM_HOST%"
            attempts: "%UPSTREAM_REQUEST_ATTEMPT_COUNT%"
            trace_id: "%TRACE_ID%"
            request_id: "%REQ(X-REQUEST-ID)%"
            downstream_peer: "%DOWNSTREAM_PEER_URI_SAN%"
            route_name: "%ROUTE_NAME%"
            authority: "%REQ(:AUTHORITY)%"
```

- [ ] **Step 2: Jaeger OTLP**

`jaeger.yaml`: add env `- name: COLLECTOR_OTLP_ENABLED` / `value: "true"`, container port `- containerPort: 4317` / `name: otlp-grpc`, and Service port:
```yaml
    - port: 4317
      targetPort: 4317
      name: grpc-otlp
      appProtocol: grpc
```

- [ ] **Step 3: Identities**

`serviceaccounts.yaml`:
```yaml
# One identity per workload: the mesh authorizes by these (authz.yaml).
apiVersion: v1
kind: ServiceAccount
metadata: {name: api-gateway, namespace: lab-environment}
---
apiVersion: v1
kind: ServiceAccount
metadata: {name: customers-service, namespace: lab-environment}
---
apiVersion: v1
kind: ServiceAccount
metadata: {name: vets-service, namespace: lab-environment}
---
apiVersion: v1
kind: ServiceAccount
metadata: {name: visits-service, namespace: lab-environment}
```
Add `serviceAccountName: <name>` to each business Deployment's pod spec.

- [ ] **Step 4: Waypoint**

`waypoint.yaml`:
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: waypoint-params
  namespace: lab-environment
data:
  # Per-Gateway overrides: the cluster-wide waypoint default in
  # k3s/istio/istiod-values.yaml (200m limit) is sized for pr-lanes.
  deployment: |
    spec:
      replicas: 2
      template:
        metadata:
          labels:
            trivy-operator.skip: "true"
          annotations:
            proxy.istio.io/config: |
              proxyStatsMatcher:
                inclusionRegexps:
                  - ".*outlier_detection.*"
                  - ".*upstream_rq_retry.*"
                  - ".*rbac.*"
        spec:
          containers:
            - name: istio-proxy
              env:
                - name: TZ
                  value: "Asia/Hong_Kong"
              resources:
                requests: {cpu: 100m, memory: 128Mi}
                limits: {cpu: 500m, memory: 256Mi}
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: waypoint
  namespace: lab-environment
  labels:
    istio.io/waypoint-for: service
spec:
  gatewayClassName: istio-waypoint
  infrastructure:
    parametersRef:
      group: ""
      kind: ConfigMap
      name: waypoint-params
  listeners:
    - name: mesh
      port: 15008
      protocol: HBONE
```

- [ ] **Step 5: Telemetry**

`telemetry.yaml`:
```yaml
apiVersion: telemetry.istio.io/v1
kind: Telemetry
metadata:
  name: mesh-default
  namespace: lab-environment
spec:
  tracing:
    - providers:
        - name: otel-lab
      randomSamplingPercentage: 100.0
  accessLogging:
    - providers:
        - name: lab-json-accesslog
```

- [ ] **Step 6: Enrol namespace and route business Services via the waypoint**

`namespace.yaml` Namespace metadata:
```yaml
  labels:
    istio.io/dataplane-mode: ambient
```
In each of the four business `Service` objects add:
```yaml
  labels:
    istio.io/use-waypoint: waypoint
```

- [ ] **Step 7: Commit, confirm, deploy (istio-istiod first)**

```bash
git add k3s/istio/istiod-values.yaml k3s/apps/lab-environment/k8s/
git commit -m "feat(lab-environment): enrol in Istio ambient with a waypoint and OTel tracing

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
After confirmation merge; `argocd app sync istio-istiod`; confirm `kubectl -n istio-system get cm istio -o yaml | grep -c 'otel-lab\|lab-json-accesslog'` = 2; then `argocd app sync lab-environment`; `kubectl -n lab-environment rollout status deploy/waypoint --timeout=300s`.

- [ ] **Step 8: Gate — spec spikes 2 and 5 (one trace, trace_id in logs)**

```bash
TID=$(openssl rand -hex 16); SID=$(openssl rand -hex 8)
kubectl -n lab-environment exec deploy/traffic-generator -- curl -s -o /dev/null -w '%{http_code}\n' \
  -H "traceparent: 00-$TID-$SID-01" http://api-gateway:8080/api/gateway/owners/6
sleep 10
curl -s "http://10.0.0.95:30095/api/traces/$TID" | python3 -c "
import json,sys
t=json.load(sys.stdin)['data'][0]
print(sorted({p['serviceName'] for p in t['processes'].values()}), len(t['spans']))"
kubectl -n lab-environment logs -l gateway.networking.k8s.io/gateway-name=waypoint --since=2m --tail=-1 | grep -c "$TID"
```
Expected: `200`; service list contains `api-gateway`, `customers-service`, `visits-service` **and** a waypoint service (e.g. `waypoint.lab-environment`); waypoint log count ≥ 2 (gateway→customers and customers→visits hops). If the Envoy spans land in a different trace or `trace_id` is empty: STOP — return to the spec (D9).

- [ ] **Step 9: Verify mTLS and health**

```bash
ZT=$(kubectl -n istio-system get pod -l app=ztunnel --field-selector spec.nodeName=vps-oracle2 -o name)
kubectl -n istio-system logs $ZT --since=2m | grep -m3 'lab-environment/sa/'
kubectl -n lab-environment logs deploy/traffic-generator --since=10m | awk '{print $2}' | sort | uniq -c
curl -s http://10.0.0.95:30093/api/v1/targets | grep -o '"health":"[a-z]*"' | sort | uniq -c
```
Expected: ztunnel lines showing `src.identity`/`dst.identity` with `spiffe://cluster.local/ns/lab-environment/sa/...`; generator all `200`; all Prometheus targets `up`.

---

### Task 12: Istio ingress gateway on NodePort 30097

**Files:**
- Create: `k8s/ingress.yaml`
- Modify: `k8s/api-gateway.yaml` (Service), `k8s/traffic-generator.yaml` (`TARGET_URL`)

**Interfaces:**
- Consumes: Task 1 spike 3/8 results (ports of generated Service; `ingress-use-waypoint` requirement).
- Produces: Service `lab-ingress-istio` (NodePort 30097), SA `lab-ingress-istio` (principal `cluster.local/ns/lab-environment/sa/lab-ingress-istio`).

- [ ] **Step 1: Write ingress.yaml**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: lab-ingress-params
  namespace: lab-environment
data:
  # Takes over NodePort 30097 from the api-gateway Service so NPM's
  # api.lab host and the "Lab API Down" probe keep working unchanged.
  service: |
    spec:
      type: NodePort
      ports:
        - name: http
          port: 80
          nodePort: 30097
  deployment: |
    spec:
      replicas: 2
      template:
        metadata:
          labels:
            trivy-operator.skip: "true"
        spec:
          containers:
            - name: istio-proxy
              env:
                - name: TZ
                  value: "Asia/Hong_Kong"
              resources:
                requests: {cpu: 100m, memory: 128Mi}
                limits: {cpu: 500m, memory: 256Mi}
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: lab-ingress
  namespace: lab-environment
spec:
  gatewayClassName: istio
  infrastructure:
    parametersRef:
      group: ""
      kind: ConfigMap
      name: lab-ingress-params
  listeners:
    - name: http
      port: 80
      protocol: HTTP
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: lab-api
  namespace: lab-environment
spec:
  parentRefs:
    - name: lab-ingress
  rules:
    - backendRefs:
        - name: api-gateway
          port: 8080
```

- [ ] **Step 2: api-gateway Service → ClusterIP, ingress via waypoint**

Replace the api-gateway `Service` with:
```yaml
apiVersion: v1
kind: Service
metadata:
  name: api-gateway
  namespace: lab-environment
  labels:
    istio.io/use-waypoint: waypoint
    # Without this, ingress-gateway traffic skips the waypoint and the
    # edge policies in resilience.yaml/authz.yaml never apply to it.
    istio.io/ingress-use-waypoint: "true"
spec:
  selector:
    app: api-gateway
  ports:
    - name: http
      port: 8080
      targetPort: 8080
```
(If Task 1 spike 8 showed the label is not needed, keep it anyway — it states intent — and note the observation in the commit message.)
In `traffic-generator.yaml` set `TARGET_URL` to `http://lab-ingress-istio:80`.

- [ ] **Step 3: Commit, confirm (brief entry outage), deploy**

```bash
git add k3s/apps/lab-environment/k8s/
git commit -m "feat(lab-environment): front the lab with an Istio ingress gateway on NodePort 30097

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
After confirmation merge + sync. If the generated Service fails with "provided port is already allocated", run `argocd app sync lab-environment` once more (the api-gateway Service releases 30097 in the same sync).

- [ ] **Step 4: Verify the external path (spec spike 6)**

```bash
kubectl -n lab-environment get svc lab-ingress-istio -o jsonpath='{.spec.type} {range .spec.ports[*]}{.name}={.nodePort} {end}{"\n"}'
docker exec npm curl -s -o /dev/null -w 'npm->30097 %{http_code}\n' http://10.0.0.95:30097/api/customer/owners
curl -s -o /dev/null -w 'tailscale->30097 %{http_code}\n' http://100.100.140.33:30097/api/customer/owners
grep -n '30097' /home/ubuntu/jerome/docker-gitops/vps_oracle/compose/monitoring/prometheus/prometheus.yml
kubectl -n lab-environment logs deploy/traffic-generator --since=5m | awk '{print $2}' | sort | uniq -c
```
Expected: `NodePort http=30097`; both curls `200` (if the NPM container lacks curl, use `docker exec npm wget -qO- ...`); the probe target printed by grep is one of the two tested URLs; generator all `200`. If `npm->30097` fails: revert this commit (merge a `git revert`), then consult `docs/incidents/` for NodePort hairpin records before retrying.

- [ ] **Step 5: Verify the entry hop is traced**

Run: `curl -s 'http://10.0.0.95:30095/api/services'`
Expected: list includes a `lab-ingress` Envoy service name alongside the app services.

---

### Task 13: Evidence wiring — Envoy metrics, log↔trace links, dashboard

**Files:**
- Modify: `k8s/configmaps.yaml` (prometheus `envoy-stats` job, promtail JSON stage, Grafana datasources), `k8s/prometheus.yaml` (bump `config-rev`), `k8s/grafana.yaml`
- Create: `k8s/grafana-dashboards.yaml`

**Interfaces:**
- Produces: Grafana datasource UIDs `prometheus`, `loki`, `jaeger`; dashboard uid `lab-mesh-overview`.

- [ ] **Step 1: Envoy scrape job**

Append to `scrape_configs` in `prometheus-config`:
```yaml
      # Waypoint + ingress Envoy stats (istio_requests_total etc.).
      - job_name: envoy-stats
        metrics_path: /stats/prometheus
        kubernetes_sd_configs:
          - role: pod
            namespaces:
              names: [lab-environment]
        relabel_configs:
          - source_labels: [__meta_kubernetes_pod_label_gateway_networking_k8s_io_gateway_name]
            action: keep
            regex: waypoint|lab-ingress
          - source_labels: [__address__]
            regex: '([^:]+)(?::\d+)?'
            replacement: '$1:15020'
            target_label: __address__
          - source_labels: [__meta_kubernetes_pod_label_gateway_networking_k8s_io_gateway_name]
            target_label: gateway
          - source_labels: [__meta_kubernetes_pod_name]
            target_label: pod
```
Bump `lab.jerome/config-rev` in `prometheus.yaml` to `"2"`.

- [ ] **Step 2: Promtail JSON stage**

In `promtail-config`'s `pipeline_stages`, append after the `labels` stage:
```yaml
          # Envoy (waypoint/ingress) JSON access logs: promote only
          # low-cardinality fields; trace_id stays in the line (Grafana's
          # derived field links it to Jaeger).
          - match:
              selector: '{service="istio-proxy"}'
              stages:
                - json:
                    expressions:
                      response_code: response_code
                      response_flags: response_flags
                - labels:
                    response_code:
                    response_flags:
```

- [ ] **Step 3: Grafana datasources with links**

Replace `datasources.yml` in `grafana-provisioning`:
```yaml
    apiVersion: 1

    datasources:
      - name: Prometheus
        uid: prometheus
        type: prometheus
        access: proxy
        url: http://prometheus:9090
        isDefault: true

      - name: Loki
        uid: loki
        type: loki
        access: proxy
        url: http://loki:3100
        jsonData:
          # Envoy JSON logs carry "trace_id"; Spring app logs carry the same
          # 32-hex trace id in their correlation prefix.
          derivedFields:
            - name: TraceID
              matcherRegex: '([0-9a-f]{32})'
              datasourceUid: jaeger
              url: '$${__value.raw}'

      - name: Jaeger
        uid: jaeger
        type: jaeger
        access: proxy
        url: http://jaeger:16686
        jsonData:
          tracesToLogsV2:
            datasourceUid: loki
            spanStartTimeShift: '-5m'
            spanEndTimeShift: '5m'
            customQuery: true
            query: '{namespace="lab-environment"} |= "$${__trace.traceId}"'
```

- [ ] **Step 4: Dashboard**

`grafana-dashboards.yaml`:
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboards
  namespace: lab-environment
data:
  lab-mesh-overview.json: |
    {
      "uid": "lab-mesh-overview",
      "title": "Lab Mesh Overview",
      "schemaVersion": 39,
      "refresh": "10s",
      "time": {"from": "now-30m", "to": "now"},
      "panels": [
        {"type": "timeseries", "title": "customers-service RPS per pod (load balancing)",
         "gridPos": {"x": 0, "y": 0, "w": 12, "h": 8},
         "datasource": {"type": "prometheus", "uid": "prometheus"},
         "targets": [{"expr": "sum by (pod) (rate(http_server_requests_seconds_count{service=\"customers-service\", uri!~\"/actuator.*\"}[1m]))", "legendFormat": "{{pod}}"}]},
        {"type": "timeseries", "title": "Mesh requests by service and code (waypoint)",
         "gridPos": {"x": 12, "y": 0, "w": 12, "h": 8},
         "datasource": {"type": "prometheus", "uid": "prometheus"},
         "targets": [{"expr": "sum by (destination_canonical_service, response_code) (rate(istio_requests_total{reporter=\"waypoint\"}[1m]))", "legendFormat": "{{destination_canonical_service}} {{response_code}}"}]},
        {"type": "timeseries", "title": "Envoy response flags (UT=timeout, UH=no healthy upstream, URX=retry limit, UO=overflow)",
         "gridPos": {"x": 0, "y": 8, "w": 12, "h": 8},
         "datasource": {"type": "prometheus", "uid": "prometheus"},
         "targets": [{"expr": "sum by (destination_canonical_service, response_flags) (rate(istio_requests_total{response_flags!=\"-\"}[5m]))", "legendFormat": "{{destination_canonical_service}} {{response_flags}}"}]},
        {"type": "timeseries", "title": "P99 latency (ms) by service",
         "gridPos": {"x": 12, "y": 8, "w": 12, "h": 8},
         "datasource": {"type": "prometheus", "uid": "prometheus"},
         "targets": [{"expr": "histogram_quantile(0.99, sum by (le, destination_canonical_service) (rate(istio_request_duration_milliseconds_bucket{reporter=\"waypoint\"}[5m])))", "legendFormat": "{{destination_canonical_service}}"}]},
        {"type": "timeseries", "title": "Outlier ejections active",
         "gridPos": {"x": 0, "y": 16, "w": 12, "h": 8},
         "datasource": {"type": "prometheus", "uid": "prometheus"},
         "targets": [{"expr": "sum by (cluster_name) (envoy_cluster_outlier_detection_ejections_active{gateway=\"waypoint\"})", "legendFormat": "{{cluster_name}}"}]},
        {"type": "timeseries", "title": "Upstream retries",
         "gridPos": {"x": 12, "y": 16, "w": 12, "h": 8},
         "datasource": {"type": "prometheus", "uid": "prometheus"},
         "targets": [{"expr": "sum by (cluster_name) (rate(envoy_cluster_upstream_rq_retry{gateway=\"waypoint\"}[5m]))", "legendFormat": "{{cluster_name}}"}]}
      ]
    }
```
In `grafana.yaml` add a volume `dashboards` (`configMap: {name: grafana-dashboards}`) mounted at `/etc/grafana/provisioning/dashboards/json` (directory mount, no subPath — hot-reloads), and a pod-template annotation `lab.jerome/config-rev: "1"` (datasources are subPath-mounted; bump on change).

- [ ] **Step 5: Validate, commit, deploy**

Run: `python3 -c "import yaml,json; d=[x for x in yaml.safe_load_all(open('k3s/apps/lab-environment/k8s/grafana-dashboards.yaml'))][0]; json.loads(d['data']['lab-mesh-overview.json']); print('JSON_OK')"`
Expected: `JSON_OK`.
```bash
git add k3s/apps/lab-environment/k8s/
git commit -m "feat(lab-environment): Envoy metrics, log-trace links and the Lab Mesh Overview dashboard

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
After confirmation merge + sync.

- [ ] **Step 6: Verify (acceptance 2 and 3)**

```bash
curl -s 'http://10.0.0.95:30093/api/v1/query?query=count%20by%20(gateway)(up%7Bjob%3D%22envoy-stats%22%7D)' | grep -o '"gateway":"[a-z-]*"' 
curl -s 'http://10.0.0.95:30093/api/v1/query?query=sum%20by%20(pod)(rate(http_server_requests_seconds_count%7Bservice%3D%22customers-service%22%7D%5B5m%5D))' | grep -o '"pod":"[^"]*"' | wc -l
curl -s -G http://10.0.0.95:30094/api/datasources/proxy/uid/loki/loki/api/v1/query_range --data-urlencode 'query={service="istio-proxy"} |= "trace_id"' --data-urlencode 'limit=1' | grep -o '"trace_id\\":\\"[0-9a-f]*' | head -1
```
Expected: gateways `waypoint` and `lab-ingress`; `5` customers pods with traffic; one trace_id printed. Then open `http://10.0.0.95:30094/d/lab-mesh-overview` in a browser (or via NPM's grafana.lab host): all six panels have data except "Outlier ejections" (0 is correct) — and in Explore → Loki click a `TraceID` link to confirm it opens the trace in Jaeger, and from that trace "Logs for this span" returns the lines. Take screenshots for sub-project 2.

---

### Task 14: mTLS STRICT and least-privilege authorization

**Files:**
- Create: `k8s/mtls.yaml`, `k8s/authz.yaml`

**Interfaces:**
- Consumes: SAs from Tasks 3/4/5/6/10/11/12; waypoint principal; ingress principal `lab-ingress-istio`.

- [ ] **Step 1: mtls.yaml**

```yaml
# STRICT for business services and data stores. Ops UIs (grafana, jaeger,
# consul, prometheus, mcp-toolkit) stay PERMISSIVE: NPM reaches them in
# plaintext via NodePort from outside the mesh.
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata: {name: api-gateway, namespace: lab-environment}
spec: {selector: {matchLabels: {app: api-gateway}}, mtls: {mode: STRICT}}
---
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata: {name: customers-service, namespace: lab-environment}
spec: {selector: {matchLabels: {app: customers-service}}, mtls: {mode: STRICT}}
---
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata: {name: vets-service, namespace: lab-environment}
spec: {selector: {matchLabels: {app: vets-service}}, mtls: {mode: STRICT}}
---
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata: {name: visits-service, namespace: lab-environment}
spec: {selector: {matchLabels: {app: visits-service}}, mtls: {mode: STRICT}}
---
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata: {name: postgres, namespace: lab-environment}
spec: {selector: {matchLabels: {app: postgres}}, mtls: {mode: STRICT}}
---
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata: {name: redis, namespace: lab-environment}
spec: {selector: {matchLabels: {app: redis}}, mtls: {mode: STRICT}}
```

- [ ] **Step 2: authz.yaml (L7 policies in dry-run)**

```yaml
# L7 (waypoint): who may call which Service. Dry-run first; remove the
# istio.io/dry-run annotations once shadow denies are confirmed at zero.
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: api-gateway-callers
  namespace: lab-environment
  annotations: {istio.io/dry-run: "true"}
spec:
  targetRefs: [{kind: Service, group: "", name: api-gateway}]
  action: ALLOW
  rules:
    - from: [{source: {principals: [cluster.local/ns/lab-environment/sa/lab-ingress-istio]}}]
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: customers-service-callers
  namespace: lab-environment
  annotations: {istio.io/dry-run: "true"}
spec:
  targetRefs: [{kind: Service, group: "", name: customers-service}]
  action: ALLOW
  rules:
    - from: [{source: {principals: [cluster.local/ns/lab-environment/sa/api-gateway]}}]
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: visits-service-callers
  namespace: lab-environment
  annotations: {istio.io/dry-run: "true"}
spec:
  targetRefs: [{kind: Service, group: "", name: visits-service}]
  action: ALLOW
  rules:
    - from:
        - source:
            principals:
              - cluster.local/ns/lab-environment/sa/api-gateway
              - cluster.local/ns/lab-environment/sa/customers-service
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: vets-service-callers
  namespace: lab-environment
  annotations: {istio.io/dry-run: "true"}
spec:
  targetRefs: [{kind: Service, group: "", name: vets-service}]
  action: ALLOW
  rules:
    - from: [{source: {principals: [cluster.local/ns/lab-environment/sa/api-gateway]}}]
---
# actuator exposes env/heapdump: never reachable through Service traffic.
# Kubelet probes and Prometheus hit pods directly, not via the waypoint.
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: deny-actuator
  namespace: lab-environment
spec:
  targetRefs: [{kind: Gateway, group: gateway.networking.k8s.io, name: waypoint}]
  action: DENY
  rules:
    - to: [{operation: {paths: ["/actuator", "/actuator/*"]}}]
```

- [ ] **Step 3: Commit, confirm, deploy, observe dry-run**

```bash
git add k3s/apps/lab-environment/k8s/mtls.yaml k3s/apps/lab-environment/k8s/authz.yaml
git commit -m "feat(lab-environment): STRICT mTLS and dry-run L7 authorization

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
After confirmation merge + sync. Browse the app UI via NPM for a few pages, wait 10 minutes, then:
```bash
for p in $(kubectl -n lab-environment get pod -l gateway.networking.k8s.io/gateway-name=waypoint -o name); do
  kubectl -n lab-environment exec $p -- pilot-agent request GET stats | grep -E 'rbac.*shadow_denied' ; done
kubectl -n lab-environment exec deploy/traffic-generator -- curl -s -o /dev/null -w 'illegal %{http_code}\n' http://customers-service:8081/owners
for p in $(kubectl -n lab-environment get pod -l gateway.networking.k8s.io/gateway-name=waypoint -o name); do
  kubectl -n lab-environment exec $p -- pilot-agent request GET stats | grep -E 'rbac.*shadow_denied' ; done
kubectl -n lab-environment logs deploy/traffic-generator --since=10m | awk '{print $2}' | sort | uniq -c
```
Expected: first stats sum `0` shadow denies; the illegal call returns `200` (dry-run) and the second stats sum increases by 1; generator all `200`. A non-zero shadow count before the illegal call means a legitimate caller is missing from a policy — find it in the waypoint JSON log (`downstream_peer`) and fix the policy before enforcing.

- [ ] **Step 4: Enforce L7 and add L4 policies**

Remove the four `istio.io/dry-run` annotations. Append to `authz.yaml`:
```yaml
---
# L4 (ztunnel): business pods accept only the waypoint, plus Prometheus
# on the metrics port (it scrapes pod IPs directly).
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata: {name: api-gateway-direct, namespace: lab-environment}
spec:
  selector: {matchLabels: {app: api-gateway}}
  action: ALLOW
  rules:
    - from: [{source: {principals: [cluster.local/ns/lab-environment/sa/waypoint]}}]
    - from: [{source: {principals: [cluster.local/ns/lab-environment/sa/prometheus]}}]
      to: [{operation: {ports: ["8080"]}}]
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata: {name: customers-service-direct, namespace: lab-environment}
spec:
  selector: {matchLabels: {app: customers-service}}
  action: ALLOW
  rules:
    - from: [{source: {principals: [cluster.local/ns/lab-environment/sa/waypoint]}}]
    - from: [{source: {principals: [cluster.local/ns/lab-environment/sa/prometheus]}}]
      to: [{operation: {ports: ["8081"]}}]
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata: {name: visits-service-direct, namespace: lab-environment}
spec:
  selector: {matchLabels: {app: visits-service}}
  action: ALLOW
  rules:
    - from: [{source: {principals: [cluster.local/ns/lab-environment/sa/waypoint]}}]
    - from: [{source: {principals: [cluster.local/ns/lab-environment/sa/prometheus]}}]
      to: [{operation: {ports: ["8082"]}}]
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata: {name: vets-service-direct, namespace: lab-environment}
spec:
  selector: {matchLabels: {app: vets-service}}
  action: ALLOW
  rules:
    - from: [{source: {principals: [cluster.local/ns/lab-environment/sa/waypoint]}}]
    - from: [{source: {principals: [cluster.local/ns/lab-environment/sa/prometheus]}}]
      to: [{operation: {ports: ["8083"]}}]
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata: {name: postgres-clients, namespace: lab-environment}
spec:
  selector: {matchLabels: {app: postgres}}
  action: ALLOW
  rules:
    - from:
        - source:
            principals:
              - cluster.local/ns/lab-environment/sa/customers-service
              - cluster.local/ns/lab-environment/sa/vets-service
              - cluster.local/ns/lab-environment/sa/visits-service
              - cluster.local/ns/lab-environment/sa/db-init
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata: {name: redis-clients, namespace: lab-environment}
spec:
  selector: {matchLabels: {app: redis}}
  action: ALLOW
  rules:
    - from: [{source: {principals: [cluster.local/ns/lab-environment/sa/visits-service]}}]
```
Before committing, check nothing else talks to postgres/redis: `grep -rn 'postgres\|redis' k3s/apps/lab-environment/k8s/*.yaml | grep -v -E '^.*(postgres|redis)\.yaml|db-init|configmaps|authz|mtls'` — if `mcp-toolkit` or `prometheus` (exporters) connect, add their principals.
```bash
git add k3s/apps/lab-environment/k8s/authz.yaml
git commit -m "feat(lab-environment): enforce L7 authorization and add L4 direct-access policies

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
After confirmation merge + sync.

- [ ] **Step 5: Verify (acceptance 4)**

```bash
kubectl -n lab-environment exec deploy/traffic-generator -- curl -s -o /dev/null -w 'unauthorized-sa %{http_code}\n' http://customers-service:8081/owners
kubectl -n lab-environment exec deploy/traffic-generator -- curl -s -o /dev/null -w 'actuator %{http_code}\n' http://lab-ingress-istio/actuator/env
CIP=$(kubectl -n lab-environment get pod -l app=customers-service -o jsonpath='{.items[0].status.podIP}')
kubectl run -n default mtls-probe --rm -i --restart=Never --image=curlimages/curl:8.10.1 -- curl -s -m 5 -o /dev/null -w 'plaintext %{http_code}\n' http://$CIP:8081/actuator/health; echo "exit=$?"
kubectl -n lab-environment logs deploy/traffic-generator --since=5m | awk '{print $2}' | sort | uniq -c
curl -s http://10.0.0.95:30093/api/v1/targets | grep -o '"health":"[a-z]*"' | sort | uniq -c
kubectl -n lab-environment get pods | grep -v -E 'Running|Completed|NAME'
```
Expected: `unauthorized-sa 403`; `actuator 403`; plaintext fails (`000` / non-zero exit); generator all `200`; all targets `up`; no unhealthy pods (probes are unaffected).

---

### Task 15: Resident resilience policies

**Files:**
- Create: `k8s/resilience.yaml`

- [ ] **Step 1: Write resilience.yaml**

```yaml
# Resident production policies. Retries only at internal hops and only for
# idempotent GETs on transient failures (500 = app bug, not retried); the
# edge (api-gateway) never retries, so attempts never multiply across hops.
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata: {name: api-gateway, namespace: lab-environment}
spec:
  hosts: [api-gateway.lab-environment.svc.cluster.local]
  http:
    - route: [{destination: {host: api-gateway.lab-environment.svc.cluster.local}}]
      timeout: 5s
      retries: {attempts: 0}
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata: {name: customers-service, namespace: lab-environment}
spec:
  hosts: [customers-service.lab-environment.svc.cluster.local]
  http:
    - match: [{method: {exact: GET}}]
      route: [{destination: {host: customers-service.lab-environment.svc.cluster.local}}]
      timeout: 3s
      retries: {attempts: 2, perTryTimeout: 1s, retryOn: "connect-failure,refused-stream,unavailable,503"}
    - route: [{destination: {host: customers-service.lab-environment.svc.cluster.local}}]
      timeout: 5s
      retries: {attempts: 0}
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata: {name: visits-service, namespace: lab-environment}
spec:
  hosts: [visits-service.lab-environment.svc.cluster.local]
  http:
    - match: [{method: {exact: GET}}]
      route: [{destination: {host: visits-service.lab-environment.svc.cluster.local}}]
      timeout: 3s
      retries: {attempts: 2, perTryTimeout: 1s, retryOn: "connect-failure,refused-stream,unavailable,503"}
    - route: [{destination: {host: visits-service.lab-environment.svc.cluster.local}}]
      timeout: 5s
      retries: {attempts: 0}
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata: {name: vets-service, namespace: lab-environment}
spec:
  hosts: [vets-service.lab-environment.svc.cluster.local]
  http:
    - match: [{method: {exact: GET}}]
      route: [{destination: {host: vets-service.lab-environment.svc.cluster.local}}]
      timeout: 3s
      retries: {attempts: 2, perTryTimeout: 1s, retryOn: "connect-failure,refused-stream,unavailable,503"}
    - route: [{destination: {host: vets-service.lab-environment.svc.cluster.local}}]
      timeout: 5s
      retries: {attempts: 0}
---
# maxEjectionPercent 50: with 5 customers pods at most 2 are ejected; with a
# single replica (vets, visits) it floors to 0 — Envoy never ejects the last
# host, by design.
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata: {name: api-gateway, namespace: lab-environment}
spec:
  host: api-gateway.lab-environment.svc.cluster.local
  trafficPolicy:
    connectionPool:
      tcp: {maxConnections: 100}
      http: {http1MaxPendingRequests: 100, http2MaxRequests: 200}
    outlierDetection: {consecutive5xxErrors: 5, interval: 10s, baseEjectionTime: 30s, maxEjectionPercent: 50}
---
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata: {name: customers-service, namespace: lab-environment}
spec:
  host: customers-service.lab-environment.svc.cluster.local
  trafficPolicy:
    connectionPool:
      tcp: {maxConnections: 100}
      http: {http1MaxPendingRequests: 100, http2MaxRequests: 200}
    outlierDetection: {consecutive5xxErrors: 5, interval: 10s, baseEjectionTime: 30s, maxEjectionPercent: 50}
---
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata: {name: visits-service, namespace: lab-environment}
spec:
  host: visits-service.lab-environment.svc.cluster.local
  trafficPolicy:
    connectionPool:
      tcp: {maxConnections: 100}
      http: {http1MaxPendingRequests: 100, http2MaxRequests: 200}
    outlierDetection: {consecutive5xxErrors: 5, interval: 10s, baseEjectionTime: 30s, maxEjectionPercent: 50}
---
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata: {name: vets-service, namespace: lab-environment}
spec:
  host: vets-service.lab-environment.svc.cluster.local
  trafficPolicy:
    connectionPool:
      tcp: {maxConnections: 100}
      http: {http1MaxPendingRequests: 100, http2MaxRequests: 200}
    outlierDetection: {consecutive5xxErrors: 5, interval: 10s, baseEjectionTime: 30s, maxEjectionPercent: 50}
```

- [ ] **Step 2: Commit, confirm, deploy, verify config reached Envoy**

```bash
git add k3s/apps/lab-environment/k8s/resilience.yaml
git commit -m "feat(lab-environment): resident timeouts, retries, outlier detection and connection pools

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
After confirmation merge + sync:
```bash
W=$(kubectl -n lab-environment get pod -l gateway.networking.k8s.io/gateway-name=waypoint -o name | head -1)
kubectl -n lab-environment exec $W -- pilot-agent request GET config_dump > $SCRATCH/waypoint-config.json
grep -c '"per_try_timeout": "1s"' $SCRATCH/waypoint-config.json
grep -c '"consecutive_5xx": 5' $SCRATCH/waypoint-config.json
kubectl -n lab-environment logs deploy/traffic-generator --since=5m | awk '{print $2}' | sort | uniq -c
```
Expected: per-try count ≥ 3 (customers, visits, vets GET routes), outlier count ≥ 4; generator all `200`.

---

### Task 16: Acceptance run, RCA symptom record, docs

**Files:**
- Modify: spec (append "Implementation results"), `k3s/apps/lab-environment/README.md`

- [ ] **Step 1: Acceptance 1 — rolling update, zero errors, data intact**

Bump a pod-template annotation `lab.jerome/rollout-rev: "1"` in `customers-service.yaml`, commit (`chore(lab-environment): rolling-restart customers-service for acceptance`), confirm, merge, sync. Record before/after:
```bash
kubectl -n lab-environment exec deploy/postgres -- psql -U petclinic -d customers -tAc 'select count(*) from owners' # before
kubectl -n lab-environment rollout status deploy/customers-service --timeout=900s
kubectl -n lab-environment exec deploy/postgres -- psql -U petclinic -d customers -tAc 'select count(*) from owners' # after
kubectl -n lab-environment logs deploy/traffic-generator --since=20m | awk '{print $2}' | sort | uniq -c
```
Expected: counts equal; generator all `200`.

- [ ] **Step 2: Acceptance 5 and 6**

```bash
kubectl -n lab-environment exec deploy/mcp-toolkit -- python -c "import asyncio,json; from tools.discovery import get_service_health; r=asyncio.run(get_service_health('customers-service')); print(r['instance_count'], r['healthy_instance_count'])"
```
Expected: `5 5`. Check the compose Grafana alert `Lab API Down` is `Normal` (Grafana UI → Alerting).

For each scenario in `lab-environment/scenarios/scenarios.yaml` (`customers_slow_query`, `customers_downstream_error`, `visits_redis_timeout`): trigger via `kubectl -n lab-environment exec deploy/consul -- consul kv put <key> true`, wait 10 s, then run 5× `curl -s -o /dev/null -w '%{http_code} %{time_total}\n' http://10.0.0.95:30097/api/gateway/owners/6`, capture `kubectl -n lab-environment logs -l gateway.networking.k8s.io/gateway-name=waypoint --since=1m | grep -v '"response_code":"200"' | tail -3`, reset the key. Record per scenario: status codes, durations, `response_flags`, `attempts`.

- [ ] **Step 3: Review Focus checks 4 and 5**

```bash
kubectl -n lab-environment delete pod -l app=customers-service --wait=false
sleep 180; kubectl -n lab-environment get deploy customers-service
kubectl -n lab-environment logs deploy/traffic-generator --since=4m | awk '{print $1, $2}' | grep -v ' 200$' | tail -3
kubectl -n lab-environment delete pod -l app=consul
sleep 60; kubectl -n lab-environment logs deploy/traffic-generator --since=70s | awk '{print $2}' | sort | uniq -c
```
Expected: customers 5/5 ready within 3 min with the last non-200 timestamp inside that window (record how long the outage lasted — all 5 JVMs restarting at once on 2 cores is a real outage; note it); after the Consul restart the generator shows only `200`.

- [ ] **Step 4: Record results in the spec**

Append to the spec:
```markdown
## Implementation results (<date>)

| Acceptance | Result | Evidence |
|---|---|---|
| 1 Rolling update | <PASS/FAIL> | owners before/after = <n>/<n>; generator codes: <counts> |
| 2 LB spread | <...> | Grafana "customers-service RPS per pod": 5 series |
| 3 Log↔trace | <...> | trace <id> contains app + waypoint + ingress spans |
| 4 Authz/mTLS | <...> | 403 / 403 / plaintext refused |
| 5 Health tool | <...> | 5 5 |
| 6 Probe + scenarios | <...> | see table below |
| 7 Secrets | <...> | old password rejected; 0 KV passwords |

### Observed RCA scenario symptoms

| Scenario | Codes | Duration | response_flags | attempts |
|---|---|---|---|---|
| customers_slow_query | <...> | <...> | <...> | <...> |
| customers_downstream_error | <...> | <...> | <...> | <...> |
| visits_redis_timeout | <...> | <...> | <...> | <...> |
```
Every `<...>` is filled with the observed value — this table is the deliverable of Steps 1–3.

- [ ] **Step 5: Update the lab README (current state)**

In `k3s/apps/lab-environment/README.md`:
- Intro/"Runs always-on" section: replicas (customers ×5, api-gateway ×3), RollingUpdate + PDBs, Istio ambient with waypoint (2 replicas) and ingress gateway (2 replicas), per-workload ServiceAccounts, STRICT mTLS for business + data pods, authz summary table (copy from spec §4), resident resilience values.
- New section "Service discovery and config": K8s Service DNS + mesh; Consul = config center + chaos toggles only; DB password from `lab-db-credentials` SealedSecret (rotate: reseal + `ALTER USER` + rollout, see Task 3 of the plan).
- New section "Schema": `db-init` PreSync Job, idempotent, test with `tests/test-db-init.sh`; services run `SPRING_SQL_INIT_MODE=never`.
- "After bringing it up: seed Consul KV" — note `db.password` is no longer seeded.
- NodePorts table: `30097` → `lab-ingress-istio` (was api-gateway directly); api-gateway is ClusterIP.
- "Images": SHA tags, `scripts/build.sh` + `scripts/push-to-k3s.sh`; never `:dev` in manifests.
- New section "Evidence": Jaeger (app + Envoy spans, OTLP), Loki JSON access logs with trace_id links, dashboard `Lab Mesh Overview`, traffic generator.
- New section "Rollback": per-stage table from the spec.
Also update the ResourceQuota comment if the README quotes quota numbers.

- [ ] **Step 6: Commit, confirm, merge; clean up worktree**

```bash
git add docs/superpowers/specs/2026-09-25-lab-mesh-production-baseline-design.md k3s/apps/lab-environment/README.md
git commit -m "docs(lab-environment): record baseline acceptance results and current state

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
After confirmation merge to `main`. Then `git -C /home/ubuntu/jerome/docker-gitops worktree remove ../docker-gitops-lab-mesh` (no compose stack ever ran in it, so no bind-mount risk) and `git branch -d lab-mesh-baseline`.
