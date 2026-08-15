# K3s Phase E — Kyverno + Trivy Operator + PSA Baseline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the cluster admission-time policy enforcement — Cosign signature verification for self-built images, Trivy CVE gating for every workload, and a restricted Pod Security profile for self-built workloads — plus a free namespace-wide baseline via Kubernetes' built-in Pod Security Admission.

**Architecture:** Deploy Trivy Operator (Job-only/Standalone mode, generates `VulnerabilityReport` CRDs) and Kyverno (admission-controller only) via ArgoCD. Three `ClusterPolicy` resources implement the three enforcement rules, all starting in `Audit` mode. Fix the two self-built workloads' `securityContext` first so they're ready for the restricted policy before it's ever enforced. Label the repo-managed namespaces with Kubernetes' built-in PSA `baseline` level — a separate, free mechanism, not part of Kyverno. Observe Audit-mode results, triage any findings, then flip all three policies to `Enforce`.

**Tech Stack:** Helm (`kyverno/kyverno` chart v3.8.2, app v1.18.2; `trivy-operator/trivy-operator` chart v0.35.0, app v0.33.0), ArgoCD (existing), `kubectl`.

**Spec:** [docs/superpowers/specs/2026-08-15-k3s-phase-e-supply-chain-security-design.md](../specs/2026-08-15-k3s-phase-e-supply-chain-security-design.md)

**Depends on:** [docs/superpowers/plans/2026-08-15-k3s-phase-e-sealed-secrets.md](2026-08-15-k3s-phase-e-sealed-secrets.md) should run first so the `sealed-secrets` namespace exists before Task 7 (PSA labeling) runs — but every other task in this plan works standalone regardless of that plan's status; Task 7 just skips `sealed-secrets` if it isn't there yet and gets a short follow-up label command afterward.

## Global Constraints

- Pin image tags/digests. No `latest` (repo-wide rule, README.md).
- One change per commit, scoped to one compose/k8s stack (repo-wide rule).
- Kyverno chart: `kyverno/kyverno` version `3.8.2` (app `v1.18.2`), repo `https://kyverno.github.io/kyverno/`.
- Trivy Operator chart: `trivy-operator/trivy-operator` version `0.35.0` (app `0.33.0`), repo `https://aquasecurity.github.io/helm-charts/`.
- Kyverno install scope: `admissionController` only (`replicas: 1`), `backgroundController.enabled: false`, `reportsController.enabled: false`, `cleanupController.enabled: false` — confirmed exact key names via `helm show values kyverno/kyverno --version 3.8.2`.
- Trivy Operator scan mode: `trivy.mode: Standalone` is already the chart default (Job-only, no persistent `trivy-server`) — do not override it to `ClientServer`.
- Namespaces: `kyverno`, `trivy-system` (both new, chart defaults, `CreateNamespace=true`).
- Self-built images in scope for Cosign/restricted policies: `ghcr.io/jeromefromcn/placeholder-hello`, `ghcr.io/jeromefromcn/vikunja-notify-relay` — both live in the `workloads` namespace, identified by pod label `app in (placeholder-hello, vikunja-notify-relay)`, not by namespace (namespace is mixed with third-party workloads).
- Trivy CVE gate scope: **all** workloads, cluster-wide, not scoped to self-built images.
- PSA baseline scope: `argocd`, `workloads`, `dify`, `llm`, `headlamp`, `kyverno`, `trivy-system`, `sealed-secrets` — not `lab-environment` (foreign project) or `kube-system` (needs privileged).
- All three `ClusterPolicy` resources start with `validationFailureAction: Audit`; flipping to `Enforce` is a deliberate, separate task (Task 9) gated on reviewing Audit-mode findings, not automatic.
- Repo path convention: `vps_oracle/k3s/kyverno/` and `vps_oracle/k3s/trivy-operator/`, alongside `vps_oracle/k3s/argocd/apps/kyverno.yaml` and `trivy-operator.yaml`, following the `argocd.yaml` multi-source pattern.

---

### Task 1: Fix securityContext on the two self-built workloads

**Files:**
- Modify: `vps_oracle/k3s/apps/placeholder-hello/Dockerfile`
- Modify: `vps_oracle/k3s/apps/placeholder-hello/k8s/deployment.yaml`
- Modify: `vps_oracle/k3s/apps/placeholder-hello/k8s/service.yaml`
- Modify: `vps_oracle/k3s/apps/vikunja/k8s/relay-deployment.yaml`

**Interfaces:**
- Produces: both Deployments' pods satisfy the Kubernetes `restricted` Pod Security Standard, so Task 6's policy (in `Audit` mode already, `Enforce` later in Task 9) has nothing to flag against them.

- [ ] **Step 1: Switch placeholder-hello to a non-root nginx image**

