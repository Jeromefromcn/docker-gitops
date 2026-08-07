# K3s Phase B — GitOps Bootstrap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up ArgoCD (app-of-apps) on the phase A cluster so it self-manages its own Helm release plus phase A's namespace/quota/limitrange, deploy a new placeholder app through it, and prove the loop closes end to end: a GitHub Actions pipeline builds→scans→signs a real image, a git commit bumps the deployed tag, and ArgoCD self-heals any manual drift — so no future deploy needs `kubectl apply`.

**Architecture:** ArgoCD installed via Helm into a new `argocd` namespace, bootstrapped once by hand then handed over to a self-managing multi-source Application. A root "app of apps" Application watches `vps_oracle/k3s/argocd/apps/` in this repo and fans out to three children: the ArgoCD Helm release itself, phase A's foundation manifests (adopted from their current hand-applied state), and a new `placeholder-hello` demo app. A GitHub Actions workflow builds `placeholder-hello`'s image cross-architecture (x64 runner + QEMU → arm64), Trivy-scans it (fails on CRITICAL), and signs it with keyless Cosign via GitHub OIDC. ArgoCD's UI reaches the outside world through the same NPM NodePort-bridge pattern phase A validated.

**Tech Stack:** ArgoCD (Helm), GitHub Actions, Docker Buildx + QEMU, Trivy, Cosign (keyless/Sigstore), GHCR, kubectl, Nginx Proxy Manager (existing)

**Reference spec:** [docs/superpowers/specs/2026-08-07-k3s-phase-b-gitops-design.md](../specs/2026-08-07-k3s-phase-b-gitops-design.md)

## Global Constraints

- ArgoCD: single replica (no HA — single-node cluster), `dex.enabled: false` (no SSO — auth is local admin + NPM access list), `notifications.enabled: false`, `applicationSet.enabled: true` (kept for phase F, unused for now), `configs.params."server.insecure": true` (TLS terminates at NPM, same pattern every other service here uses).
- Every Application (`root`, `argocd`, `phase-a-foundation`, `placeholder-hello`) runs `syncPolicy.automated.prune: true` and `selfHeal: true`. This is the phase's actual acceptance criterion — verify it by deliberately breaking a managed resource and watching ArgoCD fix it, not just by confirming a sync succeeded once.
- No hardcoded version numbers in committed config — every install/workflow step looks up the current stable release at run time (same convention phase A used for k3s/Cilium) and records it into `vps_oracle/k3s/README.md`.
- No secrets in the repo. Two distinct credentials are needed and neither goes in git: a read-only fine-grained GitHub PAT (Contents: Read-only, scoped to this one repo) registered with ArgoCD as a repo credential (stored as a Secret in `argocd` namespace, created via `argocd repo add`, never written to a file); and a classic GitHub PAT (`write:packages`, `read:packages`) used once, locally, for the manual bootstrap push to GHCR in Task 4 — typed at the `docker login` prompt, never saved.
- Image tags pinned, never `latest` (repo-wide convention, `CLAUDE.md`). The placeholder app's deployment manifest always names an exact tag (`bootstrap`, then a real git SHA once CI produces one).
- `placeholder-hello` resource requests/limits: `requests: {cpu: 50m, memory: 64Mi}`, `limits: {cpu: 100m, memory: 128Mi}` — same sizing phase A's smoke-test used, well inside the `workloads` namespace's existing 1 CPU / 2Gi quota.
- CI (`aquasecurity/trivy-action`) fails the job on `CRITICAL` severity findings — this is a real gate, not advisory.
- CI signs with keyless Cosign (GitHub OIDC → Sigstore Fulcio/Rekor) — no key material anywhere, in the repo or in GitHub secrets.
- CI runner is `ubuntu-latest` (x64) with QEMU emulation for `linux/arm64` builds — not a self-hosted runner. Switching later is a one-line `runs-on:` change if emulation ever becomes a bottleneck; not needed now.
- Deploying a new image is still a manual git commit (bump the tag in `deployment.yaml`, commit, push) — deliberately not wired to an image-updater. This still satisfies "deploys go through GitOps, not kubectl apply."
- ArgoCD UI is exposed through NPM with `Access List: self-only` (same convention every other service here uses) — no homepage dashboard card, same precedent as `3x-ui`, since ArgoCD can deploy anything to the cluster.
- The `vps_oracle/k3s/manifests/` directory's existing phase A verification tooling (`smoke-test.yaml`, `netpol-test.yaml`) moves into a `verification/` subdirectory in this phase (Task 3) so the `phase-a-foundation` Application's non-recursive directory sync only picks up `namespace.yaml` / `resourcequota.yaml` / `limitrange.yaml`, not the throwaway test workloads.

---

## File Structure

