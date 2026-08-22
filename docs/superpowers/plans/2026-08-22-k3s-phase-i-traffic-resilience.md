# K3s Phase I — Traffic Resilience Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give `hello-backend` in `pr-lanes` canary weight routing, request timeouts, retries, outlier detection (circuit breaking), and header-triggered fault injection — entirely via new/edited Istio and Gateway API CRD YAML, zero new infrastructure components beyond one extra `hello-backend` variant Deployment.

**Architecture:** A real `hello-backend-canary` Deployment/Service (same pinned image, ConfigMap-overridden `index.html`) becomes the second weighted target. `backend-httproute.yaml` (Gateway API, already live) gets `backendRefs[].weight` (90/10) and `timeouts`. A new `VirtualService` (classic Istio API — Gateway API has no retry field) carries `retries` on the default route and header-triggered `fault` injection on two dedicated header values, and **duplicates** the 90/10 weight + 10s timeout on its own default route as a hedge, since whether Istio's dataplane treats the Gateway API `HTTPRoute` or the classic `VirtualService` as authoritative for the same host is not confirmed by upstream docs and has to be verified empirically against this cluster (Task 3). Two `DestinationRule`s (one per host) add outlier detection.

**Tech Stack:** Gateway API `v1` (standard channel, already installed — confirmed live: `v1.6.1`), Istio `networking.istio.io/v1` `VirtualService`/`DestinationRule` (istiod `1.30.3`, already installed), ArgoCD (existing `hello` Application, `path: vps_oracle/k3s/apps/hello/k8s`, automated prune+selfHeal — new files under this path sync automatically), Kyverno (existing policies, confirmed live to already cover this without changes — see Global Constraints).

**Spec:** [docs/superpowers/specs/2026-08-22-k3s-phase-i-traffic-resilience-design.md](../specs/2026-08-22-k3s-phase-i-traffic-resilience-design.md)

**Depends on:** Phase F+G (Istio Ambient + Gateway API in `pr-lanes`, complete). Independent of any other in-flight work — this plan only creates new files or edits `backend-httproute.yaml`, nothing else in the repo.

## Global Constraints

