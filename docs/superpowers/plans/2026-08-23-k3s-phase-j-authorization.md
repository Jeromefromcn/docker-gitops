# K3s Phase J — Fine-Grained Authorization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restrict east-west calls to `hello-backend` (baseline, canary, and every PR lane) so only `hello-frontend` can reach them — enforced by Istio ambient at the mTLS identity layer, not by editing any of Phase I's routing resources.

**Architecture:** Two new `ServiceAccount`s (`hello-frontend-sa`, `hello-backend-sa`) replace the shared `default` identity all `hello-*` workloads currently use. Two `AuthorizationPolicy` resources then do the actual enforcement, because a single selector-based policy would silently break PR lanes (see Global Constraints): **Policy 1** attaches via `targetRefs` to the `waypoint` Gateway itself and allows only `hello-frontend-sa` — evaluated with the caller's true identity, since the waypoint is the first mesh enforcement point a request hits. **Policy 2** attaches via `selector` to every `app: hello-backend` pod and allows only the `waypoint` ServiceAccount's own identity — this closes the path where a caller reaches a backend pod without going through the waypoint at all (the only path that exists for PR-lane backends, since their Service has no `istio.io/use-waypoint` label).

**Tech Stack:** Istio `security.istio.io/v1` `AuthorizationPolicy` (istiod `1.30.3`, confirmed live), Gateway API `v1` (`targetRefs` referencing the existing `waypoint` `Gateway` resource), ArgoCD (existing `hello` Application, `path: vps_oracle/k3s/apps/hello/k8s`, automated prune+selfHeal), Kyverno (existing policies, confirmed live to only match `kind: Pod` — untouched by this plan's `ServiceAccount`/`AuthorizationPolicy` resources).

**Spec:** [docs/superpowers/specs/2026-08-23-k3s-phase-j-authorization-design.md](../specs/2026-08-23-k3s-phase-j-authorization-design.md)

**Depends on:** Phase I (complete, merged to main). Independent of any other in-flight work — this plan only creates new files and adds one `serviceAccountName` field to four existing Deployments.

## Global Constraints

- **A single selector-based `AuthorizationPolicy` would break PR lanes — confirmed against official Istio docs, not a guess.** When a waypoint forwards traffic to a downstream Service that has no `istio.io/use-waypoint` label (true of `hello-backend-pr-N`), the destination pod's own ztunnel sees the *waypoint's* identity, not the original caller's. This is why the plan has two policies, not one — see the spec's "已知限制" section and [istio.io](https://istio.io/latest/docs/tasks/security/authorization/authz-waypoint/) / [ambientmesh.io](https://ambientmesh.io/docs/security/ztunnel-authz/).
- **`hello-backend`/`hello-backend-canary` Services already carry `istio.io/use-waypoint: waypoint`; their Service hostname is therefore not a bypass path** — ztunnel redirects any caller hitting that hostname through the waypoint regardless of source pod. A genuine Policy 2 bypass test against these two must target the **pod IP** directly, not the Service. `hello-backend-pr-N`'s Service carries no such label, so its Service hostname alone is already a valid bypass path — no pod-IP trick needed there.
- **Trust domain is `cluster.local`** (confirmed live: `kubectl -n istio-system get cm istio -o jsonpath='{.data.mesh}' | grep trustDomain`). Every `source.principals` entry in this plan uses the form `cluster.local/ns/pr-lanes/sa/<name>`.
- **The `waypoint` ServiceAccount already exists** (confirmed live: `kubectl -n pr-lanes get sa` shows `default` and `waypoint`, nothing else, before this plan starts). Policy 2 references `cluster.local/ns/pr-lanes/sa/waypoint` — nothing to create for that identity, it's the Istio-managed waypoint Deployment's own SA.
- **No PR lane is currently open** (confirmed live: only `hello-backend`, `hello-backend-canary`, `hello-frontend`, `waypoint` pods exist in `pr-lanes`; no `hello-backend-pr-N`). Every step in this plan that exercises PR-lane-specific behavior is opportunistic — same pattern as Phase I's plan (Task 2 Step 5): run it if a PR happens to be open at execution time, skip with a note if not. This plan does not open a throwaway PR to force the check (out of scope, matches spec).
- **Kyverno policies (`require-vuln-scan-clean`, `restrict-image-registry`, `restrict-image-registry-pr-lanes`, `restricted-self-built`, all `Enforce`, confirmed live) all match only `kind: Pod`** — confirmed by reading every policy file under `vps_oracle/k3s/kyverno/policies/`. `ServiceAccount` and `AuthorizationPolicy` resources are untouched. The four Deployment edits in Task 1 do recreate their pods (`strategy: Recreate`, adding `serviceAccountName` changes the pod template) — Kyverno re-evaluates those recreated pods, but since none of the four policies key off `serviceAccountName`, they pass exactly as before.
- **`pr-lanes-quota` is unaffected**: `ServiceAccount` and `AuthorizationPolicy` are pure control-plane objects, no CPU/memory request. Confirmed live before this plan: `limits.cpu: 500m/1200m`, `limits.memory: 640Mi/1536Mi`, `requests.cpu: 125m/400m`, `requests.memory: 320Mi/768Mi` — Phase I's numbers, unchanged. This plan's own verification re-checks the same numbers hold after every task.
- **Repo path convention:** every new file lives in `vps_oracle/k3s/apps/hello/k8s/`, following the existing `backend-*`/`frontend-*` naming. The `hello` ArgoCD `Application` already points at this directory with no `kustomization.yaml` gate — new files sync automatically on push to `main`. The one file outside that directory is `vps_oracle/k3s/apps/hello/lane/deployment.yaml` (the PR-lane template), edited in place — `lane/kustomization.yaml` already lists it as a resource, no kustomization change needed.
- **`istioctl` is not installed system-wide in this environment.** It was downloaded to a scratchpad path outside the repo for this plan's verification steps: `/tmp/claude-1001/-home-ubuntu-jerome-docker-gitops/bf5cf944-36ce-4e29-b9ed-95e3c9a90592/scratchpad/istio-1.30.3/bin/istioctl` (arm64, version `1.30.3`, matches the live cluster exactly). Every step in this plan that uses `istioctl` assumes this path is on `PATH`, or invokes it by full path. Do not install it inside the repo directory — it must never be committed.
- **Git workflow:** commit and push to `main`, then verify against the live cluster (`hello` Application has `syncPolicy.automated: {prune: true, selfHeal: true}` — no manual `kubectl apply` per repo/CLAUDE.md convention). This checkout has had concurrent-session activity before — run `git status` and `git log --oneline -3` before every commit in this plan to confirm you're still starting from a clean, expected state.
- **Read-only `kubectl`/`istioctl` diagnostics are always fine** at any point — only mutating the live cluster outside of `git push` → ArgoCD sync is restricted. The one documented exception (disable `selfHeal` for genuine live trial-and-error, re-enable after) is **not needed anywhere in this plan** — every mutation here is git-first.
- **Rollout asymmetry is intentional, not an inconsistency to fix:** Policy 2 (Task 2) goes straight to Enforce with no dry-run step; Policy 1 (Task 3→4) goes through a dry-run observation window first. This is because Policy 1's dry-run is natively supported (it's enforced by the waypoint, a full Envoy proxy), while Policy 2's dry-run would require enabling `AMBIENT_ENABLE_DRY_RUN_AUTHORIZATION_POLICY=true` on istiod — a cluster-wide control-plane change out of scope for this plan. See the spec's "上線節奏" section for the full reasoning.

---

### Task 1: ServiceAccounts and wiring them into every `hello-*` Deployment

**Files:**
- Create: `vps_oracle/k3s/apps/hello/k8s/frontend-serviceaccount.yaml`
- Create: `vps_oracle/k3s/apps/hello/k8s/backend-serviceaccount.yaml`
- Modify: `vps_oracle/k3s/apps/hello/k8s/frontend-deployment.yaml`
- Modify: `vps_oracle/k3s/apps/hello/k8s/backend-deployment.yaml`
- Modify: `vps_oracle/k3s/apps/hello/k8s/backend-canary-deployment.yaml`
- Modify: `vps_oracle/k3s/apps/hello/lane/deployment.yaml`

**Interfaces:**
- Consumes: nothing from another task in this plan.
- Produces: `hello-frontend-sa` and `hello-backend-sa` ServiceAccounts, each actually in use by their respective pods. Task 3/4's Policy 1 references `cluster.local/ns/pr-lanes/sa/hello-frontend-sa` by this exact name — if it's spelled differently here, that policy silently matches nothing.

- [ ] **Step 1: Confirm current state before touching anything**

```bash
kubectl -n pr-lanes get sa
kubectl -n pr-lanes get pods -o custom-columns=NAME:.metadata.name,SA:.spec.serviceAccountName
kubectl -n pr-lanes describe resourcequota pr-lanes-quota
git status
git log --oneline -3
```

Expected: `default` and `waypoint` are the only ServiceAccounts. All four app pods (`hello-backend`, `hello-backend-canary`, `hello-frontend`, and the waypoint pod itself) show `SA: default` except the waypoint pod itself which shows `waypoint`. Quota matches Global Constraints (`limits.cpu: 500m`, `limits.memory: 640Mi`). `git status` clean; note the current `git log` head.

- [ ] **Step 2: Write the two ServiceAccounts**

```yaml
# vps_oracle/k3s/apps/hello/k8s/frontend-serviceaccount.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: hello-frontend-sa
  namespace: pr-lanes
```

```yaml
# vps_oracle/k3s/apps/hello/k8s/backend-serviceaccount.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: hello-backend-sa
  namespace: pr-lanes
```

- [ ] **Step 3: Wire `hello-frontend-sa` into `frontend-deployment.yaml`**

```yaml
# vps_oracle/k3s/apps/hello/k8s/frontend-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello-frontend
  namespace: pr-lanes
  labels:
    app: hello-frontend
    lane: baseline
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: hello-frontend
      lane: baseline
  template:
    metadata:
      labels:
        app: hello-frontend
        lane: baseline
      annotations:
        # sha256 of frontend-configmap.yaml's data["default.conf"] content (as
        # rendered, not the raw YAML block). subPath-mounted ConfigMap files are
        # NOT hot-reloaded by kubelet, so a content-only edit to the ConfigMap
        # silently has no effect on running pods until they're recreated.
        # Whoever edits default.conf in frontend-configmap.yaml MUST recompute
        # this hash and update it here too, or the change won't take effect:
        #   kubectl get configmap hello-frontend-conf -n pr-lanes \
        #     -o jsonpath='{.data.default\.conf}' | sha256sum
        configmap-checksum: "e80fd33fbf8ac9f38e059f51634963eb9582a2ad55e459db20c2ca7b6b1e7425"
    spec:
      serviceAccountName: hello-frontend-sa
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: hello-frontend
          image: ghcr.io/jeromefromcn/placeholder-hello@sha256:3b8929d1913203f822539731236bf1127c178729588647703eed7ea15e831992
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
          resources:
            requests:
              cpu: 25m
              memory: 64Mi
            limits:
              cpu: 100m
              memory: 128Mi
          volumeMounts:
            - name: nginx-conf
              mountPath: /etc/nginx/conf.d/default.conf
              subPath: default.conf
      volumes:
        - name: nginx-conf
          configMap:
            name: hello-frontend-conf
```

Only the `serviceAccountName: hello-frontend-sa` line under `spec.template.spec` is new — everything else is unchanged from the current file.

- [ ] **Step 4: Wire `hello-backend-sa` into `backend-deployment.yaml`**

```yaml
# vps_oracle/k3s/apps/hello/k8s/backend-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello-backend
  namespace: pr-lanes
  labels:
    app: hello-backend
    lane: baseline
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: hello-backend
      lane: baseline
  template:
    metadata:
      labels:
        app: hello-backend
        lane: baseline
    spec:
      serviceAccountName: hello-backend-sa
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: hello-backend
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
```

- [ ] **Step 5: Wire `hello-backend-sa` into `backend-canary-deployment.yaml`**

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
      serviceAccountName: hello-backend-sa
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

- [ ] **Step 6: Wire `hello-backend-sa` into the PR-lane Deployment template**

```yaml
# vps_oracle/k3s/apps/hello/lane/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello-backend-lane
  labels:
    app: hello-backend
    lane: template
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: hello-backend
      lane: template
  template:
    metadata:
      labels:
        app: hello-backend
        lane: template
    spec:
      serviceAccountName: hello-backend-sa
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: hello-backend
          # This tag never exists on GHCR — it's a Kustomize base placeholder.
          # pr-lanes-appset.yaml's `kustomize.images` overrides it per-PR with the
          # PR's actual commit SHA. Should this placeholder ever get resolved as-is,
          # it fails safe: ImagePullBackOff, and Kyverno rejects it at admission first.
          image: ghcr.io/jeromefromcn/hello-backend:placeholder
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
          resources:
            requests:
              cpu: 25m
              memory: 64Mi
            limits:
              cpu: 100m
              memory: 128Mi
```

`pr-lanes-appset.yaml`'s kustomize patches only touch `metadata/name`, `metadata/labels/lane`, `spec/selector/matchLabels/lane`, and `spec/template/metadata/labels/lane` on this Deployment — `serviceAccountName` isn't in that patch list, so every dynamically-generated `hello-backend-pr-N` Deployment inherits it unmodified. No change to `pr-lanes-appset.yaml` needed.

- [ ] **Step 7: Validate YAML and commit**

```bash
python3 -c "
import yaml
for f in ['vps_oracle/k3s/apps/hello/k8s/frontend-serviceaccount.yaml',
          'vps_oracle/k3s/apps/hello/k8s/backend-serviceaccount.yaml',
          'vps_oracle/k3s/apps/hello/k8s/frontend-deployment.yaml',
          'vps_oracle/k3s/apps/hello/k8s/backend-deployment.yaml',
          'vps_oracle/k3s/apps/hello/k8s/backend-canary-deployment.yaml',
          'vps_oracle/k3s/apps/hello/lane/deployment.yaml']:
    yaml.safe_load(open(f))
" && echo OK
git add vps_oracle/k3s/apps/hello/k8s/frontend-serviceaccount.yaml \
  vps_oracle/k3s/apps/hello/k8s/backend-serviceaccount.yaml \
  vps_oracle/k3s/apps/hello/k8s/frontend-deployment.yaml \
  vps_oracle/k3s/apps/hello/k8s/backend-deployment.yaml \
  vps_oracle/k3s/apps/hello/k8s/backend-canary-deployment.yaml \
  vps_oracle/k3s/apps/hello/lane/deployment.yaml
git commit -m "Give hello-frontend and hello-backend variants their own ServiceAccounts

Replaces the shared default SA with hello-frontend-sa and
hello-backend-sa (the latter shared across baseline/canary/every PR
lane, treated as one role). This is the identity prerequisite for
Phase J's AuthorizationPolicy — mTLS principals need a real identity
to restrict on, and source.namespaces can't distinguish frontend from
backend since both live in pr-lanes."
git push
```

- [ ] **Step 8: Verify pods recreated with the new identity and everything still runs**

```bash
kubectl -n pr-lanes get pods -o custom-columns=NAME:.metadata.name,SA:.spec.serviceAccountName,STATUS:.status.phase
kubectl -n pr-lanes get sa
```

Expected: `hello-frontend` pod shows `hello-frontend-sa`; `hello-backend` and `hello-backend-canary` pods show `hello-backend-sa`; all `Running`. `get sa` now lists `default`, `waypoint`, `hello-frontend-sa`, `hello-backend-sa`.

- [ ] **Step 9: Confirm Kyverno admission still passes and quota is unchanged**

```bash
kubectl -n kyverno logs -l app.kubernetes.io/component=admission-controller --tail=80 | grep -E "hello-frontend|hello-backend"
kubectl -n pr-lanes describe resourcequota pr-lanes-quota
```

Expected: admission review log lines referencing the recreated pods, all passed (pods are `Running`, proving Kyverno didn't block them despite the new `serviceAccountName` field). Quota unchanged from Global Constraints (`limits.cpu: 500m`, `limits.memory: 640Mi`) — ServiceAccounts don't consume it.

- [ ] **Step 10: Smoke test — normal traffic still works with the new identities in place**

```bash
kubectl -n pr-lanes run curl-post-sa-check --rm -i --restart=Never --image=curlimages/curl:8.11.1 -- \
  curl -s -o /dev/null -w '%{http_code}\n' http://hello-backend.pr-lanes.svc.cluster.local/
```

Expected: `200` — no `AuthorizationPolicy` exists yet, so this just confirms the SA change alone didn't break anything.

---

### Task 2: Policy 2 — require traffic to arrive via the waypoint

**Files:**
- Create: `vps_oracle/k3s/apps/hello/k8s/backend-authorizationpolicy-require-waypoint.yaml`

**Interfaces:**
- Consumes: nothing from Task 1 directly (this policy only references the pre-existing `waypoint` SA) — sequenced after Task 1 because the spec's rollout order puts it first among the two policies, not because of a data dependency.
- Produces: the ztunnel-enforced backstop that Task 4's bypass verification tests against. Independent of Policy 1 (Task 3/4) — this task's policy is fully enforcing on its own from the moment it lands.

This is the plan's first live-enforcing change with no observation window (see Global Constraints for why). Read Step 1 and Step 3 carefully before applying — this step denies any inbound connection to a `hello-backend`-labeled pod that isn't from the waypoint, immediately.

- [ ] **Step 1: Confirm current state and the reasoning for skipping a dry-run window on this policy**

```bash
kubectl -n pr-lanes get authorizationpolicy
kubectl -n pr-lanes get pods -l app=hello-backend -o wide
```

Expected: no `AuthorizationPolicy` exists yet. Two pods (`hello-backend`, `hello-backend-canary`) match `app=hello-backend`. Before proceeding: per the spec, the only components that have ever connected directly to these pods are the waypoint (normal routed traffic) and kubelet (health probes, exempted at the ambient network layer via a fixed link-local SNAT address — not subject to `AuthorizationPolicy` at all). No other caller in this namespace's history connects to these pods directly, so there's nothing this policy could plausibly deny that isn't already unwanted.

- [ ] **Step 2: Write Policy 2**

```yaml
# vps_oracle/k3s/apps/hello/k8s/backend-authorizationpolicy-require-waypoint.yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: hello-backend-require-waypoint
  namespace: pr-lanes
spec:
  selector:
    matchLabels:
      app: hello-backend
  action: ALLOW
  rules:
    - from:
        - source:
            principals:
              - cluster.local/ns/pr-lanes/sa/waypoint
```

- [ ] **Step 3: Validate YAML and commit**

```bash
python3 -c "import yaml; yaml.safe_load(open('vps_oracle/k3s/apps/hello/k8s/backend-authorizationpolicy-require-waypoint.yaml'))" && echo OK
git add vps_oracle/k3s/apps/hello/k8s/backend-authorizationpolicy-require-waypoint.yaml
git commit -m "Require hello-backend pods to only accept traffic from the waypoint

Closes the bypass path Phase J's spec identified: a caller reaching a
backend pod without going through the waypoint at all skips Policy 1
(Task 3/4) entirely, since Policy 1 only evaluates traffic the waypoint
sees. This is the only protection hello-backend-pr-N pods get, since
their Service has no istio.io/use-waypoint label of its own. No
dry-run window — see Global Constraints for why this one goes straight
to Enforce."
git push
```

- [ ] **Step 4: Verify the policy landed and normal traffic through the waypoint still works**

```bash
kubectl -n pr-lanes get authorizationpolicy hello-backend-require-waypoint -o yaml
kubectl -n pr-lanes run curl-policy2-normal --rm -i --restart=Never --image=curlimages/curl:8.11.1 -- \
  curl -s -o /dev/null -w '%{http_code}\n' http://hello-backend.pr-lanes.svc.cluster.local/
kubectl -n pr-lanes run curl-policy2-canary --rm -i --restart=Never --image=curlimages/curl:8.11.1 -- \
  curl -s -o /dev/null -w '%{http_code}\n' http://hello-backend-canary.pr-lanes.svc.cluster.local/
```

Expected: policy object exists with the exact spec from Step 2. Both `curl` calls return `200` — even though these are throwaway debug pods with the `default` SA, calling the *Service hostname* still gets redirected through the waypoint (see Global Constraints: `use-waypoint` redirection is destination-based, not source-based), so the effective source ztunnel sees is the waypoint's identity, which Policy 2 allows.

- [ ] **Step 5: Verify the bypass path is actually closed — direct pod IP**

```bash
kubectl -n pr-lanes get pod -l app=hello-backend,lane=baseline -o jsonpath='{.items[0].status.podIP}'
```

Take that IP and:

```bash
BACKEND_IP=$(kubectl -n pr-lanes get pod -l app=hello-backend,lane=baseline -o jsonpath='{.items[0].status.podIP}')
kubectl -n pr-lanes run curl-policy2-bypass --rm -i --restart=Never --image=curlimages/curl:8.11.1 -- \
  curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 "http://${BACKEND_IP}:8080/"
```

Expected: the request fails — either a non-`200` status, a connection reset, or a timeout (Istio ambient's mTLS enforcement typically resets the connection rather than returning an HTTP status, since the deny happens before HTTP is even parsed at that layer). This is the plan's first proof that Policy 2 actually blocks a real bypass attempt, not just that the policy object exists.

- [ ] **Step 6: Confirm kubelet health checks are unaffected**

```bash
kubectl -n pr-lanes get pods -l app=hello-backend -o custom-columns=NAME:.metadata.name,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount
```

Expected: both pods `READY: true`, `RESTARTS: 0` (or whatever their pre-existing restart count was — the point is it hasn't incremented since this policy landed). Confirms the ambient kubelet-probe exemption (fixed link-local SNAT address, bypasses `AuthorizationPolicy` entirely) holds on this cluster, not just in documentation.

- [ ] **Step 7: Opportunistic PR-lane check**

```bash
kubectl -n argocd get application -l argocd.argoproj.io/application-set-name=pr-lanes
```

If this lists any `hello-pr-<N>` Application: confirm its pod also only shows traffic from waypoint working (`curl -H "x-pr-lane: <N>" http://hello-backend.pr-lanes.svc.cluster.local/` should still return that lane's content), and confirm a direct-pod-IP or direct-Service-hostname call to `hello-backend-pr-<N>` is blocked the same way Step 5 proved for baseline (this Service has no `use-waypoint` label, so its Service hostname alone is already a valid bypass — no pod IP needed for this one). If the list is empty, skip this step and note it in Task 5.

---

### Task 3: Policy 1 — waypoint-attached identity restriction, dry-run

**Files:**
- Create: `vps_oracle/k3s/apps/hello/k8s/backend-authorizationpolicy-waypoint.yaml`

**Interfaces:**
- Consumes: `hello-frontend-sa` (Task 1) as the allowed principal; the `waypoint` `Gateway` resource (`vps_oracle/k3s/apps/hello/k8s/waypoint-gateway.yaml`, pre-existing from Phase F+G) as the `targetRefs` target.
- Produces: dry-run observation data that Task 4 reads before deciding whether to flip this policy to Enforce.

- [ ] **Step 1: Confirm the waypoint Gateway this policy will target**

```bash
kubectl -n pr-lanes get gateway waypoint -o yaml
```

Expected: matches the existing `vps_oracle/k3s/apps/hello/k8s/waypoint-gateway.yaml` — `gatewayClassName: istio-waypoint`, listener `mesh` on port `15008`/`HBONE`. This is the exact object Policy 1's `targetRefs` names.

- [ ] **Step 2: Write Policy 1 with the dry-run annotation**

```yaml
# vps_oracle/k3s/apps/hello/k8s/backend-authorizationpolicy-waypoint.yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: hello-backend-waypoint-frontend-only
  namespace: pr-lanes
  annotations:
    istio.io/dry-run: "true"
spec:
  targetRefs:
    - kind: Gateway
      group: gateway.networking.k8s.io
      name: waypoint
  action: ALLOW
  rules:
    - from:
        - source:
            principals:
              - cluster.local/ns/pr-lanes/sa/hello-frontend-sa
```

- [ ] **Step 3: Validate YAML and commit**

```bash
python3 -c "import yaml; yaml.safe_load(open('vps_oracle/k3s/apps/hello/k8s/backend-authorizationpolicy-waypoint.yaml'))" && echo OK
git add vps_oracle/k3s/apps/hello/k8s/backend-authorizationpolicy-waypoint.yaml
git commit -m "Add dry-run AuthorizationPolicy restricting the waypoint to hello-frontend-sa

Attached via targetRefs to the waypoint Gateway itself, not a pod
selector — this is the layer that sees the caller's true identity
(confirmed against Istio ambient docs, see the design doc). Landed
with istio.io/dry-run: \"true\" for an observation window before
Task 4 flips it to Enforce, per the roadmap's Audit-before-Enforce
requirement for authorization changes."
git push
```

- [ ] **Step 4: Verify the policy landed and normal traffic is completely unaffected (dry-run never blocks)**

```bash
kubectl -n pr-lanes get authorizationpolicy hello-backend-waypoint-frontend-only -o yaml
kubectl -n pr-lanes run curl-policy1-dryrun-check --rm -i --restart=Never --image=curlimages/curl:8.11.1 -- \
  curl -s -o /dev/null -w '%{http_code}\n' http://hello-backend.pr-lanes.svc.cluster.local/
```

Expected: policy object exists with `annotations: {istio.io/dry-run: "true"}`. The `curl` call still returns `200` — this specific debug pod isn't `hello-frontend-sa`, so if dry-run weren't actually a no-op, this would be denied. A `200` here is the first evidence dry-run mode is truly non-enforcing (not yet proof it's logging anything — that's Step 5).

- [ ] **Step 5: Look for dry-run observation output**

```bash
kubectl -n pr-lanes logs deploy/waypoint --tail=200 | grep -i "dry.run\|dry_run" || echo "NO_DRYRUN_LOG_LINES"
istioctl proxy-config log deploy/waypoint -n pr-lanes 2>&1 | head -20
```

(Use the scratchpad `istioctl` per Global Constraints if it's not on `PATH` in this shell.)

Two possible outcomes, both fine — record whichever happens in Task 5:
- **Dry-run output found**: note the format (log lines, or a metric you found via a follow-up `istioctl proxy-config` / Envoy admin query) — this becomes the thing Step 6 below watches during the observation window.
- **Nothing found**: dry-run logging isn't surfacing on this waypoint in an easily observable way. This is not a blocker — fall back to the spec's documented alternative: since Step 4 already confirms the policy is a true no-op right now, and the observation content itself is "does `hello-frontend` remain the only real caller" (already established architecturally and re-confirmed by Task 2's Step 1), proceed to Task 4 on the strength of that manual confirmation instead of dry-run logs.

- [ ] **Step 6: Generate normal traffic during the observation window to have something to check against (whichever outcome Step 5 produced)**

```bash
kubectl -n pr-lanes run curl-policy1-traffic --rm -i --restart=Never --image=curlimages/curl:8.11.1 -- \
  sh -c 'for i in $(seq 1 20); do curl -s -o /dev/null -w "%{http_code}\n" http://hello-backend.pr-lanes.svc.cluster.local/; sleep 1; done'
```

Expected: 20x `200`. If Step 5 found a working dry-run log/metric, check it now for `allow` entries matching this traffic and confirm there are no unexpected `deny` entries mixed in (there's no `hello-frontend-sa` traffic to observe separately in this environment, since the smoke tests in this plan all originate from throwaway `default`-SA debug pods, not from the actual `hello-frontend` pod — note this limitation in Task 5 rather than fabricating a `hello-frontend`-originated test).

---

### Task 4: Flip Policy 1 to Enforce and run the adversarial verification

**Files:** none — this task edits Task 3's file and verifies live behavior.
- Modify: `vps_oracle/k3s/apps/hello/k8s/backend-authorizationpolicy-waypoint.yaml`

**Interfaces:**
- Consumes: Policy 1 (Task 3), Policy 2 (Task 2), `hello-frontend-sa`/`hello-backend-sa` (Task 1).
- Produces: nothing further tasks in this plan depend on — Task 5 is verification/documentation only.

This is the task where a misconfiguration would actually cut off traffic. Read Global Constraints' bypass-path note again before Step 4 — testing the wrong target (Service hostname instead of pod IP for baseline/canary) would give a false negative.

- [ ] **Step 1: Remove the dry-run annotation**

```yaml
# vps_oracle/k3s/apps/hello/k8s/backend-authorizationpolicy-waypoint.yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: hello-backend-waypoint-frontend-only
  namespace: pr-lanes
spec:
  targetRefs:
    - kind: Gateway
      group: gateway.networking.k8s.io
      name: waypoint
  action: ALLOW
  rules:
    - from:
        - source:
            principals:
              - cluster.local/ns/pr-lanes/sa/hello-frontend-sa
```

Only the `annotations: {istio.io/dry-run: "true"}` block is removed — nothing else changes.

- [ ] **Step 2: Validate YAML and commit**

```bash
python3 -c "import yaml; yaml.safe_load(open('vps_oracle/k3s/apps/hello/k8s/backend-authorizationpolicy-waypoint.yaml'))" && echo OK
git add vps_oracle/k3s/apps/hello/k8s/backend-authorizationpolicy-waypoint.yaml
git commit -m "Enforce Phase J's waypoint AuthorizationPolicy (drop dry-run)

Observation window (Task 3) showed no unexpected activity. Only
hello-frontend-sa may now call through the waypoint to any
hello-backend variant; Policy 2 (Task 2) independently requires all
such traffic to have arrived via the waypoint in the first place."
git push
```

- [ ] **Step 3: Verify legitimate traffic through the waypoint is now denied for a non-frontend identity**

```bash
kubectl -n pr-lanes run curl-policy1-deny-check --rm -i --restart=Never --image=curlimages/curl:8.11.1 -- \
  curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 http://hello-backend.pr-lanes.svc.cluster.local/
```

Expected: **not** `200` — connection reset, `403`, or timeout (ambient mTLS denial behavior, same as Task 2 Step 5). This debug pod runs as `default` SA; Policy 1 only allows `hello-frontend-sa`. This is the plan's core proof that Policy 1 actually restricts callers, not just that it exists.

- [ ] **Step 4: Verify Policy 2's bypass protection still independently holds**

```bash
BACKEND_IP=$(kubectl -n pr-lanes get pod -l app=hello-backend,lane=baseline -o jsonpath='{.items[0].status.podIP}')
kubectl -n pr-lanes run curl-final-bypass-check --rm -i --restart=Never --image=curlimages/curl:8.11.1 -- \
  curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 "http://${BACKEND_IP}:8080/"
```

Expected: same denial behavior as Task 2 Step 5 — proves Policy 2 wasn't accidentally disabled or superseded by Policy 1's Enforce switch.

- [ ] **Step 5: The one legitimate path this plan cannot fully exercise — note it, don't fake it**

This plan has no step that curls `hello-backend` from inside the actual `hello-frontend` pod using its real `hello-frontend-sa` identity end-to-end (every positive-path test above used throwaway debug pods reaching the Service hostname, which Policy 2 allows because the request still transits the waypoint — but those pods are not `hello-frontend-sa`, so post-Enforce they'd now be denied by Policy 1). Run this once to close that gap:

```bash
FRONTEND_POD=$(kubectl -n pr-lanes get pod -l app=hello-frontend,lane=baseline -o jsonpath='{.items[0].metadata.name}')
kubectl -n pr-lanes exec "$FRONTEND_POD" -- curl -s -o /dev/null -w '%{http_code}\n' http://hello-backend.pr-lanes.svc.cluster.local/
```

Expected: `200` — this is the real `hello-frontend` pod, running as `hello-frontend-sa`, calling through the waypoint exactly as production traffic does. If this returns anything other than `200`, Policy 1's principal string has a typo or the pod didn't actually pick up the new SA (re-check Task 1 Step 8) — do not proceed to Task 5 until this passes.

- [ ] **Step 6: Opportunistic PR-lane re-check**

Same as Task 2 Step 7 — if a `hello-pr-<N>` Application exists, confirm its header-routed traffic (via `hello-frontend`, or via a debug-pod call through the `hello-backend` Service hostname with the `x-pr-lane` header, which still transits the waypoint and is therefore governed by Policy 1 the same as baseline) still returns `200`, and that both Policy 1 and Policy 2's denials from Steps 3-4 apply equally to that lane's own backend. If no PR is open, skip and note it in Task 5.

---

### Task 5: End-to-end verification, quota check, and design doc update

**Files:**
- Modify: `docs/superpowers/specs/2026-08-23-k3s-phase-j-authorization-design.md`

**Interfaces:**
- Consumes: everything from Tasks 1-4.
- Produces: nothing — this is the plan's final gate.

- [ ] **Step 1: Full resource quota check**

```bash
kubectl -n pr-lanes describe resourcequota pr-lanes-quota
```

Expected: identical to the pre-plan baseline in Global Constraints (`limits.cpu: 500m/1200m`, `limits.memory: 640Mi/1536Mi`) — confirms the ServiceAccounts and AuthorizationPolicies added zero resource cost, as designed.

- [ ] **Step 2: Full cluster-wide regression check**

```bash
kubectl get pods -A -o wide | grep -v Running
kubectl get applications -n argocd -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status | grep -v "Synced.*Healthy"
```

Expected: both empty — every pod cluster-wide `Running`, every Application `Synced`/`Healthy`. Do not consider Phase J done until this passes.

- [ ] **Step 3: Combined smoke test as a final sanity pass**

```bash
FRONTEND_POD=$(kubectl -n pr-lanes get pod -l app=hello-frontend,lane=baseline -o jsonpath='{.items[0].metadata.name}')
echo "--- legitimate path (via hello-frontend pod, real hello-frontend-sa identity) ---"
kubectl -n pr-lanes exec "$FRONTEND_POD" -- curl -s -o /dev/null -w '%{http_code}\n' http://hello-backend.pr-lanes.svc.cluster.local/
echo "--- denied: wrong identity through the waypoint ---"
kubectl -n pr-lanes run curl-final-1 --rm -i --restart=Never --image=curlimages/curl:8.11.1 -- \
  curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 http://hello-backend.pr-lanes.svc.cluster.local/
echo "--- denied: bypass attempt, direct pod IP ---"
BACKEND_IP=$(kubectl -n pr-lanes get pod -l app=hello-backend,lane=baseline -o jsonpath='{.items[0].status.podIP}')
kubectl -n pr-lanes run curl-final-2 --rm -i --restart=Never --image=curlimages/curl:8.11.1 -- \
  curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 "http://${BACKEND_IP}:8080/"
```

Expected: `200`, then two non-`200` outcomes.

- [ ] **Step 4: Record implementation findings back into the design doc**

Open [docs/superpowers/specs/2026-08-23-k3s-phase-j-authorization-design.md](../specs/2026-08-23-k3s-phase-j-authorization-design.md)'s "已知限制 / 待查證風險" section and add findings from this plan's execution:
- Whether Task 3 Step 5 found working dry-run observation output on this waypoint, or fell back to manual confirmation
- Whether a PR lane was open during execution (Tasks 2/4's opportunistic steps) — if none was, note that the PR-lane-specific bypass protection (Policy 2 being the *only* defense for `hello-backend-pr-N`) is verified by architecture/documentation and by Policy 2's general mechanism, but not by a live PR-lane-specific test in this pass; flag it as worth re-checking the next time a real PR lane is open

```bash
git add docs/superpowers/specs/2026-08-23-k3s-phase-j-authorization-design.md
git commit -m "Record Phase J implementation findings in the design doc

Closes the open items in 已知限制 about dry-run observability on this
cluster's waypoint and whether PR-lane-specific bypass protection got
a live test during this implementation pass."
git push
```

- [ ] **Step 5: Final check — confirm this plan's file list matches what actually landed**

```bash
git log --oneline --stat -6 -- vps_oracle/k3s/apps/hello/
```

Expected: commits from Tasks 1, 2, 3, 4, 5, touching exactly: `frontend-serviceaccount.yaml`, `backend-serviceaccount.yaml`, `frontend-deployment.yaml` (modified), `backend-deployment.yaml` (modified), `backend-canary-deployment.yaml` (modified), `lane/deployment.yaml` (modified), `backend-authorizationpolicy-require-waypoint.yaml`, `backend-authorizationpolicy-waypoint.yaml` (created then modified). No other file under `vps_oracle/k3s/apps/hello/` touched, and nothing under `vps_oracle/k3s/argocd/apps/pr-lanes-appset.yaml` — confirms the plan stayed inside its stated scope.

---

## Self-Review Notes

- **Spec coverage:** every item in the design doc's 驗證清單 maps to a step above — items 1-2 (Application health, SA wiring) are Task 1 Steps 8-9; items 3-4 (Policy 2 traffic/kubelet) are Task 2 Steps 4-6; items 5-6 (dry-run observation) are Task 3 Steps 4-6, honestly framed for both possible dry-run-support outcomes; items 7-10 (Enforce verification, both denial paths, PR-lane recheck) are Task 4 Steps 3-6; items 11-12 (quota, full regression) are Task 5 Steps 1-2. The design doc's two "已知限制" items about dry-run support and PR-lane live testing are explicitly left as findings to record in Task 5 Step 4, not pre-answered — this plan doesn't know the answer until it runs.
- **Placeholder scan:** no TBD/TODO. Task 3 Step 5 and Task 4/5's PR-lane steps have two honestly-framed possible outcomes each rather than a single assumed result, with concrete commands and explicit instructions for both branches — not vague placeholders.
- **Type/name consistency:** `hello-frontend-sa` and `hello-backend-sa` are spelled identically across Task 1 (creation + wiring), Task 3/4 (Policy 1's `source.principals`), and the spec. `cluster.local/ns/pr-lanes/sa/waypoint` (Policy 2) and `cluster.local/ns/pr-lanes/sa/hello-frontend-sa` (Policy 1) match the trust domain confirmed live in Global Constraints. The two `AuthorizationPolicy` file names (`backend-authorizationpolicy-waypoint.yaml`, `backend-authorizationpolicy-require-waypoint.yaml`) match the spec's Repo 佈局 section exactly. `app: hello-backend` selector in Policy 2 matches the label already present on all three backend variants (confirmed via Task 1 Step 1's baseline read and the existing `backend-canary-deployment.yaml`/`lane/deployment.yaml` content).