```
vps_oracle/k3s/
  README.md                          # modified: ArgoCD section, version table rows
  argocd/
    values.yaml                       # Helm values for the argo-cd chart
    manifests/
      argocd-server-nodeport.yaml      # plain NodePort Service exposing argocd-server for the NPM bridge
    apps/
      root.yaml                        # app-of-apps root Application
      argocd.yaml                       # child: self-manages the argocd Helm release + the NodePort Service above
      phase-a-foundation.yaml            # child: adopts namespace/resourcequota/limitrange
      placeholder-hello.yaml              # child: deploys the placeholder app
  apps/
    placeholder-hello/
      Dockerfile
      index.html
      k8s/
        deployment.yaml
        service.yaml
  manifests/
    namespace.yaml                     # existing, untouched
    resourcequota.yaml                  # existing, untouched
    limitrange.yaml                      # existing, untouched
    verification/                         # new subdirectory
      smoke-test.yaml                      # moved from manifests/ (git mv)
      netpol-test.yaml                      # moved from manifests/ (git mv)

.github/
  workflows/
    placeholder-hello.yml              # build (QEMU arm64) -> Trivy -> Cosign keyless -> push GHCR
```

---

### Task 1: Install ArgoCD via Helm

**Files:**
- Create: `vps_oracle/k3s/argocd/values.yaml`
- Modify: `vps_oracle/k3s/README.md` (new "ArgoCD" section, version table row)

**Interfaces:**
- Consumes: the `Ready` k3s cluster from phase A (already live — `kubectl get nodes` shows one `Ready` node).
- Produces: a running ArgoCD install in the `argocd` namespace, reachable via `kubectl -n argocd port-forward`, with the `argocd` CLI installed locally and able to log in. Task 2 depends on this exact Helm release (name `argocd`, namespace `argocd`, same values file) existing so it can be handed over to self-management without creating duplicate resources.

- [ ] **Step 1: Add the Argo Helm repo and resolve the current chart version**

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
ARGOCD_CHART_VERSION=$(helm search repo argo/argo-cd -o json | jq -r '.[0].version')
echo "$ARGOCD_CHART_VERSION"
```

Expected: prints a version string like `7.x.x` (exact number will differ from this plan's authoring date — expected, not an error).

- [ ] **Step 2: Write the Helm values file**

Create `vps_oracle/k3s/argocd/values.yaml`:

```yaml
dex:
  enabled: false
notifications:
  enabled: false
applicationSet:
  enabled: true
configs:
  params:
    server.insecure: true
```

- [ ] **Step 3: Create the namespace and install**

```bash
kubectl create namespace argocd
helm install argocd argo/argo-cd \
  --version "$ARGOCD_CHART_VERSION" \
  --namespace argocd \
  -f vps_oracle/k3s/argocd/values.yaml
```

- [ ] **Step 4: Wait for rollout and confirm Dex/notifications are absent**

```bash
kubectl -n argocd rollout status deployment/argocd-server --timeout=180s
kubectl -n argocd get pods
```

Expected: `argocd-server`, `argocd-repo-server`, `argocd-applicationset-controller`, `argocd-redis`, and the `argocd-application-controller` StatefulSet pod are all `Running`. No `argocd-dex-server` or `argocd-notifications-controller` pods exist — if they do, `values.yaml` wasn't picked up; re-run `helm upgrade argocd argo/argo-cd --version "$ARGOCD_CHART_VERSION" --namespace argocd -f vps_oracle/k3s/argocd/values.yaml`.

- [ ] **Step 5: Install the `argocd` CLI, pinned to its current stable release**

```bash
ARGOCD_CLI_VERSION=$(curl -s https://api.github.com/repos/argoproj/argo-cd/releases/latest | jq -r .tag_name)
CLI_ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
curl -sSL -o argocd-cli "https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_CLI_VERSION}/argocd-linux-${CLI_ARCH}"
sudo install -m 555 argocd-cli /usr/local/bin/argocd
rm argocd-cli
argocd version --client
```

Expected: prints the client version, matching `$ARGOCD_CLI_VERSION`.

- [ ] **Step 6: Retrieve the initial admin password and confirm CLI login**

```bash
ARGOCD_ADMIN_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)
kubectl -n argocd port-forward svc/argocd-server 8080:80 &
sleep 2
argocd login localhost:8080 --username admin --password "$ARGOCD_ADMIN_PASSWORD" --insecure
kill %1
```

Expected: `'admin' logged in successfully`. Don't delete `argocd-initial-admin-secret` — later tasks re-derive this password the same way to log in from fresh shells; there's no other credential store set up in this phase.

- [ ] **Step 7: Record the resolved version and add an ArgoCD section to the README**

Edit `vps_oracle/k3s/README.md`, add a row to the version table:

```markdown
| ArgoCD | `<ARGOCD_CHART_VERSION from Step 1>` | <today's date> |
```

And a new section:

```markdown
## ArgoCD

Installed via Helm (`argo/argo-cd` chart) into the `argocd` namespace. Dex and the notifications controller are disabled (`argocd/values.yaml`) — auth is the built-in local admin account plus NPM's access list, no SSO; no alert-routing integration yet. Single replica everywhere, no HA — this is a single-node cluster.