- **Retry has no Gateway API field.** Confirmed live: `kubectl explain httproute.spec.rules.retry` → `error: field "retry" does not exist` against the installed `v1.6.1` CRDs. Retries in this plan are `VirtualService.http[].retries` only — this supersedes the spec's "verify then decide" framing; the answer is now known.
- **Two mechanisms will independently claim the same routing decision for default (non-header) traffic on `hello-backend`:** the Gateway API `HTTPRoute` (weight + timeout) and the new `VirtualService` (retries + duplicated weight + duplicated timeout). Task 3 verifies both stay consistent; until proven safe, every task that edits the weight ratio or the timeout value must edit it in **both** places, or the two configs will silently disagree.
- **`pr-lanes-quota` hard caps:** `limits.cpu: 1200m`, `limits.memory: 1536Mi` (confirmed live, `kubectl -n pr-lanes describe resourcequota pr-lanes-quota`, 2026-08-22). Used before this plan: `limits.cpu: 400m`, `limits.memory: 512Mi` (waypoint 200m/256Mi + hello-frontend 100m/128Mi + hello-backend baseline 100m/128Mi). Task 1 adds `hello-backend-canary` at the same `lane/deployment.yaml` sizing (`limits: 100m/128Mi`), bringing the total to `500m/640Mi` — leaves `700m/896Mi` for PR lanes, i.e. **7 concurrent lanes instead of 8** (each lane is `100m/128Mi`). This is the spec's accepted tradeoff, not a new discovery.
- **Only `vps_oracle/k3s/apps/hello/k8s/` is touched.** Nothing in `vps_oracle/k3s/apps/hello/lane/` or `vps_oracle/k3s/argocd/apps/pr-lanes-appset.yaml` changes in this plan.
- **Canary reuses the exact baseline image digest** — `ghcr.io/jeromefromcn/hello-backend@sha256:8b3dc653ce946c66d60844cc168cf2a155f3384ed4b6fd9f602b87f1f88b374f` (copied verbatim from `backend-deployment.yaml`, not retyped). Confirmed live against both Kyverno policies that could apply in `pr-lanes`: `restricted-self-built` matches Pods by label `app in [hello-frontend, hello-backend]` (my canary Pods carry `app: hello-backend`, so it's already in scope and already passes because the securityContext is copied from baseline unchanged); `restrict-image-registry-pr-lanes` matches any Pod in the `pr-lanes` namespace by image reference (`ghcr.io/jeromefromcn/*`), not by workload name, and the baseline digest is already signed from a `main`-branch build. **No Kyverno policy edits are needed anywhere in this plan.**
- **`maxEjectionPercent: 100`, not the spec's illustrative `50`.** Both `hello-backend` and `hello-backend-canary` run `replicas: 1`. Envoy's `max_ejection_percent` caps how much of a cluster's endpoints can be ejected; at 50% with a 1-endpoint cluster, the single endpoint may never be ejectable at all, silently defeating the feature. 100% removes that risk for these single-replica demo services. Revisit if either backend ever runs more than 1 replica.
- **Repo path convention:** every new file lives in `vps_oracle/k3s/apps/hello/k8s/`, following the existing `backend-*`/`frontend-*` naming (`backend-canary-*`, `backend-virtualservice.yaml`, `backend-destinationrule.yaml`, `backend-canary-destinationrule.yaml`). The `hello` ArgoCD `Application` already points at this directory with no `kustomization.yaml` gate — new files sync automatically on the next push to `main`.
- **Git workflow:** commit and push to `main`, then verify against the live cluster (`hello` Application has `syncPolicy.automated: {prune: true, selfHeal: true}` — no manual `kubectl apply` per repo/CLAUDE.md convention). This checkout has had concurrent-session activity before (branch switches, commits from another process) — run `git status` and `git log --oneline -3` before every commit in this plan to confirm you're still starting from a clean, expected state.
- **Read-only `kubectl`/`istioctl` diagnostics are always fine** at any point — only mutating the live cluster outside of `git push` → ArgoCD sync is restricted.

---

### Task 1: `hello-backend-canary` (ConfigMap + Deployment + Service)

**Files:**
- Create: `vps_oracle/k3s/apps/hello/k8s/backend-canary-configmap.yaml`
- Create: `vps_oracle/k3s/apps/hello/k8s/backend-canary-deployment.yaml`
- Create: `vps_oracle/k3s/apps/hello/k8s/backend-canary-service.yaml`

**Interfaces:**
- Consumes: nothing from another task in this plan.
- Produces: a `hello-backend-canary` Service reachable at `hello-backend-canary.pr-lanes.svc.cluster.local:80`, selecting Pods labeled `app: hello-backend, lane: canary`. Task 2 (HTTPRoute), Task 3 (VirtualService), and Task 4 (DestinationRule) all reference this exact Service name/host.

- [ ] **Step 1: Confirm current state before touching anything**

```bash
kubectl -n pr-lanes get pods,svc
kubectl -n pr-lanes describe resourcequota pr-lanes-quota
git status
git log --oneline -3
```

Expected: 3 pods (`hello-backend`, `hello-frontend`, `waypoint`), 3 Services (`hello-backend`, `hello-frontend`, `waypoint`); quota used `limits.cpu: 400m`, `limits.memory: 512Mi` — matches the Global Constraints baseline. `git status` clean (or only this plan's own untracked files); note the current `git log` head so you can tell later if another session has committed here meanwhile.

- [ ] **Step 2: Write the ConfigMap**

```yaml
# vps_oracle/k3s/apps/hello/k8s/backend-canary-configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: hello-backend-canary-conf
  namespace: pr-lanes
# NOTE: hello-backend-canary mounts index.html via subPath, which kubelet never
# hot-reloads. If you edit data["index.html"] below, you MUST also recompute the
# `configmap-checksum` annotation in backend-canary-deployment.yaml (sha256 of
# this content, same convention as frontend-configmap.yaml) so the pod template
# actually changes and a rollout happens — otherwise running pods keep serving
# stale content.
data:
  index.html: |
    <!DOCTYPE html>
    <html>
    <head><title>hello-backend</title></head>
    <body><h1>hello-backend (canary)</h1></body>
    </html>
```

- [ ] **Step 3: Compute the checksum and verify it matches this plan's precomputed value**

```bash
printf '%s\n' '<!DOCTYPE html>' '<html>' '<head><title>hello-backend</title></head>' \
  '<body><h1>hello-backend (canary)</h1></body>' '</html>' | sha256sum
```

Expected: `298934fedba8a579276041523ff72986b769872fa3cb89e25cdcd5a69ac552e8` — this is the exact value Step 4's Deployment annotation uses. If your `index.html` block in Step 2 differs from the one above in any whitespace, this hash will differ too — recompute and use your own value instead of the plan's.

- [ ] **Step 4: Write the Deployment**

```yaml
# vps_oracle/k3s/apps/hello/k8s/backend-canary-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello-backend-canary
  namespace: pr-lanes
  labels:
    app: hello-backend
    lane: canary
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: hello-backend
      lane: canary
  template:
    metadata:
      labels:
        app: hello-backend
        lane: canary
      annotations:
        # sha256 of backend-canary-configmap.yaml's data["index.html"] content
        # (as rendered, not the raw YAML block) — see that file's own note and
        # frontend-deployment.yaml for the full explanation of why this exists.
        configmap-checksum: "298934fedba8a579276041523ff72986b769872fa3cb89e25cdcd5a69ac552e8"
    spec:
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: hello-backend
          # Same pinned digest as baseline (backend-deployment.yaml) — canary is
          # a content variant for testing weight routing, not a different build.
          image: ghcr.io/jeromefromcn/hello-backend@sha256:8b3dc653ce946c66d60844cc168cf2a155f3384ed4b6fd9f602b87f1f88b374f
          env:
            - name: TZ
              value: "Asia/Hong_Kong"
          ports:
            - containerPort: 8080
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
          livenessProbe:
            httpGet:
              path: /
              port: 8080
            initialDelaySeconds: 3
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /
              port: 8080
            initialDelaySeconds: 3
            periodSeconds: 10
          resources:
            requests:
              cpu: 25m
              memory: 64Mi
            limits:
              cpu: 100m
              memory: 128Mi
          volumeMounts:
            - name: index-html
              mountPath: /usr/share/nginx/html/index.html
              subPath: index.html
      volumes:
        - name: index-html
          configMap:
            name: hello-backend-canary-conf
```

- [ ] **Step 5: Write the Service**

```yaml
# vps_oracle/k3s/apps/hello/k8s/backend-canary-service.yaml
apiVersion: v1
kind: Service
metadata:
  name: hello-backend-canary
  namespace: pr-lanes
  labels:
    app: hello-backend
    lane: canary
    istio.io/use-waypoint: waypoint
spec:
  selector:
    app: hello-backend
    lane: canary
  ports:
    - port: 80
      targetPort: 8080
```

- [ ] **Step 6: Validate YAML and commit**

```bash
python3 -c "
import yaml
for f in ['vps_oracle/k3s/apps/hello/k8s/backend-canary-configmap.yaml',
          'vps_oracle/k3s/apps/hello/k8s/backend-canary-deployment.yaml',
          'vps_oracle/k3s/apps/hello/k8s/backend-canary-service.yaml']:
    yaml.safe_load(open(f))
" && echo OK
git add vps_oracle/k3s/apps/hello/k8s/backend-canary-configmap.yaml \
  vps_oracle/k3s/apps/hello/k8s/backend-canary-deployment.yaml \
  vps_oracle/k3s/apps/hello/k8s/backend-canary-service.yaml
git commit -m "Add hello-backend-canary as a real second version for weight routing

Same pinned digest as baseline, content-differentiated via a mounted
ConfigMap (phase I traffic resilience design, decided against a subset-
based canary since Gateway API weight routing splits across Services,
not subsets)."
git push
```

- [ ] **Step 7: Verify the pod runs and is reachable**

```bash
kubectl -n pr-lanes get pods -l app=hello-backend,lane=canary
kubectl -n pr-lanes get svc hello-backend-canary
kubectl -n pr-lanes run curl-canary-check --rm -i --restart=Never --image=curlimages/curl:8.11.1 -- \
  curl -s http://hello-backend-canary.pr-lanes.svc.cluster.local/
```

Expected: one pod `Running`; Service has a `ClusterIP`; the `curl` output contains `hello-backend (canary)`.

- [ ] **Step 8: Confirm Kyverno admission actually ran (not silently skipped) and quota moved as predicted**

```bash
kubectl -n kyverno logs -l app.kubernetes.io/component=admission-controller --tail=80 | grep hello-backend-canary
kubectl -n pr-lanes describe resourcequota pr-lanes-quota
```

Expected: at least one admission review log line referencing the new pod (proves both Kyverno policies from Global Constraints evaluated it, and passed, since it's `Running`). Quota now shows `limits.cpu: 500m`, `limits.memory: 640Mi` — matches Global Constraints exactly.

---

### Task 2: `HTTPRoute` weight split and timeouts

**Files:**
- Modify: `vps_oracle/k3s/apps/hello/k8s/backend-httproute.yaml`

**Interfaces:**
- Consumes: `hello-backend-canary` Service (Task 1).
- Produces: the Gateway API side of the 90/10 split and the 10s/8s timeout — Task 3's `VirtualService` duplicates these same two numbers, so if either changes here, it must change there too (Global Constraints).

- [ ] **Step 1: Confirm the current live HTTPRoute before editing**

```bash
kubectl -n pr-lanes get httproute hello-backend-baseline -o yaml
```

Expected: single rule, single `backendRefs` entry (`hello-backend`, `port: 80`), no `timeouts`. This is the object you're about to change — compare after Step 4 to confirm the diff took effect.

- [ ] **Step 2: Edit the file**

```yaml
# vps_oracle/k3s/apps/hello/k8s/backend-httproute.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: hello-backend-baseline
  namespace: pr-lanes
spec:
  parentRefs:
    - group: ""
      kind: Service
      name: hello-backend
  rules:
    - timeouts:
        request: 10s
        backendRequest: 8s
      backendRefs:
        - name: hello-backend
          port: 80
          weight: 90
        - name: hello-backend-canary
          port: 80
          weight: 10
```

Don't add a `matches` block — Gateway API defaults an unspecified `matches` to a PathPrefix `/` match (confirmed live: the currently-deployed object already shows this default materialized), and every per-PR-lane `HTTPRoute` header-matches on the same parent, which by Gateway API's own match-specificity rules always outranks this path-only catchall regardless of its `backendRefs`/`weight` content — the header routing you're not touching stays unaffected by this edit for that reason, not by luck.

- [ ] **Step 3: Validate YAML and commit**

```bash
python3 -c "import yaml; yaml.safe_load(open('vps_oracle/k3s/apps/hello/k8s/backend-httproute.yaml'))" && echo OK
git add vps_oracle/k3s/apps/hello/k8s/backend-httproute.yaml
git commit -m "Weight-split hello-backend traffic 90/10 to canary, add request timeouts

Gateway API backendRefs[].weight — the standard multi-backend canary
pattern for Gateway API, distinct from Istio's subset-based approach.
timeouts.request/backendRequest are Extended-support fields, confirmed
present in the installed v1.6.1 standard channel CRDs."
git push
```

- [ ] **Step 4: Verify the HTTPRoute updated and the ratio holds**

```bash
kubectl -n pr-lanes get httproute hello-backend-baseline -o yaml
kubectl -n pr-lanes run curl-weight-check --rm -i --restart=Never --image=curlimages/curl:8.11.1 -- \
  sh -c 'for i in $(seq 1 50); do curl -s http://hello-backend.pr-lanes.svc.cluster.local/; echo; done' \
  > /tmp/weight-check.txt 2>&1; grep -c canary /tmp/weight-check.txt; wc -l < /tmp/weight-check.txt
```

Expected: the `get httproute` output shows both `backendRefs` with their weights and the `timeouts` block; roughly 5 out of 50 responses (±3, this is a statistical sample, not exact) contain `canary`, the rest `baseline`.

- [ ] **Step 5: Opportunistic PR-lane regression check**

```bash
kubectl -n argocd get application -l argocd.argoproj.io/application-set-name=pr-lanes
```

If this lists any `hello-pr-<N>` Application, pick one and confirm its header-matched request still returns that lane's own content unaffected by the new weight:

```bash
kubectl -n pr-lanes run curl-lane-check --rm -i --restart=Never --image=curlimages/curl:8.11.1 -- \
  curl -s -H "x-pr-lane: <N>" http://hello-backend.pr-lanes.svc.cluster.local/
```

If the list is empty (no PR currently open), skip this step — there's nothing to regress against, and this plan doesn't create a test PR (out of scope, see spec).

---

### Task 3: `VirtualService` — fault injection and retries

**Files:**
- Create: `vps_oracle/k3s/apps/hello/k8s/backend-virtualservice.yaml`

**Interfaces:**
- Consumes: `hello-backend`/`hello-backend-canary` Services (Task 1), the 90/10 + 10s timeout values from Task 2 (duplicated here, see Global Constraints).
- Produces: the header-triggered fault paths (`x-fault-test: delay` / `x-fault-test: abort`) that Task 4 uses to attempt to trigger outlier detection ejection.

This refines the spec's sketch (a single header value triggering both delay and abort together) into **two separate header values**, because Envoy applies `fault.delay` before `fault.abort` when both are set on the same rule — combined with this route's own `timeout: 10s`, a combined delay+abort rule would always hit the timeout before the abort ever fired, making the abort untestable. Splitting them lets each be verified independently.

- [ ] **Step 1: Write the VirtualService**

```yaml
# vps_oracle/k3s/apps/hello/k8s/backend-virtualservice.yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: hello-backend
  namespace: pr-lanes
spec:
  hosts:
    - hello-backend.pr-lanes.svc.cluster.local
  http:
    # Header-triggered only — see Task 3's own testing steps for why delay
    # and abort are split into separate header values instead of one.
    - match:
        - headers:
            x-fault-test:
              exact: "delay"
      fault:
        delay:
          percentage:
            value: 100
          fixedDelay: 15s
      route:
        - destination:
            host: hello-backend.pr-lanes.svc.cluster.local
      timeout: 10s
    - match:
        - headers:
            x-fault-test:
              exact: "abort"
      fault:
        abort:
          percentage:
            value: 100
          httpStatus: 500
      route:
        - destination:
            host: hello-backend.pr-lanes.svc.cluster.local
    # Default route — no x-fault-test header. Weight and timeout here MUST
    # match backend-httproute.yaml's values exactly (currently 90/10, 10s):
    # see Global Constraints for why this is duplicated rather than deferred
    # to whichever of HTTPRoute/VirtualService the dataplane treats as
    # authoritative for this host.
    - route:
        - destination:
            host: hello-backend.pr-lanes.svc.cluster.local
          weight: 90
        - destination:
            host: hello-backend-canary.pr-lanes.svc.cluster.local
          weight: 10
      retries:
        attempts: 2
        perTryTimeout: 2s
        retryOn: 5xx,reset,connect-failure
      timeout: 10s
```

- [ ] **Step 2: Validate YAML and commit**

```bash
python3 -c "import yaml; yaml.safe_load(open('vps_oracle/k3s/apps/hello/k8s/backend-virtualservice.yaml'))" && echo OK
git add vps_oracle/k3s/apps/hello/k8s/backend-virtualservice.yaml
git commit -m "Add header-triggered fault injection and retries for hello-backend

Retries have no Gateway API HTTPRoute field (confirmed against the
installed v1.6.1 CRDs) — VirtualService is the only mechanism. Delay and
abort are split into separate x-fault-test header values (delay/abort)
rather than combined, so each is independently observable despite the
route's own 10s timeout. Default route duplicates HTTPRoute's 90/10
weight and 10s timeout as a hedge — see Task 3 verification for whether
that hedge turns out to be load-bearing on this cluster."
git push
```

- [ ] **Step 3: Verify normal traffic is unaffected and the weight ratio still holds with the VirtualService now also in place**

```bash
kubectl -n pr-lanes run curl-weight-recheck --rm -i --restart=Never --image=curlimages/curl:8.11.1 -- \
  sh -c 'for i in $(seq 1 50); do curl -s http://hello-backend.pr-lanes.svc.cluster.local/; echo; done' \
  > /tmp/weight-recheck.txt 2>&1; grep -c canary /tmp/weight-recheck.txt
```

Expected: still roughly 5 out of 50 — same as Task 2 Step 4. This is the plan's central coexistence check (spec's known-limitation item): whichever of `HTTPRoute`/`VirtualService` the dataplane actually honors for default traffic, the ratio holds either way because both configs agree. If this ratio comes back wildly different (e.g. ~50/50, or 0/100), the two configs are in conflict rather than agreement despite matching numbers — stop and investigate with `istioctl proxy-config route deploy/waypoint -n pr-lanes -o json` before continuing to Task 4.

- [ ] **Step 4: Verify the delay path is cut off by the timeout, not by the fault delay completing**

```bash
kubectl -n pr-lanes run curl-delay-check --rm -i --restart=Never --image=curlimages/curl:8.11.1 -- \
  curl -s -o /dev/null -w '%{http_code} %{time_total}\n' -H "x-fault-test: delay" \
  http://hello-backend.pr-lanes.svc.cluster.local/
```

Expected: total time close to 10s (the timeout), not 15s (the configured delay), and an HTTP status indicating a timeout/gateway error (`504` is typical for Envoy request timeouts), not `200`. This proves `timeout: 10s` is actually enforced on this route, from whichever of the two configs is providing it.

- [ ] **Step 5: Verify the abort path returns the configured error, cleanly and immediately**

```bash
kubectl -n pr-lanes run curl-abort-check --rm -i --restart=Never --image=curlimages/curl:8.11.1 -- \
  curl -s -o /dev/null -w '%{http_code} %{time_total}\n' -H "x-fault-test: abort" \
  http://hello-backend.pr-lanes.svc.cluster.local/
```

Expected: `500`, total time well under 1s (no delay configured on this path).

- [ ] **Step 6: Confirm normal traffic (no `x-fault-test` header) is completely unaffected**

```bash
kubectl -n pr-lanes run curl-normal-check --rm -i --restart=Never --image=curlimages/curl:8.11.1 -- \
  curl -s -o /dev/null -w '%{http_code} %{time_total}\n' http://hello-backend.pr-lanes.svc.cluster.local/
```

Expected: `200`, total time well under 1s — proves the two fault-test header rules only match when the header is actually present.

---

### Task 4: `DestinationRule` outlier detection

**Files:**
- Create: `vps_oracle/k3s/apps/hello/k8s/backend-destinationrule.yaml`
- Create: `vps_oracle/k3s/apps/hello/k8s/backend-canary-destinationrule.yaml`

**Interfaces:**
- Consumes: `hello-backend`/`hello-backend-canary` Services (Task 1), the `x-fault-test: abort` path (Task 3) as a best-effort ejection trigger.
- Produces: nothing further tasks in this plan depend on — this is the plan's last capability, Task 5 is verification-only.

- [ ] **Step 1: Write both DestinationRules**

```yaml
# vps_oracle/k3s/apps/hello/k8s/backend-destinationrule.yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: hello-backend
  namespace: pr-lanes
spec:
  host: hello-backend.pr-lanes.svc.cluster.local
  trafficPolicy:
    outlierDetection:
      consecutive5xxErrors: 3
      interval: 30s
      baseEjectionTime: 30s
      # 100, not the more typical 50 — see Global Constraints: replicas: 1
      # means 50% would round down to zero ejectable endpoints and silently
      # disable this feature entirely for a single-replica demo service.
      maxEjectionPercent: 100
```

```yaml
# vps_oracle/k3s/apps/hello/k8s/backend-canary-destinationrule.yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: hello-backend-canary
  namespace: pr-lanes
spec:
  host: hello-backend-canary.pr-lanes.svc.cluster.local
  trafficPolicy:
    outlierDetection:
      consecutive5xxErrors: 3
      interval: 30s
      baseEjectionTime: 30s
      maxEjectionPercent: 100
```

Not shared/combined into one file: `host` is a required, single-value field — `hello-backend` and `hello-backend-canary` are two distinct Service hosts, so this is mechanically two separate resources, not a stylistic choice (see spec's resolution of the "share a DestinationRule?" open question).

- [ ] **Step 2: Validate YAML and commit**

```bash
python3 -c "
import yaml
yaml.safe_load(open('vps_oracle/k3s/apps/hello/k8s/backend-destinationrule.yaml'))
yaml.safe_load(open('vps_oracle/k3s/apps/hello/k8s/backend-canary-destinationrule.yaml'))
" && echo OK
git add vps_oracle/k3s/apps/hello/k8s/backend-destinationrule.yaml \
  vps_oracle/k3s/apps/hello/k8s/backend-canary-destinationrule.yaml
git commit -m "Add outlier detection (circuit breaking) for hello-backend and its canary

One DestinationRule per host — DestinationRule.host is single-valued so
this can't be combined into one resource. maxEjectionPercent: 100 (not
the usual 50) because both backends run replicas: 1, where a 50% cap
would round down to zero ejectable endpoints."
git push
```

- [ ] **Step 3: Confirm the config reached the Envoy dataplane (reliable regardless of whether ejection can be behaviorally observed below)**

```bash
kubectl -n pr-lanes get destinationrule -o wide
istioctl proxy-config cluster deploy/waypoint -n pr-lanes --fqdn hello-backend.pr-lanes.svc.cluster.local -o json | grep -i outlier
istioctl proxy-config cluster deploy/waypoint -n pr-lanes --fqdn hello-backend-canary.pr-lanes.svc.cluster.local -o json | grep -i outlier
```

Expected: both `DestinationRule` objects listed; both `istioctl` calls show non-empty output referencing outlier detection (the cluster config carries the policy, not just the k8s API object).

- [ ] **Step 4: Best-effort behavioral check — attempt to trigger ejection with the fault-injection abort path**

```bash
kubectl -n pr-lanes run curl-ejection-attempt --rm -i --restart=Never --image=curlimages/curl:8.11.1 -- \
  sh -c 'for i in $(seq 1 6); do curl -s -o /dev/null -w "%{http_code}\n" -H "x-fault-test: abort" http://hello-backend.pr-lanes.svc.cluster.local/; sleep 1; done'
istioctl proxy-config cluster deploy/waypoint -n pr-lanes --fqdn hello-backend.pr-lanes.svc.cluster.local -o json | grep -i -A3 "outlier\|ejected"
```

This may or may not actually demonstrate ejection: Envoy's fault-injection `abort` returns a local reply before the request reaches the upstream cluster, which means it may never be attributed to `hello-backend`'s own upstream-failure accounting the way outlier detection needs. If the second command shows an ejection count/timestamp, the abort path does count — note this finding in Task 5. If it doesn't, that's not a plan failure — it just means this demo app's only reliable way to prove ejection behaviorally would require the app itself to return a real 5xx, which is out of scope (this phase is CRD-only, no app changes). Either way, Step 3 already proves the configuration itself is correct and live.

- [ ] **Step 5: Confirm no regression — plain traffic and canary ratio still work after all fault-testing**

```bash
kubectl -n pr-lanes run curl-final-sanity --rm -i --restart=Never --image=curlimages/curl:8.11.1 -- \
  curl -s -o /dev/null -w '%{http_code}\n' http://hello-backend.pr-lanes.svc.cluster.local/
kubectl -n pr-lanes get pods -l app=hello-backend
```

Expected: `200`; both `hello-backend` and `hello-backend-canary` pods `Running` (the abort-testing traffic never reached either pod, so neither should show elevated restarts or non-Ready status).

---

### Task 5: End-to-end verification and cleanup

**Files:** none — verification only.

**Interfaces:**
- Consumes: everything from Tasks 1-4.
- Produces: nothing — this is the plan's final gate.

- [ ] **Step 1: Full resource quota check**

```bash
kubectl -n pr-lanes describe resourcequota pr-lanes-quota
```

Expected: `limits.cpu: 500m / 1200m`, `limits.memory: 640Mi / 1536Mi` — matches Global Constraints, nowhere near the hard cap.

- [ ] **Step 2: Full cluster-wide regression check — nothing outside this plan's scope was disturbed**

```bash
kubectl get pods -A -o wide | grep -v Running
kubectl get applications -n argocd -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status | grep -v "Synced.*Healthy"
```

Expected: both empty. This is the plan's final gate, same as the FG plan's own closing check — do not consider phase I done until every pod cluster-wide is `Running` and every `Application` is `Synced`/`Healthy`.

- [ ] **Step 3: Re-run the canary ratio and fault-injection checks one more time as a final combined smoke test**

```bash
kubectl -n pr-lanes run curl-smoke-test --rm -i --restart=Never --image=curlimages/curl:8.11.1 -- sh -c '
echo "--- normal traffic ratio ---"
for i in $(seq 1 30); do curl -s http://hello-backend.pr-lanes.svc.cluster.local/; echo; done | grep -c canary
echo "--- delay path (expect ~10s cutoff) ---"
curl -s -o /dev/null -w "%{http_code} %{time_total}\n" -H "x-fault-test: delay" http://hello-backend.pr-lanes.svc.cluster.local/
echo "--- abort path (expect 500, fast) ---"
curl -s -o /dev/null -w "%{http_code} %{time_total}\n" -H "x-fault-test: abort" http://hello-backend.pr-lanes.svc.cluster.local/
'
```

Expected: roughly 3/30 canary; delay path ~10s with a timeout status; abort path `500` in well under 1s.

- [ ] **Step 4: Record the Task 4 Step 4 finding back into the design doc**

Open [docs/superpowers/specs/2026-08-22-k3s-phase-i-traffic-resilience-design.md](../specs/2026-08-22-k3s-phase-i-traffic-resilience-design.md)'s "已知限制 / 失敗模式" section and add one line recording whether fault-injection abort actually triggered an observable outlier-detection ejection (Task 4 Step 4's finding) — the spec currently leaves this open, and this plan is what resolves it.

```bash
git add docs/superpowers/specs/2026-08-22-k3s-phase-i-traffic-resilience-design.md
git commit -m "Record Phase I implementation findings in the design doc

Closes the open question in the 已知限制 section about whether fault-
injection abort can trigger outlier detection ejection in practice."
git push
```

- [ ] **Step 5: Final check — confirm this plan's file list matches what actually landed**

```bash
git log --oneline --stat -5 -- vps_oracle/k3s/apps/hello/k8s/
```

Expected: 4 commits (Task 1, 2, 3, 4), touching exactly: `backend-canary-configmap.yaml`, `backend-canary-deployment.yaml`, `backend-canary-service.yaml`, `backend-httproute.yaml` (modified), `backend-virtualservice.yaml`, `backend-destinationrule.yaml`, `backend-canary-destinationrule.yaml`. No other file under `vps_oracle/k3s/apps/hello/` touched — confirms the plan stayed inside its stated scope (no `lane/` or `pr-lanes-appset.yaml` changes).

---

## Self-Review Notes

- **Spec coverage:** every item in the design doc's 驗證清單 maps to a step above — items 1-3 (canary ratio, PR-lane non-interference) are Task 2 Steps 4-5, re-verified in Task 3 Step 3 once the VirtualService coexists; item 4 (timeout) is Task 3 Step 4; item 5 (retry) is structurally covered by Task 3 (VirtualService is the only mechanism, confirmed live) — this plan does not attempt a full behavioral retry proof beyond the config existing, since forcing a real mid-request failure against a 1-replica backend without disturbing the demo isn't reliably achievable, and the plan says so rather than writing a step that looks like it proves something it doesn't; items 6-7 (outlier detection ejection/recovery) are Task 4 Steps 3-4, honestly framed as structural-verification-guaranteed / behavioral-verification-best-effort; items 8-9 (fault injection) are Task 3 Steps 4-6; item 10 (HTTPRoute/VirtualService coexistence) is Task 3 Step 3, the plan's central check; items 11-12 (resource quota, full regression) are Task 5 Steps 1-2.
- **Placeholder scan:** no TBD/TODO. The one open-ended item (Task 4 Step 4's "may or may not demonstrate ejection") is not a placeholder — it's an honestly-flagged empirical uncertainty with a concrete command to resolve it and an explicit instruction for what to do with either outcome, closed out by Task 5 Step 4.
- **Type/name consistency:** `hello-backend-canary` (Service/Deployment/host) is spelled identically across Tasks 1, 2, 3, 4. The 90/10 weight and 10s/8s timeout values match between Task 2's `HTTPRoute` and Task 3's `VirtualService` default route exactly — this pairing is this plan's single most failure-prone point if it's ever revisited (same risk class as the FG plan's lane-name-patches pairing), flagged explicitly in Global Constraints. `maxEjectionPercent: 100` is consistent across both Task 4 DestinationRules.