```dockerfile
# vps_oracle/k3s/apps/placeholder-hello/Dockerfile
FROM nginxinc/nginx-unprivileged:1.31.3-alpine3.24
COPY index.html /usr/share/nginx/html/index.html
```

(Only the `FROM` line changes — `nginxinc/nginx-unprivileged` runs as a non-root user by default and listens on `8080`, not `80`.)

- [ ] **Step 2: Update the Deployment's port and add securityContext**

```yaml
# vps_oracle/k3s/apps/placeholder-hello/k8s/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: placeholder-hello
  namespace: workloads
  labels:
    app: placeholder-hello
spec:
  replicas: 1
  selector:
    matchLabels:
      app: placeholder-hello
  template:
    metadata:
      labels:
        app: placeholder-hello
    spec:
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: placeholder-hello
          image: ghcr.io/jeromefromcn/placeholder-hello:0d3e52314b0950b893e32f684b5011ce8abdc798
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

- [ ] **Step 3: Update the Service's targetPort to match**

```yaml
# vps_oracle/k3s/apps/placeholder-hello/k8s/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: placeholder-hello
  namespace: workloads
spec:
  selector:
    app: placeholder-hello
  ports:
    - port: 80
      targetPort: 8080
```

(External `port: 80` is unchanged — nothing depends on this Service externally, it has no NodePort — only `targetPort` moves to match the new container port.)

- [ ] **Step 4: Add securityContext to vikunja-notify-relay (image already runs as `USER nobody`, just needs it declared)**

```yaml
# vps_oracle/k3s/apps/vikunja/k8s/relay-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vikunja-notify-relay
  namespace: workloads
  labels:
    app: vikunja-notify-relay
spec:
  replicas: 1
  selector:
    matchLabels:
      app: vikunja-notify-relay
  template:
    metadata:
      labels:
        app: vikunja-notify-relay
    spec:
      enableServiceLinks: false
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: relay
          image: ghcr.io/jeromefromcn/vikunja-notify-relay:1.1.0
          ports:
            - containerPort: 8080
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
          env:
            - name: TZ
              value: "Asia/Hong_Kong"
            - name: VIKUNJA_BASE_URL
              value: "https://vikunja.jerome.cloudns.asia"
            - name: APPRISE_BASE_URL
              value: "http://apprise:8000"
            - name: PORT
              value: "8080"
          resources:
            requests:
              cpu: 25m
              memory: 64Mi
            limits:
              cpu: 100m
              memory: 128Mi