The Helm release is bootstrapped once by hand (this README's Install section), then handed over to ArgoCD itself to self-manage via `vps_oracle/k3s/argocd/apps/argocd.yaml` — see the "App of apps" section below.

Get the admin password: `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d`. Log in: `kubectl -n argocd port-forward svc/argocd-server 8080:80 &`, then `argocd login localhost:8080 --username admin --password "<password>" --insecure`.

### Install

1. `helm repo add argo https://argoproj.github.io/argo-helm && helm repo update`
2. `kubectl create namespace argocd`
3. `helm install argocd argo/argo-cd --version "<pinned version>" --namespace argocd -f argocd/values.yaml`

Re-applying `argocd/values.yaml` after an edit: `helm upgrade argocd argo/argo-cd --version "<pinned version>" --namespace argocd -f argocd/values.yaml` (only needed if editing outside of ArgoCD's own self-management — once Task 2 hands the release over, prefer editing `values.yaml` and letting ArgoCD sync it).
```

Replace `<ARGOCD_CHART_VERSION from Step 1>` and `<today's date>` with the real values from Step 1.

- [ ] **Step 8: Commit**

```bash
git add vps_oracle/k3s/argocd/values.yaml vps_oracle/k3s/README.md
git commit -m "Install ArgoCD via Helm for phase B GitOps bootstrap"
```

---

### Task 2: App-of-apps root + ArgoCD self-management

**Files:**
- Create: `vps_oracle/k3s/argocd/apps/root.yaml`
- Create: `vps_oracle/k3s/argocd/apps/argocd.yaml`

**Interfaces:**
- Consumes: the Helm release from Task 1 (name `argocd`, namespace `argocd`, `vps_oracle/k3s/argocd/values.yaml`).
- Produces: a `root` Application that watches `vps_oracle/k3s/argocd/apps/` and an `argocd` child Application that adopts the Task 1 Helm release under GitOps management with `selfHeal`. Tasks 3 and 4 add more files to the same watched directory and rely on `root` picking them up automatically.

- [ ] **Step 1: Create a read-only GitHub credential for ArgoCD (manual, one-time)**

This repo is private, so ArgoCD needs a credential to clone it. In the GitHub web UI: Settings → Developer settings → Personal access tokens → Fine-grained tokens → Generate new token, scoped to only the `docker-gitops` repository, with **Contents: Read-only** permission and nothing else. Copy the token value into a shell variable — do not write it to any file in the repo:

```bash
read -rs GITHUB_READONLY_PAT
# paste the token, press enter — it is not echoed
```

- [ ] **Step 2: Register the repo with ArgoCD**

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:80 &
sleep 2
argocd login localhost:8080 --username admin --password "$ARGOCD_ADMIN_PASSWORD" --insecure

argocd repo add https://github.com/Jeromefromcn/docker-gitops.git \
  --username Jeromefromcn \
  --password "$GITHUB_READONLY_PAT"

argocd repo list
kill %1
```

Expected: `argocd repo list` shows the repo with `STATUS` `Successful`. This creates a Secret in the `argocd` namespace (`kubectl -n argocd get secrets -l argocd.argoproj.io/secret-type=repository`) — that Secret, not the repo, is what holds the credential; nothing touches the git working tree.

- [ ] **Step 3: Write the root Application**

Create `vps_oracle/k3s/argocd/apps/root.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/Jeromefromcn/docker-gitops.git
    targetRevision: main
    path: vps_oracle/k3s/argocd/apps
    directory:
      recurse: false
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

- [ ] **Step 4: Write the self-managing ArgoCD Application**

Create `vps_oracle/k3s/argocd/apps/argocd.yaml`. Replace `<ARGOCD_CHART_VERSION>` with the exact value resolved in Task 1 Step 1:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: argocd
  namespace: argocd
spec:
  project: default
  sources:
    - repoURL: https://argoproj.github.io/argo-helm
      chart: argo-cd
      targetRevision: "<ARGOCD_CHART_VERSION>"
      helm:
        valueFiles:
          - $values/vps_oracle/k3s/argocd/values.yaml
    - repoURL: https://github.com/Jeromefromcn/docker-gitops.git
      targetRevision: main
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

- [ ] **Step 5: Bootstrap the root Application (the one unavoidable manual `kubectl apply` — nothing else exists yet to create it)**

```bash
kubectl apply -f vps_oracle/k3s/argocd/apps/root.yaml
```

- [ ] **Step 6: Commit and push, then force an immediate sync**

```bash
git add vps_oracle/k3s/argocd/apps/root.yaml vps_oracle/k3s/argocd/apps/argocd.yaml
git commit -m "Bootstrap ArgoCD app-of-apps root and self-management"
git push
```

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:80 &
sleep 2
ARGOCD_ADMIN_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)
argocd login localhost:8080 --username admin --password "$ARGOCD_ADMIN_PASSWORD" --insecure
argocd app sync root
kill %1
```

- [ ] **Step 7: Verify both Applications are Synced and Healthy**

```bash
kubectl -n argocd get applications
```

Expected: two rows, `root` and `argocd`, both `SYNC STATUS` = `Synced` and `HEALTH STATUS` = `Healthy`. If `argocd` shows `OutOfSync` on resources that already exist from Task 1's manual install, that's expected on the very first sync (ArgoCD is reconciling Task 1's manually-created objects into ones it now tracks) — it should settle to `Synced` within a minute or two of `automated.selfHeal` kicking in. A leftover Helm release Secret from Task 1's `helm install` (`kubectl -n argocd get secrets -l owner=helm`) is expected and harmless — ArgoCD's Helm-source Applications render via `helm template`, not classic `helm install`/`upgrade`, so they don't reuse or clean up that Secret.

- [ ] **Step 8: Confirm ArgoCD itself survives a drift correction**

```bash
kubectl -n argocd scale deployment argocd-repo-server --replicas=0
sleep 15
kubectl -n argocd get deployment argocd-repo-server -o jsonpath='{.spec.replicas}'
```

Expected: after the sleep, replicas is back to `1` — ArgoCD's `application-controller` noticed `argocd-repo-server` (which it manages via the `argocd` Application) drifted from the desired `1` replica and corrected it, without anyone running `kubectl apply` or `helm upgrade`. This is the first concrete proof of the phase's core goal.

---

### Task 3: Adopt phase A's foundation manifests into GitOps

**Files:**
- Create: `vps_oracle/k3s/argocd/apps/phase-a-foundation.yaml`
- Modify: `vps_oracle/k3s/README.md` (update verification runbook paths)
- Move (git mv): `vps_oracle/k3s/manifests/smoke-test.yaml` → `vps_oracle/k3s/manifests/verification/smoke-test.yaml`
- Move (git mv): `vps_oracle/k3s/manifests/netpol-test.yaml` → `vps_oracle/k3s/manifests/verification/netpol-test.yaml`

**Interfaces:**
- Consumes: `root` Application from Task 2 (watches `vps_oracle/k3s/argocd/apps/` and will auto-discover this new file); the existing, currently hand-applied `namespace.yaml`/`resourcequota.yaml`/`limitrange.yaml` from phase A.
- Produces: those three resources now under `selfHeal` GitOps management. Task 4 deploys into the `workloads` namespace this Application governs.

- [ ] **Step 1: Move the phase A verification tooling out of the directory ArgoCD will sync**

`phase-a-foundation`'s Application will sync `vps_oracle/k3s/manifests/` non-recursively. That directory currently also holds `smoke-test.yaml` and `netpol-test.yaml` — phase A's reusable connectivity/policy test tooling, deliberately *not* meant to be permanently deployed. Move them into a subdirectory so the non-recursive sync skips them:

```bash
mkdir -p vps_oracle/k3s/manifests/verification
git mv vps_oracle/k3s/manifests/smoke-test.yaml vps_oracle/k3s/manifests/verification/smoke-test.yaml
git mv vps_oracle/k3s/manifests/netpol-test.yaml vps_oracle/k3s/manifests/verification/netpol-test.yaml
```

- [ ] **Step 2: Update the README's verification runbook to the new paths**

In `vps_oracle/k3s/README.md`, find the "Verification runbook" section (from phase A) and replace every reference to `manifests/smoke-test.yaml` with `manifests/verification/smoke-test.yaml`, and `manifests/netpol-test.yaml` with `manifests/verification/netpol-test.yaml`. The commands themselves (`kubectl apply -f ...`, `kubectl delete -f ...`) don't otherwise change.

- [ ] **Step 3: Write the phase-a-foundation Application**

Create `vps_oracle/k3s/argocd/apps/phase-a-foundation.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: phase-a-foundation
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/Jeromefromcn/docker-gitops.git
    targetRevision: main
    path: vps_oracle/k3s/manifests
    directory:
      recurse: false
  destination:
    server: https://kubernetes.default.svc
    namespace: workloads
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

- [ ] **Step 4: Commit, push, and force a sync**

```bash
git add vps_oracle/k3s/manifests/verification/smoke-test.yaml vps_oracle/k3s/manifests/verification/netpol-test.yaml \
        vps_oracle/k3s/argocd/apps/phase-a-foundation.yaml vps_oracle/k3s/README.md
git commit -m "Adopt phase A namespace/quota/limitrange into GitOps, move test tooling aside"
git push
```

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:80 &
sleep 2
ARGOCD_ADMIN_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)
argocd login localhost:8080 --username admin --password "$ARGOCD_ADMIN_PASSWORD" --insecure
argocd app sync root
kill %1
```

- [ ] **Step 5: Verify adoption didn't disturb the live resources**

```bash
kubectl -n argocd get application phase-a-foundation
kubectl describe resourcequota workloads-quota -n workloads
kubectl describe limitrange workloads-limits -n workloads
```

Expected: `phase-a-foundation` is `Synced`/`Healthy`; the quota and limitrange show the exact same `Hard`/default values phase A set (`requests.cpu: 1`, `requests.memory: 2Gi`, etc.) — ArgoCD adopted the existing objects in place, it didn't recreate them with different values.

---

### Task 4: Deploy `placeholder-hello` and prove self-heal

**Files:**
- Create: `vps_oracle/k3s/apps/placeholder-hello/Dockerfile`
- Create: `vps_oracle/k3s/apps/placeholder-hello/index.html`
- Create: `vps_oracle/k3s/apps/placeholder-hello/k8s/deployment.yaml`
- Create: `vps_oracle/k3s/apps/placeholder-hello/k8s/service.yaml`
- Create: `vps_oracle/k3s/argocd/apps/placeholder-hello.yaml`

**Interfaces:**
- Consumes: `workloads` namespace from Task 3; the host's own Docker daemon (native aarch64, no QEMU needed for this one manual bootstrap build) for the one-time image push.
- Produces: a running, GitOps-managed, self-healing `placeholder-hello` Deployment. Task 5 builds the real CI pipeline that will publish future images to the same GHCR path; Task 6 swaps this bootstrap image for a CI-built one.

- [ ] **Step 1: Write the app source**

Create `vps_oracle/k3s/apps/placeholder-hello/index.html`:

```html
<!DOCTYPE html>
<html>
<head><title>placeholder-hello</title></head>
<body><h1>Hello from GitOps Phase B</h1></body>
</html>
```

Create `vps_oracle/k3s/apps/placeholder-hello/Dockerfile`:

```dockerfile
FROM nginx:1.27-alpine
COPY index.html /usr/share/nginx/html/index.html
```

- [ ] **Step 2: Build it natively for this host's own architecture**

```bash
cd vps_oracle/k3s/apps/placeholder-hello
docker build -t ghcr.io/jeromefromcn/placeholder-hello:bootstrap .
cd -
```

Expected: builds successfully — this host is aarch64, so no cross-compilation is needed for this one manual build (CI will need QEMU because GitHub's hosted runners are x64; this local build isn't).

- [ ] **Step 3: Create a GHCR push credential (manual, one-time) and push**

In the GitHub web UI: Settings → Developer settings → Personal access tokens → Tokens (classic) → Generate new token, scopes `write:packages` and `read:packages`. This is a *different* credential from Task 2's read-only repo PAT — that one only reads repo contents, this one only writes container packages, neither can do the other's job.

```bash
docker login ghcr.io -u Jeromefromcn
# paste the classic PAT at the password prompt
docker push ghcr.io/jeromefromcn/placeholder-hello:bootstrap
```

- [ ] **Step 4: Make the package public**

Container packages pushed with a personal PAT default to private and aren't automatically linked to the repo the way an Actions-pushed package is. Since `index.html`/`Dockerfile` have no sensitive content, making the package public avoids needing an `imagePullSecret` in the cluster. In the GitHub web UI: your profile → Packages → `placeholder-hello` → Package settings → Change visibility → Public.

Verify:
```bash
docker logout ghcr.io
docker pull ghcr.io/jeromefromcn/placeholder-hello:bootstrap
```
Expected: pulls successfully with no credentials — confirms it's public.

- [ ] **Step 5: Write the Kubernetes manifests**

Create `vps_oracle/k3s/apps/placeholder-hello/k8s/deployment.yaml`:

```yaml
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
      containers:
        - name: placeholder-hello
          image: ghcr.io/jeromefromcn/placeholder-hello:bootstrap
          ports:
            - containerPort: 80
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 100m
              memory: 128Mi
