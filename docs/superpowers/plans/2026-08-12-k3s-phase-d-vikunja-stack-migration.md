# K3s Phase D — Vikunja 棧遷移 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 vikunja（sqlite + 資料）+ vikunja-notify-relay + apprise 從 docker compose 遷進 k3s `workloads` 命名空間，域名/端口對外不變，Telegram 通知鏈路（vikunja → relay → apprise → Telegram）遷後照常運作。

**Architecture:** 沿用 phase C 的 NPM→NodePort 橋接模式。vikunja 的 sqlite db + files 搬進一個 local-path PVC（seed-pod 六步，trilium 範本）；apprise 的 /config（40K）搬進另一個 PVC。relay 是本地 build 的 image，先推到 GHCR 讓 k3s 拉得到。三個服務各一個 Deployment；vikunja 開 NodePort 30084、apprise 開 30085，relay 純 ClusterIP。webhook URL（`http://vikunja-notify-relay:8080/`）因 k8s Service 同名而沿用，不需重註冊。

**Tech Stack:** k3s（Cilium + ArgoCD app-of-apps）、Kubernetes manifests（Deployment/PVC/Service）、local-path StorageClass、NPM automation API、GHCR + GitHub Actions（relay CI）。

## Global Constraints

- 所有 pod 一律 `enableServiceLinks: false`（避免 Service 名注入的 `<SVC>_PORT` 撞 app 自己的 env——trilium `TRILIUM_PORT` 教訓）
- 所有 env 設 `TZ: Asia/Hong_Kong`；image 有沒有 tzdata 照實測 `date` 對齊，不額外追（k8s README 對照表）
- image 一律釘 tag，不用 `latest`；secrets 永不進 git（來源是各 compose 目錄 gitignored 的 `.env`）
- NPM 的 Forward Hostname/IP 必須是字面 IP `10.0.0.95`（phase A 已知坑）
- local-path PV 目錄查詢用 `spec.local.path`（不是 `spec.hostPath.path`）
- 停容器後**等 ~10 秒**再數檔案數（sqlite wal/shm 會收斂，phase C 教訓）
- 新增 ArgoCD Application 一律 `prune: true` / `selfHeal: true`；新 Application 生效用 `argocd app sync root`
- `workloads` 配額是 `2C/4Gi`，加進 vikunja 棧後 limits 約 `700m/768Mi`、requests 約 `350m/384Mi`，加上既有 `1C/1280Mi` 仍在配額內——**不調整配額**
- 容器 UID：vikunja=1000、apprise=root、relay=nobody。PVC 資料屬主對齊 vikunja 的 uid 1000
- 每個任務在 k3s 節點本機執行（就是這台機器），`kubectl` 已指到 cluster

---

### Task 1: 把 vikunja-notify-relay image 推到 GHCR

**Files:**
- Build context: `vps_oracle/compose/vikunja/notify-relay/`（Dockerfile + app.py，不動）

**Interfaces:**
- Produces: `ghcr.io/jeromefromcn/vikunja-notify-relay:1.1.0`（linux/arm64，被 Task 9 的 relay Deployment 引用）

- [ ] **Step 1: 從 repo 原始碼重建 relay image**（確保 push 上去的內容 == repo 現況，不是某個歷史 build）

```bash
cd /home/ubuntu/jerome/docker-gitops
docker build -t vikunja-notify-relay:1.1.0 vps_oracle/compose/vikunja/notify-relay/
```

Expected: build 成功，結尾 `Successfully tagged vikunja-notify-relay:1.1.0:latest`（`latest` 是 docker build 的假標籤，下一動蓋掉）。

- [ ] **Step 2: 確認 GHCR 登入**

```bash
docker login ghcr.io -u Jeromefromcn --password-stdin
```

（密碼用 GitHub PAT，scope 需 `write:packages`；若 terminal 已登入可跳過。按提示輸入即可，不要把它寫進任何檔案。）

