# K3s Phase C — Migration Template + First Services Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate `homepage` and `trilium` off `docker compose` and onto the phase B GitOps loop, proving two reusable templates in the process — a config-as-code stateless service (homepage) and a service with real persistent data (trilium, via a standard dynamically-provisioned PVC) — with zero change to their external domains.

**Architecture:** Both services get a `k8s/` manifest set under `vps_oracle/k3s/apps/<service>/`, deployed as their own ArgoCD child Application under the existing app-of-apps `root`. Each gets a fixed NodePort Service; NPM's existing proxy host for that domain gets repointed from the compose container to the NodePort, so the domain never changes. `homepage`'s git-tracked config becomes a ConfigMap, copied by an initContainer into a writable `emptyDir` (so homepage can still write its own log file — a ConfigMap volume alone is read-only). `trilium`'s real notes data gets migrated once, by hand, into a `local-path`-provisioned PVC before its Deployment ever starts, using a disposable seed Pod to trigger provisioning (the StorageClass is `WaitForFirstConsumer`, so the PV's host directory doesn't exist until something mounts the PVC).

**Tech Stack:** k3s, ArgoCD (existing app-of-apps), `local-path` StorageClass, Nginx Proxy Manager (existing), `rsync`, `kubectl`

**Reference spec:** [docs/superpowers/specs/2026-08-09-k3s-phase-c-migration-template-design.md](../specs/2026-08-09-k3s-phase-c-migration-template-design.md)

## Global Constraints