```

Create `vps_oracle/k3s/apps/placeholder-hello/k8s/service.yaml`:

```yaml
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
      targetPort: 80
```

- [ ] **Step 6: Write the placeholder-hello Application**

Create `vps_oracle/k3s/argocd/apps/placeholder-hello.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: placeholder-hello
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/Jeromefromcn/docker-gitops.git
    targetRevision: main
    path: vps_oracle/k3s/apps/placeholder-hello/k8s
    directory:
      recurse: false
  destination:
    server: https://kubernetes.default.svc
    namespace: workloads
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

- [ ] **Step 7: Commit, push, and force a sync**

```bash
git add vps_oracle/k3s/apps/placeholder-hello vps_oracle/k3s/argocd/apps/placeholder-hello.yaml
git commit -m "Deploy placeholder-hello demo app via GitOps"
git push
```

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:80 &
sleep 2
ARGOCD_ADMIN_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)
argocd login localhost:8080 --username admin --password "$ARGOCD_ADMIN_PASSWORD" --insecure
argocd app sync root
kill %1
```

- [ ] **Step 8: Verify it's running and serving content**

```bash
kubectl -n argocd get application placeholder-hello
kubectl -n workloads rollout status deployment/placeholder-hello --timeout=60s
kubectl -n workloads port-forward svc/placeholder-hello 8081:80 &
sleep 2
curl -sS http://localhost:8081
kill %1
```

Expected: Application `Synced`/`Healthy`; curl output contains `Hello from GitOps Phase B`.

- [ ] **Step 9: Prove self-heal — the phase's core acceptance test**

```bash
kubectl -n workloads get deployment placeholder-hello -o jsonpath='{.spec.replicas}'
echo
kubectl -n workloads scale deployment placeholder-hello --replicas=0
kubectl -n workloads get deployment placeholder-hello -o jsonpath='{.spec.replicas}'
echo
for i in $(seq 1 30); do
  R=$(kubectl -n workloads get deployment placeholder-hello -o jsonpath='{.spec.replicas}')
  echo "replicas=$R"
  [ "$R" = "1" ] && break
  sleep 5