- [ ] **Step 3: 標 tag 並 push**

```bash
docker tag vikunja-notify-relay:1.1.0 ghcr.io/jeromefromcn/vikunja-notify-relay:1.1.0
docker push ghcr.io/jeromefromcn/vikunja-notify-relay:1.1.0
```

Expected: push 成功，輸出一行 digest。

- [ ] **Step 4: 驗證可被 k3s 拉取（arm64 manifest 存在）**

```bash
docker buildx imagetools inspect ghcr.io/jeromefromcn/vikunja-notify-relay:1.1.0
```

Expected: 顯示 `Platform: linux/arm64`（含 digest）。

---

### Task 2: 建立 `vikunja` Secret（VIKUNJA_SERVICE_SECRET）

**Files:**
- Source: `vps_oracle/compose/vikunja/.env`（gitignored，已含 `VIKUNJA_SERVICE_SECRET=<openssl rand -hex 32>`，不提交）

**Interfaces:**
- Produces: Secret `vikunja`（key `VIKUNJA_SERVICE_SECRET`）in ns `workloads`，被 Task 3 的 vikunja Deployment `secretKeyRef` 引用

- [ ] **Step 1: 從 gitignored .env 抽出 secret 值，冪等建立 Secret**

```bash
cd /home/ubuntu/jerome/docker-gitops
kubectl create secret generic vikunja -n workloads \
  --from-literal=VIKUNJA_SERVICE_SECRET="$(grep -E '^VIKUNJA_SERVICE_SECRET=' vps_oracle/compose/vikunja/.env | cut -d= -f2-)" \
  --dry-run=client -o yaml | kubectl apply -f -
```

（`grep | cut` 只抽出該 key；若 .env 是 `VIKUNJA_SERVICE_SECRET=...` 單行格式。用 dry-run+apply 使重跑冪等。）

- [ ] **Step 2: 驗證 secret 存在且 key 非空**

```bash
kubectl get secret vikunja -n workloads -o jsonpath='{.data.VIKUNJA_SERVICE_SECRET}' | wc -c
```

Expected: 輸出 > 0（base64 後的位元組數）。不要把它印出來。

---

### Task 3: 寫 vikunja + relay 的 k8s manifests

**Files:**
- Create: `vps_oracle/k3s/apps/vikunja/k8s/pvc.yaml`
- Create: `vps_oracle/k3s/apps/vikunja/k8s/deployment.yaml`
- Create: `vps_oracle/k3s/apps/vikunja/k8s/service.yaml`
- Create: `vps_oracle/k3s/apps/vikunja/k8s/relay-deployment.yaml`
- Create: `vps_oracle/k3s/apps/vikunja/k8s/relay-service.yaml`

（spec 的 repo 佈局把 relay 放 `relay/` 子目錄；這裡改為同目錄平鋪——ArgoCD 不遞迴掃描子目錄，平鋪最簡單。）

**Interfaces:**
- Consumes: Secret `vikunja`（Task 2）、image `ghcr.io/jeromefromcn/vikunja-notify-relay:1.1.0`（Task 1）
- Produces: PVC `vikunja`、Deployment/Service `vikunja`（NodePort 30084）、Deployment/Service `vikunja-notify-relay`（ClusterIP 8080）——被 Task 7 資料搬遷與 Task 9 sync 使用

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
      # 不加会注入 VIKUNJA_PORT=tcp://...，撞 vikunja 自己的 VIKUNJA_* 配置（trilium 教訓）
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

（`subPath: db` / `subPath: files` 對應 PV 根目錄下的 `db/`、`files/` 子目錄——Task 7 搬資料時建立。）

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

- [ ] **Step 5: `relay-service.yaml`**（純內網，ClusterIP；名稱必須是 `vikunja-notify-relay`，vikunja DB 裡的 webhook URL 才解析得到）

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

- [ ] **Step 6: 驗證五個檔案寫出（佔位檢查，真正的驗證在 Task 9）**