- Image tags pinned to what compose already runs, unchanged: `ghcr.io/gethomepage/homepage:v1.13.2`, `triliumnext/trilium:v0.104.1`. No version bump during migration — isolates any problem to the platform change, not a version change.
- No CI/Trivy pipeline for either service — both are third-party images with no Dockerfile in this repo to build. Same treatment as Cilium/ArgoCD's chart images in phases A/B: pin the tag in the manifest, let ArgoCD deploy it.
- `trilium`'s container must NOT set `securityContext.runAsUser` (or any pod-level `runAsUser`). The image's entrypoint starts as root and self-drops privileges to uid 1000 via `su`; forcing a different startup UID breaks that `su` call. This is a deliberate exception — do not attempt to fix it in this phase, it's phase E's Kyverno/Pod-Security-Standard problem (documented in the spec's "已知限制").
- `trilium` storage is a standard dynamically-provisioned `PersistentVolumeClaim` against the `local-path` StorageClass (5Gi) — not a hostPath shortcut, per explicit design decision.
- Fixed NodePorts: `homepage` → `30081`, `trilium` → `30082`. Confirmed unused as of this plan's writing (only `30090` is taken, by `argocd-server-nodeport`) — re-check with `kubectl get svc -A -o jsonpath='{range .items[*]}{.spec.ports[*].nodePort}{"\n"}{end}'` before applying either Service, in case something else claimed them since.
- Resource requests/limits: `homepage` → `requests: {cpu: 100m, memory: 192Mi}`, `limits: {cpu: 300m, memory: 384Mi}`; `trilium` → `requests: {cpu: 100m, memory: 320Mi}`, `limits: {cpu: 500m, memory: 640Mi}`. Sized off real `docker stats` usage (110MiB / 246MiB) with headroom.
- Every new Application (`homepage`, `trilium`) runs `syncPolicy.automated.prune: true` / `selfHeal: true`, same as every existing Application.
- **Never cut NPM over to a NodePort before verifying the service internally first** (`curl http://localhost:<nodeport>` from the host). This is the roadmap's migration principle 3, not optional.
- Old compose containers get `docker compose stop`, never `down` or removal of their data/volumes, once the k8s version is verified live. They stay stopped as a rollback point — final decommission is a phase H decision, not this phase's.
- `workloads` ResourceQuota (`requests.cpu: 1`, `requests.memory: 2Gi`, `limits.cpu: 1`, `limits.memory: 2Gi`) is NOT raised in this phase — both new services fit inside it alongside the existing `placeholder-hello`. Task 6 records the resulting headroom for phase D.
- NPM's Forward Hostname/IP for a NodePort target must be the host's literal internal IP, never a hostname (known gotcha, root README) — re-verify the current IP with `ip -4 addr show enp0s6` at cutover time, it's DHCP-assigned and can drift.

---

## File Structure

```
vps_oracle/k3s/
  README.md                              # modified: homepage/trilium sections, quota headroom note
  argocd/apps/
    homepage.yaml                         # new child Application
    trilium.yaml                          # new child Application
  apps/
    homepage/
      k8s/
        configmap.yaml                     # homepage-config: settings/widgets/services/bookmarks/custom.css/.js
        deployment.yaml                     # initContainer copies ConfigMap -> emptyDir -> /app/config
        service.yaml                        # NodePort 30081
    trilium/
      k8s/
        pvc.yaml                           # local-path, 5Gi
        deployment.yaml
        service.yaml                        # NodePort 30082
      migration/
        seed-pod.yaml                       # one-off tool: mounts the PVC to trigger provisioning

vps_oracle/compose/
  homepage/                                # untouched — stays as rollback path
  trilium/                                 # untouched — stays as rollback path
```

---

### Task 1: Deploy `homepage` to k8s and verify internally

**Files:**
- Create: `vps_oracle/k3s/apps/homepage/k8s/configmap.yaml`
- Create: `vps_oracle/k3s/apps/homepage/k8s/deployment.yaml`
- Create: `vps_oracle/k3s/apps/homepage/k8s/service.yaml`
- Create: `vps_oracle/k3s/argocd/apps/homepage.yaml`

**Interfaces:**
- Consumes: `root` Application (existing, watches `vps_oracle/k3s/argocd/apps/`); `workloads` namespace/quota (existing, phase A/B).
- Produces: a running, GitOps-managed `homepage` Deployment reachable at `http://localhost:30081` on the host. Task 2 depends on this being verified healthy before touching NPM.

- [ ] **Step 1: Write the ConfigMap carrying homepage's config**

Create `vps_oracle/k3s/apps/homepage/k8s/configmap.yaml`. This is the same content as `vps_oracle/compose/homepage/config/*.yaml` today, with two changes: the `docker.yaml` provider file is dropped entirely (no `docker.sock` in k8s), and every service card in `services.yaml` loses its `container:`/`server:` keys (those depended on the dropped docker provider — the per-card status indicator goes away, the card itself doesn't).

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: homepage-config
  namespace: workloads
data:
  settings.yaml: |
    title: Jerome's Homelab
    theme: dark
    color: sky
    headerStyle: clean
    cardBlur: sm
    hideVersion: true

    quicklaunch:
      provider: duckduckgo
      searchDescriptions: true
      showSearchSuggestions: true
      hideInternetSearch: false

    layout:
      Infra Services:
        style: row
        columns: 3
      Apps:
        style: row
        columns: 3
  widgets.yaml: |
    - search:
        provider: duckduckgo
        target: _blank

    - resources:
        cpu: true
        memory: true
        disk: /

    - datetime:
        text_size: xl
        format:
          dateStyle: short
          timeStyle: short
  bookmarks.yaml: |
    []
  custom.css: |
    html {
      font-size: 137.5%; /* scales all rem-based text site-wide, ~22px base instead of 16px */
    }

    body {
      background-color: #08090d;
      background-image:
        radial-gradient(at 15% 20%, rgba(56, 189, 248, 0.28) 0px, transparent 50%),
        radial-gradient(at 85% 15%, rgba(168, 85, 247, 0.24) 0px, transparent 50%),
        radial-gradient(at 50% 90%, rgba(236, 72, 153, 0.16) 0px, transparent 50%);
      background-attachment: fixed;
    }
  custom.js: ""
  services.yaml: |
    - Infra Services:
        - Nginx Proxy Manager:
            icon: nginx-proxy-manager.png
            href: https://npm.jerome.cloudns.asia
            description: Reverse proxy / SSL management

        - Portainer:
            icon: portainer.png
            href: https://portainer.jerome.cloudns.asia
            description: Docker management

        - Grafana:
            icon: grafana.png
            href: https://grafana.jerome.cloudns.asia/d/rYdddlPWk/node-exporter-full?orgId=1&from=now-24h&to=now&timezone=browser&var-job=node&var-nodename=node-exporter&var-node=node-exporter:9100&refresh=1m
            description: Monitoring dashboard

    - Apps:
        - Trilium:
            icon: trilium.png
            href: https://trilium.jerome.cloudns.asia
            description: Notes

        - Vikunja:
            icon: vikunja.png
            href: https://vikunja.jerome.cloudns.asia
            description: Task management

        - Apprise:
            icon: apprise.png
            href: https://apprise.jerome.cloudns.asia
            description: Notification forwarding

        - Open WebUI:
            icon: open-webui.png
            href: https://ollama.jerome.cloudns.asia
            description: LLM chat (llama.cpp)

        - SillyTavern:
            icon: sillytavern.png
            href: https://sillytavern.jerome.cloudns.asia
            description: Roleplay / character chat frontend (llama.cpp)

        - Dify:
            icon: si-dify
            href: https://dify.jerome.cloudns.asia
            description: LLM app builder (chat / workflow / agent)
```

- [ ] **Step 2: Write the Deployment**

Create `vps_oracle/k3s/apps/homepage/k8s/deployment.yaml`. The `seed-config` initContainer copies the read-only ConfigMap volume into a writable `emptyDir`, because homepage writes its own request log into the config directory at runtime and a ConfigMap-backed mount can't be written to.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: homepage
  namespace: workloads
  labels:
    app: homepage
spec:
  replicas: 1
  selector:
    matchLabels:
      app: homepage
  template:
    metadata:
      labels:
        app: homepage
    spec:
      initContainers:
        - name: seed-config
          image: busybox:1.36
          command: ["sh", "-c", "cp -r /config-src/. /config/"]
          volumeMounts:
            - name: config-src
              mountPath: /config-src
              readOnly: true
            - name: config
              mountPath: /config
      containers:
        - name: homepage
          image: ghcr.io/gethomepage/homepage:v1.13.2
          env:
            - name: TZ
              value: "Asia/Hong_Kong"
            - name: HOMEPAGE_ALLOWED_HOSTS
              value: "homepage.jerome.cloudns.asia"
          ports:
            - containerPort: 3000
          volumeMounts:
            - name: config
              mountPath: /app/config
          resources:
            requests:
              cpu: 100m
              memory: 192Mi
            limits:
              cpu: 300m
              memory: 384Mi
      volumes:
        - name: config-src
          configMap:
            name: homepage-config
        - name: config
          emptyDir: {}
```

- [ ] **Step 3: Write the Service**

Create `vps_oracle/k3s/apps/homepage/k8s/service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: homepage
  namespace: workloads
spec:
  type: NodePort
  selector:
    app: homepage
  ports:
    - port: 3000
      targetPort: 3000
      nodePort: 30081
```

- [ ] **Step 4: Confirm NodePort 30081 is still free**

```bash
kubectl get svc -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} {.spec.ports[*].nodePort}{"\n"}{end}' | grep -v '^[^ ]* $'
```

Expected: only `argocd/argocd-server-nodeport ... 30090` (or whatever else has been added since) — nothing claims `30081`. If something does, pick a different free NodePort and use it consistently in Step 3 above and everywhere below.

- [ ] **Step 5: Write the ArgoCD Application**

Create `vps_oracle/k3s/argocd/apps/homepage.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: homepage
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/Jeromefromcn/docker-gitops.git
    targetRevision: main
    path: vps_oracle/k3s/apps/homepage/k8s
  destination:
    server: https://kubernetes.default.svc
    namespace: workloads
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

- [ ] **Step 6: Commit, push, and force a sync**

```bash
git add vps_oracle/k3s/apps/homepage vps_oracle/k3s/argocd/apps/homepage.yaml
git commit -m "Deploy homepage to k3s via GitOps"
git push
```

```bash
argocd login --core
kubectl config set-context --current --namespace=argocd
argocd app sync root
```

- [ ] **Step 7: Verify the Application and pod are healthy**

```bash
kubectl -n argocd get application homepage
kubectl -n workloads get pods -l app=homepage
```

Expected: `homepage` Application shows `Synced`/`Healthy`; the pod is `Running` with `READY 1/1` (the `seed-config` initContainer runs to completion before the main container starts — `kubectl get pods`'s `READY` column only counts the main container, so `1/1` is correct once it's up, not `2/2`).

- [ ] **Step 8: Verify internally — do NOT touch NPM yet**

```bash
curl -s http://localhost:30081 | grep -o '<title>[^<]*</title>'
```

Expected: prints a `<title>` tag (homepage's default title, e.g. `<title>Homepage</title>` — the ConfigMap's `settings.yaml` sets the dashboard heading, not the HTML `<title>`). A connection error or empty output means the pod isn't actually serving — check `kubectl -n workloads logs deployment/homepage` before proceeding.

- [ ] **Step 9: Commit is already done in Step 6 — no further commit needed here**

(This step intentionally left as a checkpoint, not an action — Task 2 starts the NPM cutover.)

---

### Task 2: Cut NPM over to k8s `homepage` and decommission the compose container

**Files:**
- Modify: `vps_oracle/k3s/README.md` (new "homepage" section)

**Interfaces:**
- Consumes: the verified-healthy `homepage` NodePort Service from Task 1.
- Produces: `homepage.jerome.cloudns.asia` served entirely from k8s; the compose `homepage` container stopped (not removed).

- [ ] **Step 1: Get the current host IP**

```bash
ip -4 addr show enp0s6 | grep -oP 'inet \K[\d.]+'
```

Expected: an IP in `10.0.0.0/24` (documented as `10.0.0.95` as of phase A/B, but DHCP — use whatever this prints).

- [ ] **Step 2: Edit the existing NPM proxy host for homepage**

In the NPM web UI (`https://npm.jerome.cloudns.asia`), open the existing `homepage.jerome.cloudns.asia` proxy host, Details tab:
- Forward Hostname / IP: change from `homepage` to the IP from Step 1
- Forward Port: change from `3000` to `30081`

Leave every other field (SSL, Access List, Websockets) untouched — only the forward target changes. Save. Per the root README's known gotcha, reopen the entry after saving and confirm Force SSL / HTTP/2 Support are still on (they sometimes silently reset).

- [ ] **Step 3: Verify externally**

```bash
curl -s https://homepage.jerome.cloudns.asia | grep -o '<title>[^<]*</title>'
```

Expected: same result as Task 1 Step 8's internal curl. Then open `https://homepage.jerome.cloudns.asia` in a browser and confirm the cards render and are clickable (the automated curl only proves the page loads, not that the dashboard config parsed correctly).

- [ ] **Step 4: Stop the compose container**

```bash
cd vps_oracle/compose/homepage
docker compose stop
cd -
docker ps -a --filter name=homepage --format '{{.Names}}\t{{.Status}}'
```

Expected: `homepage` shows `Exited`. Do not `docker compose down` and do not delete `vps_oracle/compose/homepage/config/` — this stays as the rollback path until phase H decides otherwise.

- [ ] **Step 5: Document it in the k3s README**

Edit `vps_oracle/k3s/README.md`, add a new section after the existing "Namespace & quota" section:

```markdown
## homepage

Migrated from `vps_oracle/compose/homepage` in phase C. Config (`settings.yaml`/`widgets.yaml`/`services.yaml`/`bookmarks.yaml`/`custom.css`/`custom.js`) lives in `apps/homepage/k8s/configmap.yaml` — still git-versioned, just delivered as a ConfigMap instead of a bind mount. An initContainer copies it into a writable `emptyDir` at `/app/config` because homepage writes its own request log there and a ConfigMap volume is read-only.

The docker-container-status widget (`config/docker.yaml`, and each service card's `container`/`server` keys) was dropped — it depended on a read-only `/var/run/docker.sock` mount with no k8s equivalent worth the RBAC to replace it. The global `resources`/`search`/`datetime` widgets are unaffected.

Exposed via NodePort `30081` → NPM (`homepage.jerome.cloudns.asia`), same domain as before. The old compose container (`vps_oracle/compose/homepage`) is stopped, not removed — kept as a rollback path per the roadmap's migration principles.
```

- [ ] **Step 6: Commit**

```bash
git add vps_oracle/k3s/README.md
git commit -m "Cut homepage over to k3s, stop the compose container"
```

---

### Task 3: Migrate trilium's data into a PVC

**Files:**
- Create: `vps_oracle/k3s/apps/trilium/k8s/pvc.yaml`
- Create: `vps_oracle/k3s/apps/trilium/migration/seed-pod.yaml`

**Interfaces:**
- Consumes: `/etc/trilium/data` on the host (compose bind mount, stopped for the duration of this task); `local-path` StorageClass (existing, phase A).
- Produces: a `Bound` PVC named `trilium` in `workloads`, containing a verified-complete copy of the notes data. Task 4 deploys the real Deployment against this same PVC.

- [ ] **Step 1: Record the pre-migration baseline**

```bash
find /etc/trilium/data -type f | wc -l
du -sh /etc/trilium/data
```

Write down both numbers (file count and total size) — Step 6 below compares against them. Do not proceed past this step without having them recorded somewhere you'll actually look at again.

- [ ] **Step 2: Stop the compose container (no writes during migration)**

```bash
cd vps_oracle/compose/trilium
docker compose stop
cd -
docker ps -a --filter name=trilium --format '{{.Names}}\t{{.Status}}'
```

Expected: `trilium` shows `Exited`.

- [ ] **Step 3: Write the PVC**

Create `vps_oracle/k3s/apps/trilium/k8s/pvc.yaml`:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: trilium
  namespace: workloads
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: local-path
  resources:
    requests:
      storage: 5Gi
```

- [ ] **Step 4: Write the disposable seed Pod**

Create `vps_oracle/k3s/apps/trilium/migration/seed-pod.yaml`. This is a one-off tool, not part of the GitOps-managed app — it exists only to make the `WaitForFirstConsumer` StorageClass actually provision the PV's host directory before the real Deployment exists.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: trilium-migration-seed
  namespace: workloads
  labels:
    app: trilium-migration-seed
spec:
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
        claimName: trilium
```

- [ ] **Step 5: Apply both and wait for the PVC to bind**

```bash
kubectl apply -f vps_oracle/k3s/apps/trilium/k8s/pvc.yaml
kubectl apply -f vps_oracle/k3s/apps/trilium/migration/seed-pod.yaml
kubectl -n workloads wait --for=condition=Ready pod/trilium-migration-seed --timeout=60s
kubectl -n workloads get pvc trilium
```

Expected: `trilium-migration-seed` becomes `Ready`; `kubectl get pvc trilium` shows `STATUS: Bound`.

- [ ] **Step 6: Find the PV's host directory, copy the data in, verify it matches the baseline**

```bash
PV_NAME=$(kubectl -n workloads get pvc trilium -o jsonpath='{.spec.volumeName}')
HOST_PATH=$(kubectl get pv "$PV_NAME" -o jsonpath='{.spec.hostPath.path}')
echo "$HOST_PATH"

sudo rsync -a /etc/trilium/data/ "$HOST_PATH/"
sudo chown -R 1000:1000 "$HOST_PATH"

sudo find "$HOST_PATH" -type f | wc -l
sudo du -sh "$HOST_PATH"
```

Expected: `$HOST_PATH` prints a path under `/var/lib/rancher/k3s/storage/`; the file count and size from the last two commands match Step 1's baseline exactly. The `chown` is necessary — `local-path-provisioner` creates the directory owned by root, but trilium's process runs as uid 1000 (see Global Constraints) and needs to own its data.

If the counts don't match, do not proceed to Task 4 — re-run the `rsync` (it's idempotent) and re-check before touching anything else.

- [ ] **Step 7: Delete the seed Pod (keep the PVC)**

```bash
kubectl delete -f vps_oracle/k3s/apps/trilium/migration/seed-pod.yaml
kubectl -n workloads get pvc trilium
```

Expected: pod gone; PVC still `Bound` — deleting the pod that mounted it doesn't affect the underlying data.

- [ ] **Step 8: Commit**

```bash
git add vps_oracle/k3s/apps/trilium/k8s/pvc.yaml vps_oracle/k3s/apps/trilium/migration/seed-pod.yaml
git commit -m "Migrate trilium data into a local-path PVC"
```

Note: the PVC is not yet GitOps-managed — no Application watches `apps/trilium/k8s/` until Task 4. Committing it now just means the file exists in git matching what's already live in the cluster, so Task 4's Application sync adopts it in place instead of trying to recreate it.

---

### Task 4: Deploy `trilium` to k8s and verify internally

**Files:**
- Create: `vps_oracle/k3s/apps/trilium/k8s/deployment.yaml`
- Create: `vps_oracle/k3s/apps/trilium/k8s/service.yaml`
- Create: `vps_oracle/k3s/argocd/apps/trilium.yaml`

**Interfaces:**
- Consumes: the `Bound`, populated `trilium` PVC from Task 3; `root` Application (existing).
- Produces: a running, GitOps-managed `trilium` Deployment serving the migrated notes at `http://localhost:30082`. Task 5 depends on this being verified healthy before touching NPM.

- [ ] **Step 1: Write the Deployment**

Create `vps_oracle/k3s/apps/trilium/k8s/deployment.yaml`. No `securityContext`/`runAsUser` — see Global Constraints.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: trilium
  namespace: workloads
  labels:
    app: trilium
spec:
  replicas: 1
  selector:
    matchLabels:
      app: trilium
  template:
    metadata:
      labels:
        app: trilium
    spec:
      containers:
        - name: trilium
          image: triliumnext/trilium:v0.104.1
          env:
            - name: TZ
              value: "Asia/Hong_Kong"
          ports:
            - containerPort: 8080
          volumeMounts:
            - name: data
              mountPath: /home/node/trilium-data
          resources:
            requests:
              cpu: 100m
              memory: 320Mi
            limits:
              cpu: 500m
              memory: 640Mi
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: trilium
```

- [ ] **Step 2: Write the Service**

Create `vps_oracle/k3s/apps/trilium/k8s/service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: trilium
  namespace: workloads
spec:
  type: NodePort
  selector:
    app: trilium
  ports:
    - port: 8080
      targetPort: 8080
      nodePort: 30082
```

- [ ] **Step 3: Confirm NodePort 30082 is still free**

```bash
kubectl get svc -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} {.spec.ports[*].nodePort}{"\n"}{end}' | grep -v '^[^ ]* $'
```

Expected: `30081` (homepage, from Task 1) and `30090` (argocd) are the only ones taken — nothing claims `30082`.

- [ ] **Step 4: Write the ArgoCD Application**

Create `vps_oracle/k3s/argocd/apps/trilium.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: trilium
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/Jeromefromcn/docker-gitops.git
    targetRevision: main
    path: vps_oracle/k3s/apps/trilium/k8s
  destination:
    server: https://kubernetes.default.svc
    namespace: workloads
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