done
kubectl -n workloads get pods -l app=placeholder-hello
```

Expected: replicas prints `1`, then `0` immediately after the manual scale, then the loop shows it return to `1` within a few reconcile cycles (well under the 150s budget), and the final `get pods` shows a `Running` pod. If it doesn't self-heal within the loop, check `argocd app get placeholder-hello` for a sync error before assuming something is broken — a stuck repo credential (Task 2) is the most likely cause.

---

### Task 5: GitHub Actions CI — build, scan, sign

**Files:**
- Create: `.github/workflows/placeholder-hello.yml`

**Interfaces:**
- Consumes: `vps_oracle/k3s/apps/placeholder-hello/` source from Task 4; the repo's own `GITHUB_TOKEN` (no extra secret needed — same as how `homepage`/`llm`/`3x-ui` already pull public GHCR images, this just pushes to the same registry).
- Produces: an automated pipeline that builds, Trivy-scans, and keyless-signs a `linux/arm64` image on every push touching `placeholder-hello/`. Task 6 relies on this workflow actually running successfully to produce the image it will deploy.

- [ ] **Step 1: Resolve pinned versions for every action the workflow uses**

```bash
CHECKOUT_VER=$(gh api repos/actions/checkout/releases/latest --jq .tag_name)
QEMU_VER=$(gh api repos/docker/setup-qemu-action/releases/latest --jq .tag_name)
BUILDX_VER=$(gh api repos/docker/setup-buildx-action/releases/latest --jq .tag_name)
LOGIN_VER=$(gh api repos/docker/login-action/releases/latest --jq .tag_name)
BUILDPUSH_VER=$(gh api repos/docker/build-push-action/releases/latest --jq .tag_name)
TRIVY_VER=$(gh api repos/aquasecurity/trivy-action/releases/latest --jq .tag_name)
COSIGN_INSTALLER_VER=$(gh api repos/sigstore/cosign-installer/releases/latest --jq .tag_name)
echo "checkout=$CHECKOUT_VER qemu=$QEMU_VER buildx=$BUILDX_VER login=$LOGIN_VER buildpush=$BUILDPUSH_VER trivy=$TRIVY_VER cosign=$COSIGN_INSTALLER_VER"
```

Expected: seven version strings print, none empty/`null`. If any is `null`, that action's repo/release layout changed — check its releases page directly before proceeding.

- [ ] **Step 2: Write the workflow**

Create `.github/workflows/placeholder-hello.yml`. Replace every `<..._VER>` placeholder with the exact values from Step 1:

```yaml
name: placeholder-hello