```bash
ls vps_oracle/k3s/apps/vikunja/k8s/
```

Expected: `pvc.yaml  deployment.yaml  service.yaml  relay-deployment.yaml  relay-service.yaml`

---

### Task 4: 寫 apprise 的 k8s manifests

**Files:**
- Create: `vps_oracle/k3s/apps/apprise/k8s/pvc.yaml`
- Create: `vps_oracle/k3s/apps/apprise/k8s/deployment.yaml`
- Create: `vps_oracle/k3s/apps/apprise/k8s/service.yaml`

**Interfaces:**
- Produces: PVC `apprise`、Deployment/Service `apprise`（NodePort 30085）——被 Task 8 資料搬遷、Task 10 sync、Task 11 NPM 切流使用。relay 以 `http://apprise:8000` 訪問它（k8s DNS 同名）

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

- [ ] **Step 4: 驗證檔案存在**

```bash
ls vps_oracle/k3s/apps/apprise/k8s/
```

Expected: `pvc.yaml  deployment.yaml  service.yaml`

---

### Task 5: 寫 ArgoCD child Application（app-of-apps 入口）

**Files:**
- Create: `vps_oracle/k3s/argocd/apps/vikunja.yaml`
- Create: `vps_oracle/k3s/argocd/apps/apprise.yaml`

**Interfaces:**
- Consumes: Task 3/4 的 manifest 目錄
- Produces: 兩個 Application（ns `argocd`）——Task 9/10 以 `argocd app sync root` 讓它們生效

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

- [ ] **Step 3: 驗證檔案存在**

```bash
ls vps_oracle/k3s/argocd/apps/vikunja.yaml vps_oracle/k3s/argocd/apps/apprise.yaml
```

---

### Task 6: 停 compose 棧 + 記錄資料基準

**Files:**
- None（操作既有 compose：`vps_oracle/compose/vikunja/`、`vps_oracle/compose/apprise/`）

**Interfaces:**
- Consumes: 現役的 compose 容器（vikunja、vikunja-notify-relay、apprise）
- Produces: 停機狀態 + 資料基準數字（Task 7/8 搬遷前後比對）

- [ ] **Step 1: 停 vikunja 棧與 apprise（docker compose stop，不 down 不刪）**

```bash
cd /home/ubuntu/jerome/docker-gitops/vps_oracle/compose/vikunja && docker compose stop
cd /home/ubuntu/jerome/docker-gitops/vps_oracle/compose/apprise && docker compose stop
```

- [ ] **Step 2: 等 ~10 秒讓 sqlite 的 wal/shm 收斂**（phase C 教訓：停容器瞬間數檔案數不準）

```bash
sleep 10
```

- [ ] **Step 3: 記錄基準**

```bash
echo "vikunja files: $(sudo find /etc/vikunja -type f | wc -l)"
echo "vikunja size:  $(sudo du -sh /etc/vikunja | cut -f1)"
echo "apprise size:  $(sudo du -sh /etc/apprise/config | cut -f1)"
```

Expected: 各輸出一行（例如 `vikunja files: 3`、`vikunja size: 4.8M`、`apprise size: 40K`）。**抄下這三個數字**，Task 7/8 搬遷後比對。

- [ ] **Step 4: 確認三個容器都 Exited 且未被刪除**

```bash
docker ps -a --format '{{.Names}}\t{{.Status}}' | grep -E 'vikunja|apprise'
```

Expected: `vikunja Exited (...)`、`vikunja-notify-relay Exited (...)`、`apprise Exited (...)`。

---

### Task 7: 遷移 vikunja 資料進 PVC（trilium seed-pod 六步）

**Files:**
- Create: `vps_oracle/k3s/apps/vikunja/migration/seed-pod.yaml`
- Consumes: `vps_oracle/k3s/apps/vikunja/k8s/pvc.yaml`（Task 3）