- [ ] **Step 5: Commit, push, and force a sync**

```bash
git add vps_oracle/k3s/apps/trilium/k8s vps_oracle/k3s/argocd/apps/trilium.yaml
git commit -m "Deploy trilium to k3s via GitOps, mounting the migrated PVC"
git push
```

```bash
argocd login --core
kubectl config set-context --current --namespace=argocd
argocd app sync root
```

- [ ] **Step 6: Verify the Application adopted the existing PVC correctly**

```bash
kubectl -n argocd get application trilium
kubectl -n workloads get pvc trilium
kubectl -n workloads get pods -l app=trilium
```

Expected: `trilium` Application `Synced`/`Healthy`; PVC still shows the same `Bound` status and volume from Task 3 (not a newly created one — check `kubectl -n workloads get pvc trilium -o jsonpath='{.spec.volumeName}'` matches the `$PV_NAME` recorded in Task 3 Step 6, if you still have it); pod `Running`.

- [ ] **Step 7: Verify the migrated data is actually there and readable**

```bash
kubectl -n workloads exec deployment/trilium -- ls /home/node/trilium-data
```

Expected: shows `config.ini`, `backup/`, and the rest of what was in `/etc/trilium/data` — not an empty directory (an empty directory here means the Deployment is reading a different PVC than the one Task 3 populated).