on:
  push:
    branches: [main]
    paths:
      - 'vps_oracle/k3s/apps/placeholder-hello/**'
  workflow_dispatch: {}

permissions:
  contents: read
  packages: write
  id-token: write

env:
  IMAGE: ghcr.io/jeromefromcn/placeholder-hello

jobs:
  build-scan-sign:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@<CHECKOUT_VER>

      - name: Set up QEMU
        uses: docker/setup-qemu-action@<QEMU_VER>
        with:
          platforms: arm64

      - name: Set up Buildx
        uses: docker/setup-buildx-action@<BUILDX_VER>

      - name: Log in to GHCR
        uses: docker/login-action@<LOGIN_VER>
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build and push
        id: build
        uses: docker/build-push-action@<BUILDPUSH_VER>
        with:
          context: vps_oracle/k3s/apps/placeholder-hello
          platforms: linux/arm64
          push: true
          tags: ${{ env.IMAGE }}:${{ github.sha }}

      - name: Scan image with Trivy
        uses: aquasecurity/trivy-action@<TRIVY_VER>
        with:
          image-ref: ${{ env.IMAGE }}:${{ github.sha }}
          severity: CRITICAL
          exit-code: '1'
          ignore-unfixed: true

      - name: Install Cosign
        uses: sigstore/cosign-installer@<COSIGN_INSTALLER_VER>

      - name: Sign image (keyless)
        env:
          IMAGE_REF: ${{ env.IMAGE }}@${{ steps.build.outputs.digest }}
        run: cosign sign --yes "$IMAGE_REF"
```

Note: if Trivy fails on a `CRITICAL` finding in the `nginx:1.27-alpine` base image itself (not in anything we added), that's expected maintenance, not a broken pipeline — bump the tag in `Dockerfile` to whatever the current stable `nginx:X.Y-alpine` is and re-run.

- [ ] **Step 3: Commit and push**

```bash
git add .github/workflows/placeholder-hello.yml
git commit -m "Add build-Trivy-Cosign CI pipeline for placeholder-hello"
git push
```

- [ ] **Step 4: Trigger it manually and watch it run**

```bash
gh workflow run placeholder-hello.yml --ref main
sleep 5
RUN_ID=$(gh run list --workflow=placeholder-hello.yml --limit 1 --json databaseId --jq '.[0].databaseId')
gh run watch "$RUN_ID" --exit-status
```

Expected: exits `0`, every step green — build, Trivy scan (no CRITICAL findings), Cosign sign.

- [ ] **Step 5: Verify the pushed image and its signature**

```bash
CURRENT_SHA=$(git rev-parse HEAD)
docker pull "ghcr.io/jeromefromcn/placeholder-hello:${CURRENT_SHA}"
```

Install `cosign` locally if not already present (needed to verify from the shell, not just from inside a workflow):

```bash
COSIGN_VERSION=$(gh api repos/sigstore/cosign/releases/latest --jq .tag_name)
CLI_ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
curl -sSL -o cosign-cli "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-linux-${CLI_ARCH}"
sudo install -m 555 cosign-cli /usr/local/bin/cosign
rm cosign-cli
```

```bash
cosign verify "ghcr.io/jeromefromcn/placeholder-hello:${CURRENT_SHA}" \
  --certificate-identity-regexp "^https://github.com/Jeromefromcn/docker-gitops/.github/workflows/placeholder-hello.yml@refs/heads/main$" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

Expected: prints the verified signature's certificate details (subject matching the workflow's OIDC identity, issuer `https://token.actions.githubusercontent.com`) and at least one `tlogEntries` entry — confirming the signature is both valid and recorded in Rekor's public transparency log.

---

### Task 6: Close the loop — CI-built image deployed via git commit