**Interfaces:**
- Consumes: `/etc/vikunja`（已停機，靜止）、PVC `vikunja`
- Produces: 已填入資料的 PVC `vikunja`（PV 根目錄含 `db/`、`files/` 子目錄，屬主 uid 1000）——Task 9 sync 後被 vikunja Deployment 認領

- [ ] **Step 1: 寫 seed-pod manifest**

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

- [ ] **Step 2: apply PVC + seed pod，等 PVC Bound**（`WaitForFirstConsumer`：PVC 要等到有 pod 掛載才生宿主機目錄）

```bash
cd /home/ubuntu/jerome/docker-gitops
kubectl apply -f vps_oracle/k3s/apps/vikunja/k8s/pvc.yaml
kubectl apply -f vps_oracle/k3s/apps/vikunja/migration/seed-pod.yaml
kubectl -n workloads wait --for=jsonpath='{.status.phase}'=Bound pvc/vikunja --timeout=120s
```

Expected: `persistentvolumeclaim/vikunja condition met`。

- [ ] **Step 3: 取得 PV 實際宿主機目錄**

```bash
kubectl -n workloads get pvc vikunja -o jsonpath='{.spec.volumeName}'
```

記下 PV 名（形如 `pvc-xxxxxxxx`），再：

```bash
kubectl get pv <PV名> -o jsonpath='{.spec.local.path}'
```

Expected: 一行宿主機路徑（形如 `/var/lib/rancher/k3s/storage/pvc-...`）。**不要用 `spec.hostPath.path`**（local-path 的欄位是 `spec.local.path`）。

- [ ] **Step 4: 複製資料 + chown（來源只讀，不動原目錄）**

```bash
sudo cp -a /etc/vikunja/. <PV目錄>/
sudo chown -R 1000:1000 <PV目錄>
```

（`cp -a` 保留屬主/時間戳；`chown 1000:1000` 對齊 vikunja 容器 uid 1000——provisioner 建的目錄屬主是 root。）

- [ ] **Step 5: 驗證檔案數/大小與基準一致**

```bash
echo "migrated vikunja files: $(sudo find <PV目錄> -type f | wc -l)"
sudo du -sh <PV目錄>
```

Expected: 檔案數 == Task 6 Step 3 的 vikunja files 基準；大小相近（4.8M 量級）。

- [ ] **Step 6: 收 seed pod（PVC 保留，資料留在原地）**

```bash
kubectl delete -f vps_oracle/k3s/apps/vikunja/migration/seed-pod.yaml
```

Expected: `pod "vikunja-migration-seed" deleted`。

- [ ] **Step 7: commit seed-pod manifest**（搬遷工具留檔，與 trilium 的 `migration/` 目錄一致）

```bash
git add vps_oracle/k3s/apps/vikunja/migration/seed-pod.yaml
git commit -m "Add vikunja data-migration seed pod manifest"
```

（若執行者是 subagent，這一步與 Task 9 的 commit 一起由 review gate 決定是否合併；seed-pod 是搬遷工具，保留即可。）

---

### Task 8: 遷移 apprise 的 /config 進 PVC

**Files:**
- Create: `vps_oracle/k3s/apps/apprise/migration/seed-pod.yaml`

**Interfaces:**
- Consumes: `/etc/apprise/config`（40K，靜止）、PVC `apprise`
- Produces: 已填入資料的 PVC `apprise`（PV 根目錄 = /config 內容）——Task 10 sync 後被 apprise Deployment 認領

- [ ] **Step 1: 寫 seed-pod manifest（同 Task 7 模式，PVC 換成 `apprise`）**

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

- [ ] **Step 2: apply PVC + seed pod，等 Bound**

```bash
cd /home/ubuntu/jerome/docker-gitops
kubectl apply -f vps_oracle/k3s/apps/apprise/k8s/pvc.yaml
kubectl apply -f vps_oracle/k3s/apps/apprise/migration/seed-pod.yaml
kubectl -n workloads wait --for=jsonpath='{.status.phase}'=Bound pvc/apprise --timeout=120s
```

