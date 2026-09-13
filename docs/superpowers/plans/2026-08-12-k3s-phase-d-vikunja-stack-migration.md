# K3s Phase D — Vikunja Stack Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate vikunja (sqlite + data) + vikunja-notify-relay + apprise from docker compose into the k3s `workloads` namespace, keeping the domain/port unchanged externally, so the Telegram notification chain (vikunja → relay → apprise → Telegram) keeps working after the move.

**Architecture:** Reuse phase C's NPM→NodePort bridging pattern. vikunja's sqlite db + files move into one local-path PVC (the six-step seed-pod pattern, following the trilium template); apprise's /config (40K) moves into a second PVC. relay is a locally-built image, pushed to GHCR first so k3s can pull it. Each of the three services gets its own Deployment; vikunja opens NodePort 30084, apprise opens 30085, relay is ClusterIP only. The webhook URL (`http://vikunja-notify-relay:8080/`) carries over unchanged because the k8s Service has the same name — no re-registration needed.

**Tech Stack:** k3s (Cilium + ArgoCD app-of-apps), Kubernetes manifests (Deployment/PVC/Service), local-path StorageClass, NPM automation API, GHCR + GitHub Actions (relay CI).

## Global Constraints

- All pods use `enableServiceLinks: false` across the board (avoids the Service-name-injected `<SVC>_PORT` colliding with the app's own env vars — the trilium `TRILIUM_PORT` lesson)
- All env sets `TZ: Asia/Hong_Kong`; whether the image has tzdata is aligned by actually testing `date`, not chased further (see the k8s README comparison table)
- Images are always pinned to a tag, never `latest`; secrets never go into git (sourced from each compose directory's gitignored `.env`)
- NPM's Forward Hostname/IP must be the literal IP `10.0.0.95` (known gotcha since phase A)
- Query the local-path PV directory via `spec.local.path` (not `spec.hostPath.path`)
- After stopping a container, **wait ~10 seconds** before counting files (sqlite wal/shm needs to settle — phase C lesson)
- New ArgoCD Applications always get `prune: true` / `selfHeal: true`; use `argocd app sync root` to make a new Application take effect
- The `workloads` quota is `2C/4Gi`; after adding the vikunja stack, limits come to about `700m/768Mi`, requests about `350m/384Mi`, and combined with the existing `1C/1280Mi` this stays within quota — **do not adjust the quota**
- Container UIDs: vikunja=1000, apprise=root, relay=nobody. PVC data ownership is aligned to vikunja's uid 1000
- Every task runs locally on the k3s node (this machine); `kubectl` is already pointed at the cluster

---

### Task 1: Push the vikunja-notify-relay image to GHCR

**Files:**
- Build context: `vps_oracle/compose/vikunja/notify-relay/` (Dockerfile + app.py, unchanged)

**Interfaces:**
- Produces: `ghcr.io/jeromefromcn/vikunja-notify-relay:1.1.0` (linux/arm64, referenced by Task 9's relay Deployment)

- [ ] **Step 1: Rebuild the relay image from the repo source** (make sure what gets pushed matches the repo's current state, not some historical build)

```bash
cd /home/ubuntu/jerome/docker-gitops
docker build -t vikunja-notify-relay:1.1.0 vps_oracle/compose/vikunja/notify-relay/
```

Expected: build succeeds, ending with `Successfully tagged vikunja-notify-relay:1.1.0:latest` (`latest` is docker build's placeholder tag, overwritten by the next step).

- [ ] **Step 2: Confirm GHCR login**

```bash
docker login ghcr.io -u Jeromefromcn --password-stdin
```

(Use a GitHub PAT as the password, scope `write:packages`; skip if the terminal is already logged in. Type it in at the prompt — don't write it into any file.)

- [ ] **Step 3: Tag and push**

```bash
docker tag vikunja-notify-relay:1.1.0 ghcr.io/jeromefromcn/vikunja-notify-relay:1.1.0
docker push ghcr.io/jeromefromcn/vikunja-notify-relay:1.1.0
```

Expected: push succeeds, prints a digest line.

- [ ] **Step 4: Verify it's pullable by k3s (arm64 manifest exists)**

```bash
docker buildx imagetools inspect ghcr.io/jeromefromcn/vikunja-notify-relay:1.1.0
```

Expected: shows `Platform: linux/arm64` (with digest).

---

### Task 2: Create the `vikunja` Secret (VIKUNJA_SERVICE_SECRET)

**Files:**
- Source: `vps_oracle/compose/vikunja/.env` (gitignored, already contains `VIKUNJA_SERVICE_SECRET=<openssl rand -hex 32>`, never committed)

**Interfaces:**
- Produces: Secret `vikunja` (key `VIKUNJA_SERVICE_SECRET`) in ns `workloads`, referenced by Task 3's vikunja Deployment via `secretKeyRef`

- [ ] **Step 1: Extract the secret value from the gitignored .env and create the Secret idempotently**

```bash
cd /home/ubuntu/jerome/docker-gitops
kubectl create secret generic vikunja -n workloads \
  --from-literal=VIKUNJA_SERVICE_SECRET="$(grep -E '^VIKUNJA_SERVICE_SECRET=' vps_oracle/compose/vikunja/.env | cut -d= -f2-)" \
  --dry-run=client -o yaml | kubectl apply -f -
```

(`grep | cut` extracts just that key, assuming the .env has it as a single-line `VIKUNJA_SERVICE_SECRET=...` entry. Using dry-run+apply makes re-runs idempotent.)

- [ ] **Step 2: Verify the secret exists and the key is non-empty**

```bash
kubectl get secret vikunja -n workloads -o jsonpath='{.data.VIKUNJA_SERVICE_SECRET}' | wc -c
```

Expected: output > 0 (byte count after base64 encoding). Don't print the value itself.

---

### Task 3: Write the vikunja + relay k8s manifests

**Files:**
- Create: `vps_oracle/k3s/apps/vikunja/k8s/pvc.yaml`
- Create: `vps_oracle/k3s/apps/vikunja/k8s/deployment.yaml`
- Create: `vps_oracle/k3s/apps/vikunja/k8s/service.yaml`
- Create: `vps_oracle/k3s/apps/vikunja/k8s/relay-deployment.yaml`
- Create: `vps_oracle/k3s/apps/vikunja/k8s/relay-service.yaml`

(The spec's repo layout puts relay in a `relay/` subdirectory; here it's flattened into the same directory instead — ArgoCD doesn't scan subdirectories recursively, so flat is simplest.)

**Interfaces:**
- Consumes: Secret `vikunja` (Task 2), image `ghcr.io/jeromefromcn/vikunja-notify-relay:1.1.0` (Task 1)
- Produces: PVC `vikunja`, Deployment/Service `vikunja` (NodePort 30084), Deployment/Service `vikunja-notify-relay` (ClusterIP 8080) — used by Task 7's data migration and Task 9's sync

- [ ] **Step 1: `pvc.yaml`**

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: vikunja
  namespace: workloads
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: local-path
  resources:
    requests:
      storage: 2Gi
```

- [ ] **Step 2: `deployment.yaml`**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vikunja
  namespace: workloads
  labels:
    app: vikunja
spec:
  replicas: 1
  selector:
    matchLabels:
      app: vikunja
  template:
    metadata:
      labels:
        app: vikunja
    spec:
      # Without this, VIKUNJA_PORT=tcp://... gets injected and collides with
      # vikunja's own VIKUNJA_* config (the trilium lesson)
      enableServiceLinks: false
      containers:
        - name: vikunja
          image: vikunja/vikunja:2.4.0
          ports:
            - containerPort: 3456
          env:
            - name: TZ
              value: "Asia/Hong_Kong"
            - name: VIKUNJA_DATABASE_TYPE
              value: sqlite
            - name: VIKUNJA_DATABASE_PATH
              value: /db/vikunja.db
            - name: VIKUNJA_SERVICE_PUBLICURL
              value: "https://vikunja.jerome.cloudns.asia"
            - name: VIKUNJA_SERVICE_ENABLEREGISTRATION
              value: "false"
            - name: VIKUNJA_OUTGOINGREQUESTS_ALLOWNONROUTABLEIPS
              value: "true"
            - name: VIKUNJA_SERVICE_SECRET
              valueFrom:
                secretKeyRef:
                  name: vikunja
                  key: VIKUNJA_SERVICE_SECRET
          volumeMounts:
            - name: data
              mountPath: /db
              subPath: db
            - name: data
              mountPath: /app/vikunja/files
              subPath: files
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 300m
              memory: 256Mi
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: vikunja
```

(`subPath: db` / `subPath: files` correspond to the `db/`, `files/` subdirectories under the PV root — created when Task 7 moves the data in.)

- [ ] **Step 3: `service.yaml`**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: vikunja
  namespace: workloads
spec:
  type: NodePort
  selector:
    app: vikunja
  ports:
    - port: 3456
      targetPort: 3456
      nodePort: 30084
```

- [ ] **Step 4: `relay-deployment.yaml`**

```yaml
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
      containers:
        - name: relay
          image: ghcr.io/jeromefromcn/vikunja-notify-relay:1.1.0
          ports:
            - containerPort: 8080
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
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 100m
              memory: 128Mi
```

- [ ] **Step 5: `relay-service.yaml`** (internal-only, ClusterIP; the name must be `vikunja-notify-relay` for the webhook URL stored in vikunja's DB to resolve)

```yaml
apiVersion: v1
kind: Service
metadata:
  name: vikunja-notify-relay
  namespace: workloads
spec:
  selector:
    app: vikunja-notify-relay
  ports:
    - port: 8080
      targetPort: 8080
```

- [ ] **Step 6: Verify all five files were written** (placeholder check only; the real verification is in Task 9)

```bash
ls vps_oracle/k3s/apps/vikunja/k8s/
```

Expected: `pvc.yaml  deployment.yaml  service.yaml  relay-deployment.yaml  relay-service.yaml`

---

### Task 4: Write the apprise k8s manifests

**Files:**
- Create: `vps_oracle/k3s/apps/apprise/k8s/pvc.yaml`
- Create: `vps_oracle/k3s/apps/apprise/k8s/deployment.yaml`
- Create: `vps_oracle/k3s/apps/apprise/k8s/service.yaml`

**Interfaces:**
- Produces: PVC `apprise`, Deployment/Service `apprise` (NodePort 30085) — used by Task 8's data migration, Task 10's sync, and Task 11's NPM cutover. relay reaches it at `http://apprise:8000` (same-name k8s DNS)

- [ ] **Step 1: `pvc.yaml`**

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: apprise
  namespace: workloads
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: local-path
  resources:
    requests:
      storage: 1Gi
```

- [ ] **Step 2: `deployment.yaml`**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: apprise
  namespace: workloads
  labels:
    app: apprise
spec:
  replicas: 1
  selector:
    matchLabels:
      app: apprise
  template:
    metadata:
      labels:
        app: apprise
    spec:
      enableServiceLinks: false
      containers:
        - name: apprise
          image: caronc/apprise:v1.5.1
          ports:
            - containerPort: 8000
          env:
            - name: TZ
              value: "Asia/Hong_Kong"
            - name: APPRISE_STATEFUL_MODE
              value: "simple"
            - name: APPRISE_WORKER_COUNT
              value: "1"
            - name: APPRISE_ADMIN
              value: "y"
          volumeMounts:
            - name: config
              mountPath: /config
          resources:
            requests:
              cpu: 200m
              memory: 192Mi
            limits:
              cpu: 300m
              memory: 384Mi
      volumes:
        - name: config
          persistentVolumeClaim:
            claimName: apprise
```

- [ ] **Step 3: `service.yaml`**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: apprise
  namespace: workloads
spec:
  type: NodePort
  selector:
    app: apprise
  ports:
    - port: 8000
      targetPort: 8000
      nodePort: 30085
```

- [ ] **Step 4: Verify the files exist**

```bash
ls vps_oracle/k3s/apps/apprise/k8s/
```

Expected: `pvc.yaml  deployment.yaml  service.yaml`

---

### Task 5: Write the ArgoCD child Applications (app-of-apps entries)

**Files:**
- Create: `vps_oracle/k3s/argocd/apps/vikunja.yaml`
- Create: `vps_oracle/k3s/argocd/apps/apprise.yaml`

**Interfaces:**
- Consumes: Task 3/4's manifest directories
- Produces: two Applications (ns `argocd`) — brought live by Task 9/10's `argocd app sync root`

- [ ] **Step 1: `argocd/apps/vikunja.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: vikunja
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/Jeromefromcn/docker-gitops.git
    targetRevision: main
    path: vps_oracle/k3s/apps/vikunja/k8s
  destination:
    server: https://kubernetes.default.svc
    namespace: workloads
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

- [ ] **Step 2: `argocd/apps/apprise.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: apprise
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/Jeromefromcn/docker-gitops.git
    targetRevision: main
    path: vps_oracle/k3s/apps/apprise/k8s
  destination:
    server: https://kubernetes.default.svc
    namespace: workloads
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

- [ ] **Step 3: Verify the files exist**

```bash
ls vps_oracle/k3s/argocd/apps/vikunja.yaml vps_oracle/k3s/argocd/apps/apprise.yaml
```

---

### Task 6: Stop the compose stacks + record a data baseline

**Files:**
- None (operates on the existing compose stacks: `vps_oracle/compose/vikunja/`, `vps_oracle/compose/apprise/`)

**Interfaces:**
- Consumes: the live compose containers (vikunja, vikunja-notify-relay, apprise)
- Produces: a stopped state + baseline data numbers (compared before/after Task 7/8's migration)

- [ ] **Step 1: Stop the vikunja stack and apprise (docker compose stop, not down, not removed)**

```bash
cd /home/ubuntu/jerome/docker-gitops/vps_oracle/compose/vikunja && docker compose stop
cd /home/ubuntu/jerome/docker-gitops/vps_oracle/compose/apprise && docker compose stop
```

- [ ] **Step 2: Wait ~10 seconds for sqlite's wal/shm to settle** (phase C lesson: file counts taken the instant a container stops are unreliable)

```bash
sleep 10
```

- [ ] **Step 3: Record the baseline**

```bash
echo "vikunja files: $(sudo find /etc/vikunja -type f | wc -l)"
echo "vikunja size:  $(sudo du -sh /etc/vikunja | cut -f1)"
echo "apprise size:  $(sudo du -sh /etc/apprise/config | cut -f1)"
```

Expected: one output line each (e.g. `vikunja files: 3`, `vikunja size: 4.8M`, `apprise size: 40K`). **Write down these three numbers** — they're compared against after Task 7/8's migration.

- [ ] **Step 4: Confirm all three containers are Exited and not removed**

```bash
docker ps -a --format '{{.Names}}\t{{.Status}}' | grep -E 'vikunja|apprise'
```

Expected: `vikunja Exited (...)`, `vikunja-notify-relay Exited (...)`, `apprise Exited (...)`.

---

### Task 7: Migrate vikunja's data into the PVC (trilium's six-step seed-pod pattern)

**Files:**
- Create: `vps_oracle/k3s/apps/vikunja/migration/seed-pod.yaml`
- Consumes: `vps_oracle/k3s/apps/vikunja/k8s/pvc.yaml` (Task 3)

**Interfaces:**
- Consumes: `/etc/vikunja` (stopped, at rest), PVC `vikunja`
- Produces: PVC `vikunja` populated with data (PV root contains `db/`, `files/` subdirectories, owner uid 1000) — claimed by the vikunja Deployment after Task 9's sync

- [ ] **Step 1: Write the seed-pod manifest**

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: vikunja-migration-seed
  namespace: workloads
  labels:
    app: vikunja-migration-seed
spec:
  restartPolicy: Never
  containers:
    - name: seed
      image: busybox:1.36
      command: ["sleep", "3600"]
      volumeMounts:
        - name: data
          mountPath: /data
      resources:
        requests:
          cpu: 50m
          memory: 32Mi
        limits:
          cpu: 100m
          memory: 64Mi
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: vikunja
```

- [ ] **Step 2: Apply the PVC + seed pod, wait for the PVC to bind** (`WaitForFirstConsumer`: the PVC only gets a host directory once a pod mounts it)

```bash
cd /home/ubuntu/jerome/docker-gitops
kubectl apply -f vps_oracle/k3s/apps/vikunja/k8s/pvc.yaml
kubectl apply -f vps_oracle/k3s/apps/vikunja/migration/seed-pod.yaml
kubectl -n workloads wait --for=jsonpath='{.status.phase}'=Bound pvc/vikunja --timeout=120s
```

Expected: `persistentvolumeclaim/vikunja condition met`.

- [ ] **Step 3: Get the PV's actual host directory**

```bash
kubectl -n workloads get pvc vikunja -o jsonpath='{.spec.volumeName}'
```

Note the PV name (looks like `pvc-xxxxxxxx`), then:

```bash
kubectl get pv <PV-name> -o jsonpath='{.spec.local.path}'
```

Expected: one host path line (looks like `/var/lib/rancher/k3s/storage/pvc-...`). **Don't use `spec.hostPath.path`** (local-path's field is `spec.local.path`).

- [ ] **Step 4: Copy the data + chown (source stays read-only, original directory untouched)**

```bash
sudo cp -a /etc/vikunja/. <PV-dir>/
sudo chown -R 1000:1000 <PV-dir>
```

(`cp -a` preserves ownership/timestamps; `chown 1000:1000` aligns with the vikunja container's uid 1000 — the directory the provisioner creates is owned by root.)

- [ ] **Step 5: Verify the file count/size matches the baseline**

```bash
echo "migrated vikunja files: $(sudo find <PV-dir> -type f | wc -l)"
sudo du -sh <PV-dir>
```

Expected: file count == the vikunja files baseline from Task 6 Step 3; size in the same ballpark (~4.8M).

- [ ] **Step 6: Tear down the seed pod (PVC stays, data stays in place)**

```bash
kubectl delete -f vps_oracle/k3s/apps/vikunja/migration/seed-pod.yaml
```

Expected: `pod "vikunja-migration-seed" deleted`.

- [ ] **Step 7: Commit the seed-pod manifest** (kept on file as a migration tool, consistent with trilium's `migration/` directory)

```bash
git add vps_oracle/k3s/apps/vikunja/migration/seed-pod.yaml
git commit -m "Add vikunja data-migration seed pod manifest"
```

(If this step is run by a subagent, whether to merge this commit with Task 9's is up to the review gate — the seed-pod is a migration tool, keeping it around is fine.)

---

### Task 8: Migrate apprise's /config into the PVC

**Files:**
- Create: `vps_oracle/k3s/apps/apprise/migration/seed-pod.yaml`

**Interfaces:**
- Consumes: `/etc/apprise/config` (40K, at rest), PVC `apprise`
- Produces: PVC `apprise` populated with data (PV root = the /config contents) — claimed by the apprise Deployment after Task 10's sync

- [ ] **Step 1: Write the seed-pod manifest (same pattern as Task 7, PVC swapped for `apprise`)**

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: apprise-migration-seed
  namespace: workloads
  labels:
    app: apprise-migration-seed
spec:
  restartPolicy: Never
  containers:
    - name: seed
      image: busybox:1.36
      command: ["sleep", "3600"]
      volumeMounts:
        - name: config
          mountPath: /data
      resources:
        requests:
          cpu: 50m
          memory: 32Mi
        limits:
          cpu: 100m
          memory: 64Mi
  volumes:
    - name: config
      persistentVolumeClaim:
        claimName: apprise
```

- [ ] **Step 2: Apply the PVC + seed pod, wait for Bound**

```bash
cd /home/ubuntu/jerome/docker-gitops
kubectl apply -f vps_oracle/k3s/apps/apprise/k8s/pvc.yaml
kubectl apply -f vps_oracle/k3s/apps/apprise/migration/seed-pod.yaml
kubectl -n workloads wait --for=jsonpath='{.status.phase}'=Bound pvc/apprise --timeout=120s
```

Expected: `persistentvolumeclaim/apprise condition met`.

- [ ] **Step 3: Get the PV directory and copy the data** (apprise runs as root, so ownership doesn't matter — plain `cp -a` is enough, no chown needed)

```bash
PVNAME=$(kubectl -n workloads get pvc apprise -o jsonpath='{.spec.volumeName}')
PVDIR=$(kubectl get pv "$PVNAME" -o jsonpath='{.spec.local.path}')
echo "PV dir: $PVDIR"
sudo cp -a /etc/apprise/config/. "$PVDIR"/
```

Expected: `PV dir: /var/lib/rancher/k3s/storage/pvc-...`, no error output from cp.

- [ ] **Step 4: Verify the size matches the baseline**

```bash
sudo du -sh <PV-dir>
```

Expected: matches Task 6's apprise baseline (~40K).

- [ ] **Step 5: Tear down the seed pod + commit**

```bash
kubectl delete -f vps_oracle/k3s/apps/apprise/migration/seed-pod.yaml
git add vps_oracle/k3s/apps/apprise/migration/seed-pod.yaml
git commit -m "Add apprise data-migration seed pod manifest"
```

---

### Task 9: Commit vikunja + relay and ArgoCD-sync, verify internally

**Files:**
- Commit: `vps_oracle/k3s/apps/vikunja/k8s/` (Task 3), `vps_oracle/k3s/argocd/apps/vikunja.yaml` (Task 5)

**Interfaces:**
- Consumes: Task 3/5's files, Task 1's relay image, Task 2's Secret, Task 7's populated PVC
- Produces: vikunja + relay running inside the cluster (NPM not yet cut over)

- [ ] **Step 1: Commit + push**

```bash
cd /home/ubuntu/jerome/docker-gitops
git add vps_oracle/k3s/apps/vikunja/k8s/ vps_oracle/k3s/argocd/apps/vikunja.yaml
git commit -m "Deploy vikunja + notify-relay to k3s via GitOps"
git push origin main
```

(Run `git status` before pushing to confirm nothing else got mixed in — this repo can have concurrent Claude sessions committing.)

- [ ] **Step 2: Trigger a root Application sync** (a new Application only gets created once `root` is synced)

```bash
argocd app sync root
```

(Or wait for ArgoCD's next poll cycle. After the sync, wait for both the `vikunja` and `apprise` Applications to appear.)

- [ ] **Step 3: Wait for the pods to come up and the PVC to bind**

```bash
kubectl -n workloads wait --for=condition=available deploy/vikunja --timeout=180s
kubectl -n workloads wait --for=condition=available deploy/vikunja-notify-relay --timeout=180s
kubectl get pvc -n workloads
```

Expected: both deployments available; PVC `vikunja` is `Bound`.

- [ ] **Step 4: Confirm ArgoCD status**

```bash
kubectl get applications -n argocd | grep -E 'vikunja|apprise'
```

Expected: `vikunja` appears and is `Synced`/`Healthy` (apprise may not appear yet — Task 10 commits it — vikunja being correct is enough here).

- [ ] **Step 5: Verify internal connectivity (before cutting over NPM, confirm it works inside the cluster first)**

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:30084
kubectl -n workloads logs deploy/vikunja-notify-relay --tail=20
```

Expected: vikunja returns `200` or `302` (login page/redirect); relay log is clean, no traceback (relay has no NodePort, so its log is how we confirm it started up cleanly).

---

### Task 10: Commit apprise and ArgoCD-sync, verify internally

**Files:**
- Commit: `vps_oracle/k3s/apps/apprise/k8s/` (Task 4), `vps_oracle/k3s/argocd/apps/apprise.yaml` (Task 5)

**Interfaces:**
- Consumes: Task 4/5's files, Task 8's populated PVC
- Produces: apprise running inside the cluster (NPM not yet cut over)

- [ ] **Step 1: Commit + push**

```bash
cd /home/ubuntu/jerome/docker-gitops
git add vps_oracle/k3s/apps/apprise/k8s/ vps_oracle/k3s/argocd/apps/apprise.yaml
git commit -m "Deploy apprise to k3s via GitOps"
git push origin main
```

- [ ] **Step 2: Wait for the apprise pod to come up, the PVC to bind**

```bash
kubectl -n workloads wait --for=condition=available deploy/apprise --timeout=180s
kubectl get pvc -n workloads
```

Expected: `apprise` deployment available; PVC `apprise` is `Bound`.

- [ ] **Step 3: ArgoCD status + internal connectivity**

```bash
kubectl get applications -n argocd | grep -E 'vikunja|apprise'
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:30085
```

Expected: both `Synced`/`Healthy`; apprise returns `200` (root path responds).

---

### Task 11: NPM cutover + external verification

**Files:**
- None (operates on NPM proxy host id 19 vikunja, id 20 apprise; NPM's admin port 81 is only exposed to the `proxy` network, not reachable from the host)

**Interfaces:**
- Consumes: `.npm-automation.env` (gitignored NPM API credentials), the two ready NodePorts
- Produces: the two NPM proxy hosts repointed to `10.0.0.95:30084/30085`, domain unchanged externally

- [ ] **Step 1: Write a one-off cutover script (run via `docker run --network proxy`, since the host can't reach `npm:81` directly)**

```bash
cd /home/ubuntu/jerome/docker-gitops
source vps_oracle/compose/npm/.npm-automation.env
cat > /tmp/npm-cutover-vikunja.py <<'EOF'
import json, os, urllib.request
BASE = "http://npm:81"
def req(path, method="GET", body=None, token=None):
    r = urllib.request.Request(BASE + path, method=method)
    r.add_header("Content-Type", "application/json")
    if token:
        r.add_header("Authorization", f"Bearer {token}")
    data = json.dumps(body).encode() if body is not None else None
    with urllib.request.urlopen(r, data=data) as resp:
        return json.loads(resp.read())
token = req("/api/tokens", "POST",
            {"identity": os.environ["NPM_AUTOMATION_EMAIL"],
             "secret": os.environ["NPM_AUTOMATION_PASSWORD"]})["token"]
for hid, node_port in [(19, 30084), (20, 30085)]:
    host = req(f"/api/nginx/proxy-hosts/{hid}", token=token)
    host["forward_host"] = "10.0.0.95"
    host["forward_port"] = node_port
    req(f"/api/nginx/proxy-hosts/{hid}", "PUT", host, token)
    print(f"proxy host {hid} -> 10.0.0.95:{node_port} (ssl_forced={host.get('ssl_forced')}, http2_support={host.get('http2_support')})")
EOF
docker run --rm --network proxy \
  -e NPM_AUTOMATION_EMAIL -e NPM_AUTOMATION_PASSWORD \
  -v /tmp/npm-cutover-vikunja.py:/work/cutover.py \
  python:3.12-alpine python /work/cutover.py
```

Expected: prints `proxy host 19 -> 10.0.0.95:30084 (...)` and `proxy host 20 -> 10.0.0.95:30085 (...)`, with `ssl_forced=true` and `http2_support=true` preserved (NPM has a known "the SSL toggle resets itself" bug — if it got reset, Step 3 below will catch it).

- [ ] **Step 2: Verify externally (domain unchanged, hit it from the server itself, whose public IP is already on the access list)**

```bash
curl -s -o /dev/null -w 'vikunja: %{http_code}\n' https://vikunja.jerome.cloudns.asia
curl -s -o /dev/null -w 'apprise: %{http_code}\n' https://apprise.jerome.cloudns.asia
```

Expected: both `200`/`302` (there's an access list, but the source is the server's own public IP, which is allowed).

- [ ] **Step 3: Confirm SSL wasn't reset by the PUT** (if it returns a 3xx redirect or 502, check that host's SSL toggle in the NPM UI)

```bash
curl -sv -o /dev/null https://vikunja.jerome.cloudns.asia 2>&1 | grep -E 'SSL connection|subject:'
```

Expected: `SSL connection using TLS...`, `subject: CN=...` (a normal handshake, not a certificate error).

---

### Task 12: End-to-end functional verification — the Telegram notification chain

**Files:**
- None (operates on the vikunja UI/API + reads k8s logs + checks the user's Telegram)

**Interfaces:**
- Consumes: the migrated vikunja + relay + apprise
- Produces: proof that the "vikunja → relay → apprise → Telegram" chain still works after migration

- [ ] **Step 1: Log into vikunja and create a task assigned to a user**

Open `https://vikunja.jerome.cloudns.asia` in a browser and log in, create a task assigned to a real user (e.g. jerome). The assignment action triggers the `task.assignee.created` webhook.

(Via the API instead: `POST /api/v1/login` first to get a token, then `POST /api/v1/projects/{id}/tasks` with `assignees: [user-ID]`. Credentials are held by the user — the plan doesn't assume them.)

- [ ] **Step 2: Confirm the user's Telegram received the notification**

Check the user's Telegram (the apprise target `vikunja-tg-{username}`) — it should receive a message in the "📌 Task assigned to you" format.

- [ ] **Step 3: Check the relay + apprise logs as supporting evidence**

```bash
kubectl -n workloads logs deploy/vikunja-notify-relay --tail=20
kubectl -n workloads logs deploy/apprise --tail=20
```

Expected: the relay log shows a POST record for receiving the vikunja webhook (200); the apprise log has no errors. If Telegram received the message but the log doesn't show it, trust what Telegram actually received.

- [ ] **Step 4: Confirm the old compose containers are still Exited, not removed (a rollback point)**

```bash
docker ps -a --format '{{.Names}}\t{{.Status}}' | grep -E 'vikunja|apprise'
```

Expected: all three are `Exited`, **not** `Removed` or `Up`.

---

### Task 13: Add a CI workflow for relay (so future changes are reproducible)

**Files:**
- Create: `.github/workflows/vikunja-notify-relay.yml`

**Interfaces:**
- Consumes: `vps_oracle/compose/vikunja/notify-relay/` (Dockerfile + app.py + test_app.py)
- Produces: on push, automatic build→test→Trivy→Cosign→push of `ghcr.io/jeromefromcn/vikunja-notify-relay:<sha>`; future deployment version bumps follow placeholder-hello's manual two-step (change the deployment.yaml image tag)

- [ ] **Step 1: Write the workflow** (based on `.github/workflows/placeholder-hello.yml`, with the context swapped to the relay directory, plus one added step to run the unit tests)

```yaml
name: vikunja-notify-relay

on:
  push:
    branches: [main]
    paths:
      - 'vps_oracle/compose/vikunja/notify-relay/**'
  workflow_dispatch: {}

permissions:
  contents: read
  packages: write
  id-token: write

env:
  IMAGE: ghcr.io/jeromefromcn/vikunja-notify-relay

jobs:
  test-build-scan-sign:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v7.0.1

      - name: Run unit tests
        run: |
          docker run --rm -v "$PWD/vps_oracle/compose/vikunja/notify-relay:/app" -w /app python:3.12-alpine sh -c "python -m unittest test_app -v"

      - name: Set up QEMU
        uses: docker/setup-qemu-action@v4.2.0
        with:
          platforms: arm64

      - name: Set up Buildx
        uses: docker/setup-buildx-action@v4.2.0

      - name: Log in to GHCR
        uses: docker/login-action@v4.6.0
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build and push
        id: build
        uses: docker/build-push-action@v7.3.0
        with:
          context: vps_oracle/compose/vikunja/notify-relay
          platforms: linux/arm64
          push: true
          tags: ${{ env.IMAGE }}:${{ github.sha }}

      - name: Scan image with Trivy
        uses: aquasecurity/trivy-action@v0.36.0
        env:
          TRIVY_PLATFORM: linux/arm64
        with:
          image-ref: ${{ env.IMAGE }}:${{ github.sha }}
          severity: CRITICAL
          exit-code: '1'
          ignore-unfixed: true

      - name: Install Cosign
        uses: sigstore/cosign-installer@v4.1.2

      - name: Sign image (keyless)
        env:
          IMAGE_REF: ${{ env.IMAGE }}@${{ steps.build.outputs.digest }}
        run: cosign sign --yes "$IMAGE_REF"
```

- [ ] **Step 2: Verify the YAML parses**

```bash
python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/vikunja-notify-relay.yml')); print('valid')"
```

Expected: `valid`.

- [ ] **Step 3: Commit + push**

```bash
cd /home/ubuntu/jerome/docker-gitops
git add .github/workflows/vikunja-notify-relay.yml
git commit -m "Add CI for vikunja-notify-relay image (build, test, scan, sign, push)"
git push origin main
```

Expected: this commit does not trigger the workflow (the path filter only matches the relay directory), but `workflow_dispatch` can run it manually on GitHub. **This plan's migration is already complete and does not depend on this CI run** — next time the relay code changes, it will auto-build a new `:<sha>`, at which point follow placeholder-hello's manual two-step to point the deployment's image tag at it.

---

## Self-Review Notes

- **Spec coverage:** the three vikunja-stack pieces (vikunja+relay+apprise) → Task 3/4; sqlite moved as-is + PVC migration → Task 7; relay pushed to GHCR + CI → Task 1/13; Secret created manually out-of-band → Task 2; NPM cutover (incl. SSL-reset check) → Task 11; webhook URL carried over (same Service name) → Task 9 Step 5 + Task 12; `enableServiceLinks: false` on every pod → Global Constraints + Task 3/4 manifests; quota untouched → Global Constraints. 3x-ui stays as-is; dify/llm each get their own separate plan (see "Follow-ups").
- **Placeholder scan:** no TBD/TODO; every code/manifest/command is real content.
- **Type consistency:** Service names `vikunja`/`vikunja-notify-relay`/`apprise` are consistent across tasks; secret key `VIKUNJA_SERVICE_SECRET` is consistent across Task 2/3; NodePort 30084/30085 is consistent across Task 3/4/9/10/11; PV directory lookup uniformly uses `spec.local.path`.

## Follow-ups (out of scope for this plan)

- **dify migration plan** (9 containers → `dify` ns, incl. StatefulSet + SSRF NetworkPolicy + 8 NPM location cutovers + 5 secrets)
- **llm stack migration plan** (3 containers → `llm` ns, incl. 3C/9G quota + models/data PVC)
- **3x-ui**: not migrated (the spec already records it as staying on compose)
- **phase E**: Sealed Secrets takes over Task 2's out-of-band Secret