- [ ] **Step 8: Verify internally — do NOT touch NPM yet**

```bash
curl -s http://localhost:30082 | grep -o '<title>[^<]*</title>'
```

Expected: prints trilium's login page title. Then, from a browser via SSH tunnel or similar, actually log in and confirm existing notes are visible — the file listing in Step 7 proves the files copied, not that the application can read them.

---

### Task 5: Cut NPM over to k8s `trilium` and decommission the compose container

**Files:**
- Modify: `vps_oracle/k3s/README.md` (new "trilium" section)

**Interfaces:**
- Consumes: the verified-healthy `trilium` NodePort Service and confirmed-readable data from Task 4.
- Produces: `trilium.jerome.cloudns.asia` served entirely from k8s; the compose `trilium` container stopped (not removed, already stopped since Task 3).

- [ ] **Step 1: Get the current host IP (re-check, don't assume Task 2's value is still current)**

```bash
ip -4 addr show enp0s6 | grep -oP 'inet \K[\d.]+'
```

- [ ] **Step 2: Edit the existing NPM proxy host for trilium**

In the NPM web UI, open the existing `trilium.jerome.cloudns.asia` proxy host, Details tab:
- Forward Hostname / IP: change from `trilium` to the IP from Step 1
- Forward Port: change from `8080` to `30082`