Expected: `persistentvolumeclaim/apprise condition met`。

- [ ] **Step 3: 取 PV 目錄並複製**（apprise 以 root 執行，屬主不重要，`cp -a` 即可、不需 chown）

```bash
PVNAME=$(kubectl -n workloads get pvc apprise -o jsonpath='{.spec.volumeName}')
PVDIR=$(kubectl get pv "$PVNAME" -o jsonpath='{.spec.local.path}')
echo "PV dir: $PVDIR"
sudo cp -a /etc/apprise/config/. "$PVDIR"/
```

Expected: `PV dir: /var/lib/rancher/k3s/storage/pvc-...`，cp 無錯誤輸出。

- [ ] **Step 4: 驗證大小與基準一致**

```bash
sudo du -sh <PV目錄>
```

Expected: 與 Task 6 的 apprise 基準一致（40K 量級）。

- [ ] **Step 5: 收 seed pod + commit**

```bash
kubectl delete -f vps_oracle/k3s/apps/apprise/migration/seed-pod.yaml
git add vps_oracle/k3s/apps/apprise/migration/seed-pod.yaml
git commit -m "Add apprise data-migration seed pod manifest"
```

---

### Task 9: 提交 vikunja + relay 並 ArgoCD sync，內部驗證

**Files:**
- Commit: `vps_oracle/k3s/apps/vikunja/k8s/`（Task 3）、`vps_oracle/k3s/argocd/apps/vikunja.yaml`（Task 5）

**Interfaces:**
- Consumes: Task 3/5 的檔案、Task 1 的 relay image、Task 2 的 Secret、Task 7 已填資料的 PVC
- Produces: 叢集內 vikunja + relay 跑起來（NPM 還沒切）

- [ ] **Step 1: commit + push**

```bash
cd /home/ubuntu/jerome/docker-gitops
git add vps_oracle/k3s/apps/vikunja/k8s/ vps_oracle/k3s/argocd/apps/vikunja.yaml
git commit -m "Deploy vikunja + notify-relay to k3s via GitOps"
git push origin main
```

（push 前先 `git status` 確認沒有混進別人的變更——本 repo 可能有並行的 Claude session 在 commit。）

- [ ] **Step 2: 觸發 root Application sync**（新 Application 要 sync `root` 才建得出來）

```bash
argocd app sync root
```

（或等 ArgoCD 下一輪 poll。sync 後等 `vikunja`、`apprise` 兩個 Application 出現。）

- [ ] **Step 3: 等 pod 起來、PVC Bound**

```bash
kubectl -n workloads wait --for=condition=available deploy/vikunja --timeout=180s
kubectl -n workloads wait --for=condition=available deploy/vikunja-notify-relay --timeout=180s
kubectl get pvc -n workloads
```

Expected: 兩個 deployment available；PVC `vikunja` 為 `Bound`。

- [ ] **Step 4: 確認 ArgoCD 狀態**

```bash
kubectl get applications -n argocd | grep -E 'vikunja|apprise'
```

Expected: `vikunja` 出現且 `Synced`/`Healthy`（apprise 此時可能還沒出現，Task 10 才提交它——只要 vikunja 對即可）。