**Files:**
- Modify: `vps_oracle/k3s/apps/placeholder-hello/index.html`
- Modify: `vps_oracle/k3s/apps/placeholder-hello/k8s/deployment.yaml`

**Interfaces:**
- Consumes: the CI pipeline from Task 5, the running deployment from Task 4.
- Produces: proof that the full intended flow works unassisted — a content change triggers CI automatically (not `workflow_dispatch` this time), CI publishes a new signed image, and bumping the tag in git is the only action needed to roll it out.

- [ ] **Step 1: Make a real content change**

Edit `vps_oracle/k3s/apps/placeholder-hello/index.html`:

```html
<!DOCTYPE html>
<html>
<head><title>placeholder-hello</title></head>
<body><h1>Hello from GitOps Phase B</h1><p>Deployed via CI.</p></body>
</html>
```

- [ ] **Step 2: Commit and push — this should trigger CI automatically via the path filter**

```bash
git add vps_oracle/k3s/apps/placeholder-hello/index.html
git commit -m "Update placeholder-hello content to trigger CI"
git push
```

- [ ] **Step 3: Watch the auto-triggered run**

```bash
sleep 10
RUN_ID=$(gh run list --workflow=placeholder-hello.yml --limit 1 --json databaseId --jq '.[0].databaseId')
gh run watch "$RUN_ID" --exit-status
```

Expected: exits `0` — and note this run was NOT started with `gh workflow run`; it fired on its own from the `paths:` push trigger, confirming the automation actually works unattended.

- [ ] **Step 4: Verify the new image and its signature**

```bash
NEW_SHA=$(git rev-parse HEAD)
cosign verify "ghcr.io/jeromefromcn/placeholder-hello:${NEW_SHA}" \
  --certificate-identity-regexp "^https://github.com/Jeromefromcn/docker-gitops/.github/workflows/placeholder-hello.yml@refs/heads/main$" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

Expected: same as Task 5 Step 5 — valid signature, Rekor entry, this time for `$NEW_SHA`.

- [ ] **Step 5: Bump the deployed image tag**

Edit `vps_oracle/k3s/apps/placeholder-hello/k8s/deployment.yaml`, change the `image:` line from `ghcr.io/jeromefromcn/placeholder-hello:bootstrap` to:

```yaml
          image: ghcr.io/jeromefromcn/placeholder-hello:<NEW_SHA>
```

Replace `<NEW_SHA>` with the actual SHA from Step 4.

- [ ] **Step 6: Commit, push, and sync**

```bash
git add vps_oracle/k3s/apps/placeholder-hello/k8s/deployment.yaml
git commit -m "Deploy CI-built placeholder-hello image"
git push
```

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:80 &
sleep 2
ARGOCD_ADMIN_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)
argocd login localhost:8080 --username admin --password "$ARGOCD_ADMIN_PASSWORD" --insecure
argocd app sync placeholder-hello
kill %1
```

- [ ] **Step 7: Verify the new image is actually running**

```bash
kubectl -n workloads rollout status deployment/placeholder-hello --timeout=60s
kubectl -n workloads get deployment placeholder-hello -o jsonpath='{.spec.template.spec.containers[0].image}'
echo
kubectl -n workloads port-forward svc/placeholder-hello 8081:80 &
sleep 2
curl -sS http://localhost:8081
kill %1
```

Expected: the image field shows the new SHA tag; curl output now includes `Deployed via CI.` — the full loop (git push → CI build/scan/sign → git commit → ArgoCD sync) is closed.

---

### Task 7: Expose ArgoCD via NPM and finalize documentation

**Files:**
- Create: `vps_oracle/k3s/argocd/manifests/argocd-server-nodeport.yaml`
- Modify: `vps_oracle/k3s/argocd/apps/argocd.yaml` (add a third source for the NodePort manifest)
- Modify: `vps_oracle/k3s/README.md` (app-of-apps layout section, final verification runbook)

**Interfaces:**
- Consumes: the `argocd` Application from Task 2 (multi-source, already has a Helm source and a values-only `ref` source).
- Produces: `https://argocd.jerome.cloudns.asia` reachable from outside, restricted to `self-only`. This is the phase's last deliverable — after this task, the full design-doc verification checklist should pass.

- [ ] **Step 1: Write a plain NodePort Service for argocd-server**

Create `vps_oracle/k3s/argocd/manifests/argocd-server-nodeport.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: argocd-server-nodeport
  namespace: argocd
spec:
  type: NodePort
  selector:
    app.kubernetes.io/name: argocd-server
  ports:
    - name: http
      port: 80
      targetPort: 8080
      nodePort: 30090
```

- [ ] **Step 2: Add it as a third source on the argocd Application**

Edit `vps_oracle/k3s/argocd/apps/argocd.yaml`, add a third entry under `spec.sources`:

```yaml
    - repoURL: https://github.com/Jeromefromcn/docker-gitops.git
      targetRevision: main
      path: vps_oracle/k3s/argocd/manifests
```

- [ ] **Step 3: Commit, push, sync, and verify the NodePort locally**