Save, then reopen and confirm Force SSL / HTTP/2 Support are still on (known NPM gotcha).

- [ ] **Step 3: Verify externally**

```bash
curl -s https://trilium.jerome.cloudns.asia | grep -o '<title>[^<]*</title>'
```

Then open `https://trilium.jerome.cloudns.asia` in a browser, log in, and confirm the existing notes are all there and editable.

- [ ] **Step 4: Confirm the compose container is still stopped, not removed**

```bash
docker ps -a --filter name=trilium --format '{{.Names}}\t{{.Status}}'
```

Expected: `Exited` (stopped back in Task 3 Step 2, never restarted).

- [ ] **Step 5: Document it in the k3s README**

Edit `vps_oracle/k3s/README.md`, add a new section after the "homepage" section from Task 2:

```markdown
## trilium

Migrated from `vps_oracle/compose/trilium` in phase C. Unlike homepage, trilium holds real user data (notes), so this wasn't a config-only swap — the migration procedure was:

1. Stop the compose container (no writes during migration).
2. Apply `apps/trilium/k8s/pvc.yaml` plus a disposable seed Pod (`apps/trilium/migration/seed-pod.yaml`) that mounts the same PVC — needed because the `local-path` StorageClass is `WaitForFirstConsumer`, so the PV's host directory doesn't get created until something actually mounts the PVC.
3. `rsync` the old `/etc/trilium/data` into the PV's host directory (found via `kubectl get pv <name> -o jsonpath='{.spec.hostPath.path}'`), then `chown` it to uid 1000 (the PV directory is created root-owned; trilium's process runs as uid 1000).
4. Delete the seed Pod, commit the PVC, then deploy the real Application — ArgoCD adopts the already-populated PVC instead of creating an empty one.

The container intentionally has no `securityContext.runAsUser` — the image's entrypoint starts as root and self-drops to uid 1000 via `su`, and forcing a different startup UID breaks that.

Exposed via NodePort `30082` → NPM (`trilium.jerome.cloudns.asia`), same domain as before. The old compose container is stopped, not removed.

**Known limitation:** there is no backup mechanism for this data beyond the original `/etc/trilium/data` on the host (pre-existing gap, not introduced by this migration). The PVC's `local-path` StorageClass has `reclaimPolicy: Delete` — removing `pvc.yaml` from git and letting ArgoCD prune it deletes the underlying data directory too. The original `/etc/trilium/data` is untouched by the migration (rsync only reads from it) so it's a recovery path today, but that stops being true whenever phase H decides to clean up decommissioned compose data.
```