- [ ] **Step 5: 內部連通驗證（切 NPM 之前，叢集內先通）**

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:30084
kubectl -n workloads logs deploy/vikunja-notify-relay --tail=20
```

Expected: vikunja 回 `200` 或 `302`（登入頁/重導向）；relay log 乾乾淨淨、無 traceback（relay 無 NodePort，用 log 確認啟動正常）。

---

### Task 10: 提交 apprise 並 ArgoCD sync，內部驗證

**Files:**
- Commit: `vps_oracle/k3s/apps/apprise/k8s/`（Task 4）、`vps_oracle/k3s/argocd/apps/apprise.yaml`（Task 5）

**Interfaces:**
- Consumes: Task 4/5 的檔案、Task 8 已填資料的 PVC
- Produces: 叢集內 apprise 跑起來（NPM 還沒切）

- [ ] **Step 1: commit + push**

```bash
cd /home/ubuntu/jerome/docker-gitops
git add vps_oracle/k3s/apps/apprise/k8s/ vps_oracle/k3s/argocd/apps/apprise.yaml
git commit -m "Deploy apprise to k3s via GitOps"
git push origin main
```

- [ ] **Step 2: 等 apprise pod 起來、PVC Bound**

```bash
kubectl -n workloads wait --for=condition=available deploy/apprise --timeout=180s
kubectl get pvc -n workloads
```

Expected: `apprise` deployment available；PVC `apprise` 為 `Bound`。

- [ ] **Step 3: ArgoCD 狀態 + 內部連通**

```bash
kubectl get applications -n argocd | grep -E 'vikunja|apprise'
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:30085
```

Expected: 兩者 `Synced`/`Healthy`；apprise 回 `200`（根路徑有回應）。

---

### Task 11: NPM 切流 + 外部驗證

**Files:**
- None（操作 NPM proxy host id 19 vikunja、id 20 apprise；NPM 管理埠 81 只對 `proxy` 網路開放，不走宿主機）

**Interfaces:**
- Consumes: `.npm-automation.env`（gitignored 的 NPM API 帳密）、兩個已就緒的 NodePort
- Produces: NPM 兩條 proxy host 改指 `10.0.0.95:30084/30085`，域名對外不變

- [ ] **Step 1: 寫一個一次性切流腳本（docker run --network proxy 執行，因為宿主機連不到 npm:81）**

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

Expected: 印出 `proxy host 19 -> 10.0.0.95:30084 (...)` 與 `proxy host 20 -> 10.0.0.95:30085 (...)`，且 `ssl_forced=true`、`http2_support=true` 保持（NPM 已知「SSL 開關自己重置」bug，若被重置下面 Step 3 會抓出來）。

- [ ] **Step 2: 外部驗證（域名不變，從伺服器本機打，本機公網 IP 在 access list 上）**

```bash
curl -s -o /dev/null -w 'vikunja: %{http_code}\n' https://vikunja.jerome.cloudns.asia
curl -s -o /dev/null -w 'apprise: %{http_code}\n' https://apprise.jerome.cloudns.asia
```

Expected: 兩者 `200`/`302`（有 access list，但來源是本機公網 IP，放行）。

- [ ] **Step 3: 確認 SSL 沒被 PUT 重置**（若回 3xx 跳轉或 502，去 NPM UI 檢查該 host 的 SSL 開關）

```bash
curl -sv -o /dev/null https://vikunja.jerome.cloudns.asia 2>&1 | grep -E 'SSL connection|subject:'
```

Expected: `SSL connection using TLS...`、`subject: CN=...`（正常握手，非憑證錯誤）。

---

### Task 12: 功能端到端驗證——Telegram 通知鏈路

**Files:**
- None（操作 vikunja UI/API + 看 k8s log + 使用者 Telegram）

**Interfaces:**
- Consumes: 遷移後的 vikunja + relay + apprise
- Produces: 證明「vikunja → relay → apprise → Telegram」整條鏈遷後仍通

- [ ] **Step 1: 登入 vikunja 並建一個 task 指派給使用者**

用瀏覽器開 `https://vikunja.jerome.cloudns.asia` 登入，建一個 task 指派給某個真實使用者（例如 jerome）。指派動作觸發 `task.assignee.created` webhook。

（若用 API：先 `POST /api/v1/login` 拿 token，再 `POST /api/v1/projects/{id}/tasks` 帶 `assignees: [使用者ID]`。帳密在使用者手上，plan 不預設。）

- [ ] **Step 2: 確認該使用者的 Telegram 收到通知**

檢查使用者的 Telegram（vikunja-tg-{username} 的 apprise target）——應收到「📌 Task assigned to you」格式的消息。