```bash
git add vps_oracle/k3s/argocd/manifests/argocd-server-nodeport.yaml vps_oracle/k3s/argocd/apps/argocd.yaml
git commit -m "Expose argocd-server via a fixed NodePort for the NPM bridge"
git push
```

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:80 &
sleep 2
ARGOCD_ADMIN_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)
argocd login localhost:8080 --username admin --password "$ARGOCD_ADMIN_PASSWORD" --insecure
argocd app sync argocd
kill %1
```

```bash
kubectl -n argocd get svc argocd-server-nodeport
curl -sS http://localhost:30090 | head -5
```

Expected: Service shows `TYPE NodePort`, port `80:30090/TCP`; curl returns ArgoCD's HTML shell (its SPA login page), confirming the NodePort works before touching NPM.

- [ ] **Step 4: Create the NPM proxy host**

In the NPM UI (`https://npm.jerome.cloudns.asia`), per the root README's "给服务接入 NPM 反代" conventions:

| Field | Value |
|---|---|
| Domain Names | `argocd.jerome.cloudns.asia` |
| Scheme | `http` |
| Forward Hostname / IP | the host's literal internal IP (currently `10.0.0.95` — confirm with `ip -4 addr show enp0s6`, it's DHCP-assigned and can drift) |
| Forward Port | `30090` |
| Cache Assets | off |
| Block Common Exploits | on |
| Websockets Support | on |
| Access List | `self-only` |
| SSL | Request a new certificate, Force SSL on, HTTP/2 on, HSTS off, per the standard SSL-tab settings in the README |

Save. **Known gotcha:** re-open the saved proxy host and confirm Force SSL / HTTP/2 are still on — NPM is known to silently reset these on save; re-check and re-save if needed.

- [ ] **Step 5: Verify end-to-end from outside**

```bash
curl -sS https://argocd.jerome.cloudns.asia | head -20
```

Expected: ArgoCD's login page HTML, served over HTTPS through NPM.

- [ ] **Step 6: Finalize the README**

Add a section after the "ArgoCD" section from Task 1:

```markdown
### App of apps

`argocd/apps/root.yaml` is the one Application applied by hand (`kubectl apply -f argocd/apps/root.yaml`); everything else in `argocd/apps/` is discovered automatically because `root` watches that directory. Children: `argocd` (self-manages this Helm release plus `argocd/manifests/argocd-server-nodeport.yaml`), `phase-a-foundation` (the namespace/quota/limitrange from phase A), `placeholder-hello` (the demo app proving the CI→GitOps loop).

All Applications run with `prune: true` / `selfHeal: true` — manual `kubectl` changes to anything they manage get reverted automatically. To add a new Application, write its manifest into `argocd/apps/`, commit, push, and either wait for the next poll or force it: `argocd app sync root`.

Access the UI: `https://argocd.jerome.cloudns.asia` (NPM access list restricts it to `self-only`). Admin password: see the "ArgoCD" section above.
```

- [ ] **Step 7: Run the full design-doc verification checklist**

Confirm every item from the [phase B design doc](../specs/2026-08-07-k3s-phase-b-gitops-design.md)'s "驗證清單" now passes:

```bash
kubectl -n argocd get applications
```
Expected: `root`, `argocd`, `phase-a-foundation`, `placeholder-hello` all `Synced`/`Healthy`.

```bash
kubectl get resourcequota,limitrange -n workloads
```
Expected: matches `vps_oracle/k3s/manifests/` in git.

The self-heal test (Task 4 Step 9), the Cosign verify (Task 5 Step 5 / Task 6 Step 4), and the NPM external curl (Step 5 above) have already been verified in their respective tasks — no need to repeat them, just confirm nothing has regressed:

```bash
kubectl -n workloads get pods -l app=placeholder-hello
curl -sS https://argocd.jerome.cloudns.asia | head -5
```

- [ ] **Step 8: Commit**

```bash
git add vps_oracle/k3s/README.md
git commit -m "Document ArgoCD app-of-apps layout and NPM access"
```

---

## Self-Review Notes

- **Spec coverage:** every item in the phase B design's "驗證清單" maps to a task: `root`/child Applications Synced+Healthy (Task 2 Step 7, Task 3 Step 5, Task 4 Step 8, Task 7 Step 7), phase A resources matching git (Task 3 Step 5), self-heal proof (Task 2 Step 8 for ArgoCD itself, Task 4 Step 9 for a workload), CI build→Trivy→Cosign→GHCR (Task 5), `cosign verify` against Rekor (Task 5 Step 5, Task 6 Step 4), manual tag-bump triggering an ArgoCD sync (Task 6), NPM external reachability with `self-only` (Task 7 Steps 4–5), resolved versions written to README (Task 1 Step 7, and the action versions resolved in Task 5 Step 1 are inlined directly into the committed workflow rather than tabulated — equivalent record, different location, appropriate for the artifact).
- **Placeholder scan:** every bracketed value (`<ARGOCD_CHART_VERSION>`, `<CHECKOUT_VER>`, `<NEW_SHA>`, etc.) is explicitly instructed to be replaced with a real value produced by a preceding step in the same or an earlier task — not an unresolved TBD.
- **Type/name consistency:** the `argocd` namespace, Helm release name `argocd`, Application names (`root`, `argocd`, `phase-a-foundation`, `placeholder-hello`), the `workloads` namespace, and the `placeholder-hello` Deployment/Service names are used identically across all seven tasks. The GHCR image path `ghcr.io/jeromefromcn/placeholder-hello` and the two distinct PATs (Task 2's read-only repo credential vs. Task 4's `write:packages` credential) are never conflated.