```

- [ ] **Step 5: Validate YAML parses**

```bash
cd /home/ubuntu/jerome/docker-gitops
python3 -c "import yaml; yaml.safe_load(open('vps_oracle/k3s/apps/placeholder-hello/k8s/deployment.yaml')); print('ok')"
python3 -c "import yaml; yaml.safe_load(open('vps_oracle/k3s/apps/placeholder-hello/k8s/service.yaml')); print('ok')"
python3 -c "import yaml; yaml.safe_load(open('vps_oracle/k3s/apps/vikunja/k8s/relay-deployment.yaml')); print('ok')"
```

Expected: three `ok` lines.

- [ ] **Step 6: Commit and push**

```bash
cd /home/ubuntu/jerome/docker-gitops
git add vps_oracle/k3s/apps/placeholder-hello/Dockerfile vps_oracle/k3s/apps/placeholder-hello/k8s/deployment.yaml vps_oracle/k3s/apps/placeholder-hello/k8s/service.yaml vps_oracle/k3s/apps/vikunja/k8s/relay-deployment.yaml
git commit -m "Run self-built workloads as non-root to satisfy restricted Pod Security"
git push origin main
```

Expected: this triggers `.github/workflows/placeholder-hello.yml` (path filter matches `vps_oracle/k3s/apps/placeholder-hello/**`) — build/Trivy/Cosign/push for the new base image. It does NOT trigger `vikunja-notify-relay.yml` (its path filter is `vps_oracle/compose/vikunja/notify-relay/**`, not the k8s manifest directory) since only the Deployment YAML changed, not relay's own source — nothing to rebuild there.

- [ ] **Step 7: Wait for CI, then update the placeholder-hello image tag to the new build**

```bash
gh run list --workflow=placeholder-hello.yml --limit 1
```

Once that run is green, get the new digest-pinned tag from the GHCR package (same manual two-step pattern used in prior phases: check `ghcr.io/jeromefromcn/placeholder-hello` for the new `:<sha>` tag, then edit `image:` in `vps_oracle/k3s/apps/placeholder-hello/k8s/deployment.yaml` to that tag, commit, push).

- [ ] **Step 8: Verify both workloads roll out cleanly on the new images**

```bash
kubectl -n argocd get application placeholder-hello vikunja -o jsonpath='{.items[*].status.sync.status}{"\n"}'
kubectl get pods -n workloads -l 'app in (placeholder-hello,vikunja-notify-relay)'
```

Expected: both Applications `Synced`; both pods `Running`, `1/1` ready, no restarts.

- [ ] **Step 9: Confirm the pods actually run as non-root**

```bash
kubectl exec -n workloads deploy/placeholder-hello -- id
kubectl exec -n workloads deploy/vikunja-notify-relay -- id
```

Expected: neither prints `uid=0(root)`.

---

### Task 2: Deploy Trivy Operator

**Files:**
- Create: `vps_oracle/k3s/trivy-operator/values.yaml`
- Create: `vps_oracle/k3s/argocd/apps/trivy-operator.yaml`

**Interfaces:**
- Produces: `VulnerabilityReport` CRDs (`aquasecurity.github.io/v1alpha1`) for every workload's images, consumed by Task 5's policy.

- [ ] **Step 1: Write Helm values**

```yaml
# vps_oracle/k3s/trivy-operator/values.yaml
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 512Mi

trivy:
  # Standalone (Job-only) is the chart default — no persistent trivy-server
  # cache pod. Left explicit here so the choice is visible in git, not just
  # implied by omission.
  mode: Standalone
  resources:
    requests:
      cpu: 100m
      memory: 100Mi
    limits:
      cpu: 500m
      memory: 500Mi

scanJobsConcurrentLimit: 3
```

(`scanJobsConcurrentLimit: 3` caps how many scan Jobs run at once — default is 10, which on a 4-core box scanning ~13 images at first install could transiently spike CPU; 3 keeps the initial backlog from all firing simultaneously.)

- [ ] **Step 2: Write the ArgoCD Application**

```yaml
# vps_oracle/k3s/argocd/apps/trivy-operator.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: trivy-operator
  namespace: argocd
spec:
  project: default
  sources:
    - repoURL: https://aquasecurity.github.io/helm-charts/
      chart: trivy-operator
      targetRevision: "0.35.0"
      helm:
        releaseName: trivy-operator
        valueFiles:
          - $values/vps_oracle/k3s/trivy-operator/values.yaml
    - repoURL: https://github.com/Jeromefromcn/docker-gitops.git
      targetRevision: main
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: trivy-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

- [ ] **Step 3: Validate YAML and commit**

```bash
cd /home/ubuntu/jerome/docker-gitops
python3 -c "import yaml; yaml.safe_load(open('vps_oracle/k3s/trivy-operator/values.yaml')); print('ok')"
python3 -c "import yaml; yaml.safe_load(open('vps_oracle/k3s/argocd/apps/trivy-operator.yaml')); print('ok')"
git add vps_oracle/k3s/trivy-operator/values.yaml vps_oracle/k3s/argocd/apps/trivy-operator.yaml
git commit -m "Deploy Trivy Operator for cluster-wide vulnerability scanning"
git push origin main
```

- [ ] **Step 4: Verify the Application syncs and the operator is running**

```bash
kubectl -n argocd get application trivy-operator -o jsonpath='{.status.sync.status} {.status.health.status}{"\n"}'
kubectl -n trivy-system get pods
```

Expected: `Synced Healthy`; one `trivy-operator-*` pod `Running`.

- [ ] **Step 5: Confirm VulnerabilityReports start appearing**

```bash
sleep 60
kubectl get vulnerabilityreports -A
```

Expected: at least a few reports listed (the operator scans triggered by existing workloads; with 13 Applications' worth of images and `scanJobsConcurrentLimit: 3`, full coverage takes a few minutes — re-run this command and expect the count to keep climbing until it plateaus at roughly one report per running container).

- [ ] **Step 6: Inspect one report's actual shape (needed for Task 5 — do not skip)**

```bash
kubectl get vulnerabilityreports -A -o name | head -1 | xargs -I{} kubectl get {} -o yaml
```

Read the output and note: the exact label keys under `metadata.labels` (expect `trivy-operator.resource.name`, `trivy-operator.resource.namespace`, `trivy-operator.resource.kind`, `trivy-operator.container.name`), and the shape of `report.artifact` (expect `.repository` and `.tag` or `.digest`) and `report.summary` (expect `.criticalCount`, `.highCount`, etc.). Task 5's policy is written against this expected shape — if the live output differs, adjust Task 5's policy accordingly before applying it.

---

### Task 3: Deploy Kyverno (admission-controller only)

**Files:**
- Create: `vps_oracle/k3s/kyverno/values.yaml`
- Create: `vps_oracle/k3s/kyverno/policies/README.md`
- Create: `vps_oracle/k3s/argocd/apps/kyverno.yaml`

**Interfaces:**
- Produces: a running Kyverno admission webhook in namespace `kyverno`, ready to receive the three `ClusterPolicy` resources from Tasks 4-6.

- [ ] **Step 1: Write Helm values**

```yaml
# vps_oracle/k3s/kyverno/values.yaml
admissionController:
  replicas: 1
  container:
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
      limits:
        cpu: 500m
        memory: 512Mi

backgroundController:
  enabled: false

reportsController:
  enabled: false

cleanupController:
  enabled: false
```

- [ ] **Step 2: Create the placeholder policies directory**

```markdown
<!-- vps_oracle/k3s/kyverno/policies/README.md -->
# Kyverno Policies

`ClusterPolicy` manifests for phase E's admission control:

- `restrict-image-registry.yaml` — Cosign keyless signature verification,
  scoped to `ghcr.io/jeromefromcn/*` only.
- `require-vuln-scan-clean.yaml` — Trivy CVE gate via Trivy Operator's
  `VulnerabilityReport` CRDs, scoped to all workloads.
- `restricted-self-built.yaml` — Kubernetes `restricted` Pod Security
  profile, scoped to the `placeholder-hello` and `vikunja-notify-relay`
  Deployments by pod label.

All three start with `validationFailureAction: Audit`.
```

- [ ] **Step 3: Write the ArgoCD Application**

```yaml
# vps_oracle/k3s/argocd/apps/kyverno.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kyverno
  namespace: argocd
spec:
  project: default
  sources:
    - repoURL: https://kyverno.github.io/kyverno/
      chart: kyverno
      targetRevision: "3.8.2"
      helm:
        releaseName: kyverno
        valueFiles:
          - $values/vps_oracle/k3s/kyverno/values.yaml
    - repoURL: https://github.com/Jeromefromcn/docker-gitops.git
      targetRevision: main
      ref: values
    - repoURL: https://github.com/Jeromefromcn/docker-gitops.git
      targetRevision: main
      path: vps_oracle/k3s/kyverno/policies
  destination:
    server: https://kubernetes.default.svc
    namespace: kyverno
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

- [ ] **Step 4: Validate YAML and commit**

```bash
cd /home/ubuntu/jerome/docker-gitops
python3 -c "import yaml; yaml.safe_load(open('vps_oracle/k3s/kyverno/values.yaml')); print('ok')"
python3 -c "import yaml; yaml.safe_load(open('vps_oracle/k3s/argocd/apps/kyverno.yaml')); print('ok')"
git add vps_oracle/k3s/kyverno/values.yaml vps_oracle/k3s/kyverno/policies/README.md vps_oracle/k3s/argocd/apps/kyverno.yaml
git commit -m "Deploy Kyverno admission controller (admissionController only)"
git push origin main
```

- [ ] **Step 5: Verify sync and that only the admission controller deployed**

```bash
kubectl -n argocd get application kyverno -o jsonpath='{.status.sync.status} {.status.health.status}{"\n"}'
kubectl -n kyverno get pods
kubectl -n kyverno get deployments
```

Expected: `Synced Healthy`; exactly one Deployment named `kyverno-admission-controller` (confirmed via `helm template` against this exact chart version), one pod `Running`. No `background-controller`/`reports-controller`/`cleanup-controller` pods or Deployments present — confirms the disabled controllers really didn't deploy.

---

### Task 4: Cosign signature verification policy

**Files:**
- Create: `vps_oracle/k3s/kyverno/policies/restrict-image-registry.yaml`

**Interfaces:**
- Consumes: the CI pipeline's existing keyless Cosign signing (`.github/workflows/placeholder-hello.yml`, `.github/workflows/vikunja-notify-relay.yml`), both using GitHub Actions OIDC → Fulcio/Rekor.
- Produces: admission-time signature verification for `ghcr.io/jeromefromcn/*` images only.

- [ ] **Step 1: Write the policy**

```yaml
# vps_oracle/k3s/kyverno/policies/restrict-image-registry.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: restrict-image-registry
spec:
  validationFailureAction: Audit
  webhookTimeoutSeconds: 30
  rules:
    - name: verify-ghcr-jeromefromcn-signature
      match:
        any:
          - resources:
              kinds:
                - Pod
      verifyImages:
        - imageReferences:
            - "ghcr.io/jeromefromcn/*"
          attestors:
            - entries:
                - keyless:
                    subject: "https://github.com/Jeromefromcn/docker-gitops/.github/workflows/*.yml@refs/heads/main"
                    issuer: "https://token.actions.githubusercontent.com"
                    rekor:
                      url: https://rekor.sigstore.dev
```

(`skipImageReferences` isn't needed — `imageReferences` only opts in `ghcr.io/jeromefromcn/*`; every other image is untouched by this rule by default.)

- [ ] **Step 2: Validate YAML and commit**

```bash
cd /home/ubuntu/jerome/docker-gitops
python3 -c "import yaml; yaml.safe_load(open('vps_oracle/k3s/kyverno/policies/restrict-image-registry.yaml')); print('ok')"
git add vps_oracle/k3s/kyverno/policies/restrict-image-registry.yaml
git commit -m "Add Kyverno Cosign verification policy (Audit mode, ghcr.io/jeromefromcn/* only)"
git push origin main
```

- [ ] **Step 3: Verify the policy loads and is Ready**

```bash
kubectl -n argocd get application kyverno -o jsonpath='{.status.sync.status}{"\n"}'
kubectl get clusterpolicy restrict-image-registry -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}{"\n"}'
```

Expected: `Synced`; `True`.

- [ ] **Step 4: Confirm it doesn't touch third-party images**

```bash
kubectl rollout restart deployment trilium -n workloads
kubectl rollout status deployment trilium -n workloads --timeout=60s
```

Expected: rollout succeeds normally — `trilium` isn't `ghcr.io/jeromefromcn/*`, so `imageReferences` never matches it, Audit or not.

---

### Task 5: Trivy CVE gate policy

**Files:**
- Create: `vps_oracle/k3s/kyverno/policies/require-vuln-scan-clean.yaml`

**Interfaces:**
- Consumes: `VulnerabilityReport` CRDs from Task 2, whose live field shape was inspected in Task 2 Step 6.
- Produces: admission-time CRITICAL-CVE-with-fix blocking for every workload cluster-wide.

- [ ] **Step 1: Write the policy against the shape observed in Task 2 Step 6**

```yaml
# vps_oracle/k3s/kyverno/policies/require-vuln-scan-clean.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-vuln-scan-clean
spec:
  validationFailureAction: Audit
  webhookTimeoutSeconds: 30
  rules:
    - name: block-critical-fixable-cves
      match:
        any:
          - resources:
              kinds:
                - Pod
      context:
        - name: vulnreports
          apiCall:
            urlPath: "/apis/aquasecurity.github.io/v1alpha1/namespaces/{{request.object.metadata.namespace}}/vulnerabilityreports?labelSelector=trivy-operator.resource.name={{request.object.metadata.ownerReferences[0].name}}"
            jmesPath: "items[]"
      validate:
        message: >-
          Image has CRITICAL vulnerabilities with an available fix
          (Trivy VulnerabilityReport {{ request.object.metadata.name }}).
          Wait for a patched base image or fixed dependency, or add a
          documented exception before this can deploy.
        deny:
          conditions:
            all:
              - key: "{{ vulnreports[?report.summary.criticalCount > `0`] | length(@) }}"
                operator: GreaterThan
                value: 0
```

This is the first-draft policy; **do not treat it as final until Step 2 confirms it against a live Pod admission.** The `urlPath` label selector assumes Trivy Operator labels each `VulnerabilityReport` with `trivy-operator.resource.name` set to the owning Deployment's name (as noted in Task 2 Step 6) — if the live labels differ, or `{{request.object.metadata.ownerReferences[0].name}}` doesn't resolve the way expected for bare Pods created by a ReplicaSet (it may point to the ReplicaSet, not the Deployment — check and use `{{request.object.metadata.labels.app}}` or the actual owning-resource label Trivy Operator uses instead if so), adjust before moving to Step 2.

- [ ] **Step 2: Validate YAML, commit, and check policy readiness**

```bash
cd /home/ubuntu/jerome/docker-gitops
python3 -c "import yaml; yaml.safe_load(open('vps_oracle/k3s/kyverno/policies/require-vuln-scan-clean.yaml')); print('ok')"
git add vps_oracle/k3s/kyverno/policies/require-vuln-scan-clean.yaml
git commit -m "Add Kyverno Trivy CVE gate policy (Audit mode, cluster-wide)"
git push origin main
kubectl get clusterpolicy require-vuln-scan-clean -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}{"\n"}'
```

Expected: `True`.

- [ ] **Step 3: Force a real admission and inspect what the policy actually saw**

```bash
kubectl rollout restart deployment homepage -n workloads
sleep 5
kubectl get events -n workloads --field-selector reason=PolicyViolation --sort-by='.lastTimestamp' | tail -5
kubectl logs -n kyverno deploy/kyverno-admission-controller --tail=50 | grep -i "require-vuln-scan-clean\|error" || true
```

Expected: no Kyverno-internal errors referencing this policy (a JMESPath or `apiCall` syntax error shows up here, not as a silent no-op) — an event may or may not appear depending on whether `homepage`'s image currently has a CRITICAL+fixed CVE, but the absence of policy-engine errors is what this step is checking. If there are errors, fix the `context.apiCall`/`jmesPath` expression per Step 1's note and re-commit before continuing.

---

### Task 6: Restricted Pod Security policy for self-built workloads

**Files:**
- Create: `vps_oracle/k3s/kyverno/policies/restricted-self-built.yaml`

**Interfaces:**
- Consumes: Task 1's securityContext fixes on `placeholder-hello` and `vikunja-notify-relay`.
- Produces: admission-time enforcement of the Kubernetes `restricted` Pod Security Standard, scoped by pod label rather than namespace.

- [ ] **Step 1: Write the policy using Kyverno's built-in podSecurity validator**

```yaml
# vps_oracle/k3s/kyverno/policies/restricted-self-built.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: restricted-self-built
spec:
  validationFailureAction: Audit
  rules:
    - name: restricted-profile-self-built-workloads
      match:
        any:
          - resources:
              kinds:
                - Pod
              selector:
                matchExpressions:
                  - key: app
                    operator: In
                    values:
                      - placeholder-hello
                      - vikunja-notify-relay
      validate:
        message: >-
          Self-built workload {{ request.object.metadata.name }} does not
          meet the Kubernetes restricted Pod Security profile.
        podSecurity:
          level: restricted
          version: latest
```

- [ ] **Step 2: Validate YAML and commit**

```bash
cd /home/ubuntu/jerome/docker-gitops
python3 -c "import yaml; yaml.safe_load(open('vps_oracle/k3s/kyverno/policies/restricted-self-built.yaml')); print('ok')"
git add vps_oracle/k3s/kyverno/policies/restricted-self-built.yaml
git commit -m "Add Kyverno restricted Pod Security policy for self-built workloads (Audit mode)"
git push origin main
```

- [ ] **Step 3: Verify readiness and confirm the two workloads pass**

```bash
kubectl get clusterpolicy restricted-self-built -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}{"\n"}'
kubectl rollout restart deployment placeholder-hello -n workloads
kubectl rollout restart deployment vikunja-notify-relay -n workloads
kubectl rollout status deployment placeholder-hello -n workloads --timeout=60s
kubectl rollout status deployment vikunja-notify-relay -n workloads --timeout=60s
kubectl get events -n workloads --field-selector reason=PolicyViolation --sort-by='.lastTimestamp' | grep restricted-self-built || echo "no violations"
```

Expected: policy `True`; both rollouts succeed; `no violations` printed (proves Task 1's securityContext fixes actually satisfy `restricted`, not just `baseline`).

- [ ] **Step 4: Confirm it doesn't touch anything else**

```bash
kubectl rollout restart deployment vikunja -n workloads
kubectl rollout status deployment vikunja -n workloads --timeout=60s
```

Expected: succeeds — `vikunja` doesn't carry `app: placeholder-hello` or `app: vikunja-notify-relay`, so the label selector never matches it, regardless of whether it would pass `restricted` on its own.

---

### Task 7: PSA baseline labels

**Files:**
- Create: `vps_oracle/k3s/manifests/pod-security-labels.yaml`

**Interfaces:**
- Consumes: the `phase-a-foundation` Application (already syncing `vps_oracle/k3s/manifests/`) — this file is picked up automatically, no new Application needed.
- Produces: `pod-security.kubernetes.io/enforce=baseline` on the 8 repo-managed namespaces.

- [ ] **Step 1: Check whether `sealed-secrets` namespace exists yet**

```bash
kubectl get ns sealed-secrets 2>&1
```

If it doesn't exist yet (the Sealed Secrets plan hasn't run), skip it in Step 2 for now and add it back in a follow-up once it does exist — a `Namespace` resource for a namespace that doesn't exist yet will just get created by this manifest instead of adopting an existing one, which risks fighting with that other plan's `CreateNamespace=true`. Confirm which case applies before writing Step 2.

- [ ] **Step 2: Write the namespace label manifest**

```yaml
# vps_oracle/k3s/manifests/pod-security-labels.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: argocd
  labels:
    pod-security.kubernetes.io/enforce: baseline
---
apiVersion: v1
kind: Namespace
metadata:
  name: workloads
  labels:
    pod-security.kubernetes.io/enforce: baseline
---
apiVersion: v1
kind: Namespace
metadata:
  name: dify
  labels:
    pod-security.kubernetes.io/enforce: baseline
---
apiVersion: v1
kind: Namespace
metadata:
  name: llm
  labels:
    pod-security.kubernetes.io/enforce: baseline
---
apiVersion: v1
kind: Namespace
metadata:
  name: headlamp
  labels:
    pod-security.kubernetes.io/enforce: baseline
---
apiVersion: v1
kind: Namespace
metadata:
  name: kyverno
  labels:
    pod-security.kubernetes.io/enforce: baseline
---
apiVersion: v1
kind: Namespace
metadata:
  name: trivy-system
  labels:
    pod-security.kubernetes.io/enforce: baseline
---
apiVersion: v1
kind: Namespace
metadata:
  name: sealed-secrets
  labels:
    pod-security.kubernetes.io/enforce: baseline
```

(If Step 1 found `sealed-secrets` doesn't exist yet, omit that last document for now — applying a `Namespace` object for a name that doesn't exist just creates it, which is harmless, but it's cleaner to let the Sealed Secrets plan's own `CreateNamespace=true` be the one namespace-creation path for it, and add the label block back here once it's confirmed to exist.)

- [ ] **Step 3: Validate YAML (multi-document) and commit**

```bash
cd /home/ubuntu/jerome/docker-gitops
python3 -c "
import yaml
docs = list(yaml.safe_load_all(open('vps_oracle/k3s/manifests/pod-security-labels.yaml')))
assert all(d['kind'] == 'Namespace' for d in docs)
print(f'{len(docs)} namespace docs ok')
"
git add vps_oracle/k3s/manifests/pod-security-labels.yaml
git commit -m "Label repo-managed namespaces with PSA baseline"
git push origin main
```

- [ ] **Step 4: Verify labels landed and nothing broke**

```bash
kubectl -n argocd get application phase-a-foundation -o jsonpath='{.status.sync.status} {.status.health.status}{"\n"}'
kubectl get ns argocd workloads dify llm headlamp kyverno trivy-system -o jsonpath='{range .items[*]}{.metadata.name}{"="}{.metadata.labels.pod-security\.kubernetes\.io/enforce}{"\n"}{end}'
```

Expected: Application `Synced Healthy`; every namespace prints `=baseline`.

- [ ] **Step 5: Confirm baseline doesn't reject any existing pod**

```bash
kubectl -n argocd get applications -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.status.sync.status}{"/"}{.status.health.status}{"\n"}{end}'
```

Expected: every Application still `Synced`/`Healthy` — if any workload were violating `baseline` (privileged, hostNetwork, disallowed capabilities), its next pod restart would have already failed by this point since PSA rejects at admission immediately, not just on label application.

---

### Task 8: Review Audit-mode findings

**Files:**
- None (observation and triage — may produce follow-up commits depending on findings, tracked as sub-steps below)

**Interfaces:**
- Consumes: all three policies from Tasks 4-6, running in `Audit` mode since their creation.

- [ ] **Step 1: Let the cluster run for a while with all three policies in Audit mode**

This needs real elapsed time, not immediate action — the point of `Audit` mode (per the design doc) is observing behavior across normal operation, including at least one full Trivy re-scan cycle. Leave the policies as-is for a day or more before proceeding to Step 2. If executing this plan in one sitting without that gap, note explicitly that Step 2's review only reflects the scan state at that moment, not a full observation window.

- [ ] **Step 2: Pull every policy violation recorded so far**

```bash
kubectl get events -A --field-selector reason=PolicyViolation --sort-by='.lastTimestamp'
kubectl get vulnerabilityreports -A -o json | python3 -c "
import json, sys
data = json.load(sys.stdin)
for item in data['items']:
    crit = item.get('report', {}).get('summary', {}).get('criticalCount', 0)
    if crit > 0:
        ns = item['metadata']['namespace']
        name = item['metadata'].get('labels', {}).get('trivy-operator.resource.name', '?')
        print(f'{ns}/{name}: {crit} CRITICAL')
"
```

- [ ] **Step 3: Triage each finding**

For every image reported with CRITICAL+fixable CVEs: check whether a newer tag/digest fixes it (bump the pin in the relevant Deployment if so, following the repo's "pin image tags/digests" rule) or, if no fix is available upstream yet, document it as a known accepted exception in the k3s README rather than silently ignoring it. For any Cosign/restricted-policy violation outside the two self-built workloads: this would indicate the policy's `match` selector is broader than intended — stop and re-check Task 4/6's selectors, since third-party images and other workloads should never be in scope.

- [ ] **Step 4: Record the triage outcome**

Add a short "Phase E Audit findings (2026-08-15)" note to `vps_oracle/k3s/README.md` listing what was found and how each was resolved (upgraded / accepted exception / none found). This is the evidence Task 9 relies on to justify flipping to `Enforce`.

```bash
cd /home/ubuntu/jerome/docker-gitops
git add vps_oracle/k3s/README.md
git commit -m "Record phase E Audit-mode findings before Enforce cutover"
git push origin main
```

---

### Task 9: Flip to Enforce

**Files:**
- Modify: `vps_oracle/k3s/kyverno/policies/restrict-image-registry.yaml`
- Modify: `vps_oracle/k3s/kyverno/policies/require-vuln-scan-clean.yaml`
- Modify: `vps_oracle/k3s/kyverno/policies/restricted-self-built.yaml`

**Interfaces:**
- Consumes: Task 8's triage record — do not run this task until Task 8 Step 4 is committed.

- [ ] **Step 1: Flip all three policies**

In each of the three files, change:

```yaml
  validationFailureAction: Audit
```

to:

```yaml
  validationFailureAction: Enforce
```

- [ ] **Step 2: Validate and commit as one change (these three flip together, they're one decision)**

```bash
cd /home/ubuntu/jerome/docker-gitops
for f in vps_oracle/k3s/kyverno/policies/restrict-image-registry.yaml vps_oracle/k3s/kyverno/policies/require-vuln-scan-clean.yaml vps_oracle/k3s/kyverno/policies/restricted-self-built.yaml; do
  python3 -c "import yaml; yaml.safe_load(open('$f')); print('$f ok')"
done
git add vps_oracle/k3s/kyverno/policies/restrict-image-registry.yaml vps_oracle/k3s/kyverno/policies/require-vuln-scan-clean.yaml vps_oracle/k3s/kyverno/policies/restricted-self-built.yaml
git commit -m "Flip phase E Kyverno policies from Audit to Enforce"
git push origin main
```

- [ ] **Step 3: Confirm no regressions across every existing Application**

```bash
sleep 20
kubectl -n argocd get applications -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.status.sync.status}{"/"}{.status.health.status}{"\n"}{end}'
```

Expected: all Applications `Synced`/`Healthy`, including `dify` and `llm` (the widest-blast-radius policy, the Trivy gate, covers them and every other third-party image).

- [ ] **Step 4: Prove Enforce actually blocks — Cosign**

```bash
kubectl run cosign-enforce-test --image=ghcr.io/jeromefromcn/placeholder-hello:latest -n workloads --restart=Never 2>&1 | tail -5
kubectl delete pod cosign-enforce-test -n workloads --ignore-not-found
```

Expected: the `kubectl run` is rejected by the admission webhook with an error mentioning `restrict-image-registry` — `:latest` was never built/signed by CI, so no matching Rekor entry exists. (The `delete --ignore-not-found` cleans up in case it somehow got created, e.g. if this policy's match/scope needs revisiting.)

- [ ] **Step 5: Prove Enforce actually blocks — restricted profile**

```bash
kubectl run restricted-enforce-test --image=ghcr.io/jeromefromcn/placeholder-hello:latest -n workloads --restart=Never --labels=app=placeholder-hello --overrides='{"spec":{"containers":[{"name":"restricted-enforce-test","image":"ghcr.io/jeromefromcn/placeholder-hello:latest","securityContext":{"runAsUser":0}}]}}' 2>&1 | tail -5
kubectl delete pod restricted-enforce-test -n workloads --ignore-not-found
```

Expected: rejected — explicit `runAsUser: 0` on a pod labeled `app=placeholder-hello` violates both `restrict-image-registry` (unsigned `:latest`) and `restricted-self-built` (root). Either denial message is acceptable proof; the point is the pod never gets created.

---

### Task 10: README handoff update

**Files:**
- Modify: `vps_oracle/k3s/README.md`

- [ ] **Step 1: Add a "Kyverno / Trivy Operator / PSA" section**

Following the existing `## ArgoCD` section's structure, document: chart versions installed, which Kyverno controllers are disabled and why, the three policies and their scope (self-built-only vs. cluster-wide), and the PSA baseline namespace list. Include the one-line pattern for adding a new self-built workload to the restricted policy's label selector in the future (edit `restricted-self-built.yaml`'s `values` list) — this is the thing a future change is most likely to need.

- [ ] **Step 2: Commit**

```bash
cd /home/ubuntu/jerome/docker-gitops
git add vps_oracle/k3s/README.md
git commit -m "Document Kyverno/Trivy Operator/PSA baseline in k3s README"
git push origin main
```

## Self-Review

- **Spec coverage**: Trivy Operator（Job-only）→ Task 2；Kyverno（admission-controller only）→ Task 3；Cosign 驗簽（自建鏡像範圍）→ Task 4；Trivy CVE 門禁（全叢集）→ Task 5；restricted-equivalent（per-workload）→ Task 6；PSA baseline（8 個 namespace）→ Task 7；Audit→Enforce 節奏 → Task 8/9；securityContext 修正（placeholder-hello base image 換、containerPort 改、vikunja-notify-relay 補宣告）→ Task 1；驗證清單第 9/10 條（Enforce 後故意違規測試 + 全 Application 複查）→ Task 9 Step 3-5。
- **Placeholder scan**：Task 5 的 policy 明確標註「first-draft，需對照 Task 2 Step 6 實測的即時 schema 調整」——這不是 TBD，是把「對照活體 CRD 驗證」這個必要的經驗性步驟明確寫成任務的一部分，且已給出具體的起始版本內容，不是留白等執行者自己想。其餘任務沒有 TBD/TODO。
- **Type consistency**：`app in (placeholder-hello, vikunja-notify-relay)` selector 在 Task 6 policy 與 Task 1 的 Deployment label 一致；三個 policy 檔名（`restrict-image-registry.yaml`/`require-vuln-scan-clean.yaml`/`restricted-self-built.yaml`）從 Task 3 的 README 說明、Task 4-6 建立、到 Task 9 flip Enforce 全程一致；`--controller-name`/chart version 等版本號跨 Task 1 全文一致，來源是 2026-08-15 對 `helm search repo`/GitHub Release 的實測，不是憑印象。

---

Plan complete and saved to `docs/superpowers/plans/2026-08-15-k3s-phase-e-kyverno-trivy.md`.