- [ ] **Step 3: 看 relay + apprise log 佐證**

```bash
kubectl -n workloads logs deploy/vikunja-notify-relay --tail=20
kubectl -n workloads logs deploy/apprise --tail=20
```

Expected: relay log 出現收到 vikunja webhook 的 POST 記錄（200）；apprise log 無錯誤。若 Telegram 收到而 log 沒顯示，以 Telegram 實際收到為準。

- [ ] **Step 4: 確認舊 compose 容器仍是 Exited 未刪除（回滾點）**

```bash
docker ps -a --format '{{.Names}}\t{{.Status}}' | grep -E 'vikunja|apprise'
```

Expected: 三個都是 `Exited`，**不是** `Removed` 或 `Up`。

---

### Task 13: 為 relay 加 CI workflow（未來改動可重現）

**Files:**
- Create: `.github/workflows/vikunja-notify-relay.yml`

**Interfaces:**
- Consumes: `vps_oracle/compose/vikunja/notify-relay/`（Dockerfile + app.py + test_app.py）
- Produces: push 時自動 build→test→Trivy→Cosign→push `ghcr.io/jeromefromcn/vikunja-notify-relay:<sha>`；未來 bump 部署版本時照 placeholder-hello 的手動兩步（改 deployment.yaml image tag）

- [ ] **Step 1: 寫 workflow**（以 `.github/workflows/placeholder-hello.yml` 為底，context 換成 relay 目錄，加一步跑 unittest）

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

- [ ] **Step 2: 驗證 YAML 可解析**

```bash
python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/vikunja-notify-relay.yml')); print('valid')"
```

Expected: `valid`。

- [ ] **Step 3: commit + push**

```bash
cd /home/ubuntu/jerome/docker-gitops
git add .github/workflows/vikunja-notify-relay.yml
git commit -m "Add CI for vikunja-notify-relay image (build, test, scan, sign, push)"
git push origin main
```

Expected: 該 commit 不會觸發 workflow（path 過濾只匹配 relay 目錄），但 `workflow_dispatch` 可在 GitHub 上手動跑。**本 plan 的 migration 已完成、不依賴這次 CI 執行**；下次改 relay 程式時它會自動 build 新 `:<sha>`，屆時照 placeholder-hello 手動兩步把 deployment image tag 指過去。

---

## Self-Review 記錄

- **Spec 覆蓋**：vikunja 棧三件（vikunja+relay+apprise）→ Task 3/4；sqlite 原樣 + PVC 搬遷 → Task 7；relay 上 GHCR + CI → Task 1/13；Secret 帶外手動建 → Task 2；NPM 切流（含 SSL 重置檢查）→ Task 11；webhook URL 沿用（Service 同名）→ Task 9 Step 5 + Task 12；`enableServiceLinks: false` 全 pod → Global Constraints + Task 3/4 manifests；quota 不動 → Global Constraints。3x-ui 保留、dify/llm 各寫各的 plan（見「待辦」）。
- **Placeholder scan**：無 TBD/TODO；每個 code/manifest/command 都是實際內容。
- **Type consistency**：Service 名 `vikunja`/`vikunja-notify-relay`/`apprise` 跨 Task 一致；secret key `VIKUNJA_SERVICE_SECRET` 跨 Task 2/3 一致；NodePort 30084/30085 跨 Task 3/4/9/10/11 一致；PV 目錄查詢統一 `spec.local.path`。

## 待辦（不在本 plan）

- **dify 遷移 plan**（9 容器 → `dify` ns，含 StatefulSet + SSRF NetworkPolicy + 8 條 NPM location 切流 + 5 個 secret）
- **llm 棧遷移 plan**（3 容器 → `llm` ns，含 3C/9G 配額 + models/data PVC）
- **3x-ui**：不遷（spec 已記為 compose 保留）
- **phase E**：Sealed Secrets 接管 Task 2 的帶外 Secret