- [ ] **Step 6: Commit**

```bash
git add vps_oracle/k3s/README.md
git commit -m "Cut trilium over to k3s, document the data migration procedure"
```

---

### Task 6: Self-heal proof, quota headroom check, and phase C wrap-up

**Files:**
- Modify: `vps_oracle/k3s/README.md` (quota headroom note, update "Handoff to phase D" section)

**Interfaces:**
- Consumes: both migrated services live in the cluster from Tasks 1–5.
- Produces: recorded proof phase C's acceptance criteria hold, and the exact pre-condition phase D needs to check before it starts.

- [ ] **Step 1: Self-heal proof — break `homepage`, confirm ArgoCD fixes it**

Use `homepage`, not `trilium` — no reason to put the stateful service through a disruptive test that phase B already proved the mechanism for.

```bash
kubectl -n workloads scale deployment homepage --replicas=0
sleep 30
kubectl -n workloads get deployment homepage
```

Expected: `replicas: 0` shows briefly, but within the `sleep 30` window ArgoCD's `selfHeal` restores it — the final `get deployment` shows `1/1` ready again, without anyone running `kubectl scale` back up.

- [ ] **Step 2: Check ResourceQuota headroom**

```bash
kubectl describe resourcequota workloads-quota -n workloads
```

Expected: `Used` now reflects `placeholder-hello` + `homepage` + `trilium` combined — roughly `requests.cpu: 250m/1`, `requests.memory: 576Mi/2Gi`, `limits.cpu: 900m/1`, `limits.memory: 1152Mi/2Gi` (exact numbers will differ slightly, that's fine). The important number is `limits.cpu` headroom — if it's under ~150m remaining, phase D cannot deploy even one more small service without a quota bump first.

- [ ] **Step 3: Record the headroom finding and update the phase handoff in the README**

Edit `vps_oracle/k3s/README.md`, find the "Handoff to phase C" section (added in phase B) and replace it with:

```markdown
## Handoff to phase D

Phase C (homepage + trilium migrated) leaves phase D two reusable templates: `apps/homepage/` (config-as-code via ConfigMap + initContainer→emptyDir, for services that don't hold real data) and `apps/trilium/` (dynamically-provisioned PVC + one-off seed-Pod data migration, for services that do). Both follow the same shape: manifests under `apps/<service>/k8s/`, one child Application under `argocd/apps/`, a fixed NodePort, and an NPM proxy host repointed from the compose container to that NodePort — domain unchanged throughout.

**Before starting phase D:** the `workloads` ResourceQuota is close to its `limits.cpu` cap (`<actual number from Task 6 Step 2>`m used of `1` — see phase C's verification). Raise it before deploying the next service, not after hitting the wall.

Phase D's services introduce problems phase C deliberately didn't cover: multi-container stacks with inter-service dependencies (dify), database services where StatefulSet-vs-Deployment actually matters (vikunja+pg), the llm stack's much larger CPU/memory footprint, and 3x-ui's raw TCP passthrough on `39876` (can't go through an HTTP reverse proxy at all — see the roadmap's 現狀約束).
```

Replace `<actual number from Task 6 Step 2>` with the real `limits.cpu` used value from Step 2.

- [ ] **Step 4: Commit**

```bash
git add vps_oracle/k3s/README.md
git commit -m "Record phase C self-heal proof and quota headroom for phase D"
```

- [ ] **Step 5: Final phase C checklist — confirm every item from the design doc's 驗證清單**

```bash
kubectl -n argocd get applications
kubectl -n workloads get pods
kubectl -n workloads get pvc trilium
docker ps -a --filter name=homepage --filter name=trilium --format '{{.Names}}\t{{.Status}}'
```

Expected, all together: `homepage` and `trilium` Applications `Synced`/`Healthy` alongside the pre-existing `argocd`/`phase-a-foundation`/`placeholder-hello`; both pods `Running`; PVC `Bound`; both compose containers `Exited`. This is phase C done.
