# Migrate llm / vikunja / apprise back to compose Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild docker-compose stacks for `apprise`, `vikunja` (+ `vikunja-notify-relay`), and `llm` (`llama-cpp` + `open-webui`) that match their current live k3s state, migrate persistent data back to host bind mounts, cut NPM back over, then remove the k3s footprint for these 3 apps — completing the reversal started in [`2026-08-18-k3s-to-compose-migration.md`](2026-08-18-k3s-to-compose-migration.md) (homepage/trilium/dify/evidence-os-website). `sillytavern` (the third llm-stack service in the old compose) was already fully decommissioned on 2026-08-16 — it does not come back.

**Architecture:** Same shape as part 1. All persistent data is on this same single-node host under `/var/lib/rancher/k3s/storage/<pv>_<ns>_<pvc>/` — same-host file copy, not network transfer. `apprise`'s data is trivial (40K). `vikunja` uses SQLite (not a real DB server) with two subdirectories (`db`, `files`) inside one PVC — split back into two host bind mounts. `llm`'s two PVCs are large (1.9GB model file, 890MB webui data) and currently live (1/1 replicas) — scale to 0 before the final copy, same as trilium's approach in part 1.

**Tech Stack:** Docker Compose, k3s/kubectl, ArgoCD, Nginx Proxy Manager (REST API via `curl`+`jq` from inside the `npm` container, same automation account as part 1).

**Spec:** No separate spec doc — self-contained, all research already gathered directly against the live cluster/git history and embedded below.

## Critical lesson from part 1 — apply this time

**Never run `docker compose up -d` from inside a worktree.** Part 1 corrupted `homepage`'s live config and left `dify-ssrf-proxy` fragile because their relative bind mounts (`./config`, `./ssrf_proxy/*`) got baked in as absolute paths under `.worktrees/<branch>/...`, which was then deleted during branch-finish cleanup — Docker silently recreated the mount source as an empty directory on next touch. See [[worktree_gitignored_files_gotcha]] memory.

**This time:** author and commit each app's compose files in the worktree as before, but **merge that app's commit into `main` and push immediately**, then run `docker compose up -d` **from the main checkout path** (`/home/ubuntu/jerome/docker-gitops/vps_oracle/compose/<app>`), never from `.worktrees/.../vps_oracle/compose/<app>`. This applies to every "bring up" step below — the working directory for `docker compose` commands is always the main checkout.

## Global Constraints

Same as part 1 — see its "Global Constraints" section (TZ, logging, restart policy, `no-new-privileges:true`, `proxy` network only, no `latest` tags, `.env` gitignored, one commit per stack).

---

### Task 1: `apprise` — compose file, data migration, bring up, verify, commit

**Files:**
- Create: `vps_oracle/compose/apprise/docker-compose.yml`

**Interfaces:**
- Depends on: nothing.
- Produces: running `apprise` container at `http://apprise:8000` on `proxy` — Task 5 (`vikunja-notify-relay`) and Task 2 (NPM) depend on this.

- [ ] **Step 1: Scale down k3s apprise (data is tiny but stop writes for a clean copy anyway)**

```bash
kubectl scale deployment apprise -n workloads --replicas=0
kubectl wait --for=delete pod -l app=apprise -n workloads --timeout=60s
```

- [ ] **Step 2: Copy the PVC data to the new host bind-mount path**

```bash
sudo mkdir -p /etc/apprise/config
sudo cp -a /var/lib/rancher/k3s/storage/pvc-94efbe4c-b874-445f-bc94-6671b421746c_workloads_apprise/. /etc/apprise/config/
sudo ls -la /etc/apprise/config
```

- [ ] **Step 3: Write `docker-compose.yml`** (in the worktree)

```yaml
services:
  apprise:
    image: caronc/apprise:v1.5.1
    container_name: apprise
    hostname: apprise
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "5"
    environment:
      TZ: "Asia/Hong_Kong"
      APPRISE_STATEFUL_MODE: "simple"
      APPRISE_WORKER_COUNT: "1"
      APPRISE_ADMIN: "y"
    volumes:
      - /etc/apprise/config:/config
    networks:
      - proxy
    # NPM 反代配置: Forward Hostname/IP = apprise, Forward Port = 8000（未发布到宿主机）

networks:
  proxy:
    external: true
```

- [ ] **Step 4: Commit in the worktree, merge to `main`, push**

```bash
cd <worktree-root>
git add vps_oracle/compose/apprise/
git commit -m "Add apprise compose stack, rebuilt from k3s state with migrated config"
cd /home/ubuntu/jerome/docker-gitops
git fetch origin main && git merge-base --is-ancestor origin/main HEAD && echo ok
git merge --ff-only <worktree-branch>
git push origin main
```

- [ ] **Step 5: Bring up FROM THE MAIN CHECKOUT (not the worktree) and verify**

```bash
cd /home/ubuntu/jerome/docker-gitops/vps_oracle/compose/apprise
docker compose up -d
docker compose ps
docker logs apprise --tail 30
docker run --rm --network proxy curlimages/curl -sf -o /dev/null -w '%{http_code}\n' http://apprise:8000/
```

Expected: `Up`, no error logs, curl `200`.

---

### Task 2: `apprise` — NPM cutover

**Files:** none.

**Interfaces:**
- Depends on: Task 1.
- Produces: `apprise.jerome.cloudns.asia` served by compose.

- [ ] **Step 1: Fetch a fresh API token, PATCH proxy host id 20**

```bash
source /home/ubuntu/jerome/docker-gitops/vps_oracle/compose/npm/.npm-automation.env
TOKEN=$(docker exec npm sh -c "curl -s -X POST http://localhost:81/api/tokens \
  -H 'Content-Type: application/json' \
  -d '{\"identity\":\"$NPM_AUTOMATION_EMAIL\",\"secret\":\"$NPM_AUTOMATION_PASSWORD\"}' | jq -r .token")
docker exec npm sh -c "curl -s -H 'Authorization: Bearer $TOKEN' http://localhost:81/api/nginx/proxy-hosts/20 | \
  jq 'del(.id, .created_on, .modified_on, .owner_user_id) | .forward_host = \"apprise\" | .forward_port = 8000' > /tmp/npm-20.json"
docker exec npm sh -c "curl -s -X PUT http://localhost:81/api/nginx/proxy-hosts/20 \
  -H 'Authorization: Bearer $TOKEN' -H 'Content-Type: application/json' \
  -d @/tmp/npm-20.json" | head -c 200
echo
docker exec npm grep -E 'set +\$server|set +\$port' /data/nginx/proxy_host/20.conf
```

- [ ] **Step 2: Verify externally**

```bash
curl -sf -o /dev/null -w '%{http_code}\n' https://apprise.jerome.cloudns.asia/
```

---

### Task 3: `vikunja` + `vikunja-notify-relay` — data migration

**Files:** none (host filesystem + k3s state only).

**Interfaces:**
- Depends on: nothing.
- Produces: `/etc/vikunja/db` and `/etc/vikunja/files` populated. Task 4 mounts these paths.

`vikunja`'s single PVC has two subdirectories (`db/`, `files/`, via `subPath`) — split back into the two separate host paths the old compose used.

- [ ] **Step 1: Scale down k3s vikunja (stops writes to the SQLite file)**

```bash
kubectl scale deployment vikunja -n workloads --replicas=0
kubectl wait --for=delete pod -l app=vikunja -n workloads --timeout=60s
```

- [ ] **Step 2: Copy each subdirectory to its own host path**

```bash
sudo mkdir -p /etc/vikunja/db /etc/vikunja/files
sudo cp -a /var/lib/rancher/k3s/storage/pvc-615448ea-6047-44ff-8adb-fff1515e7229_workloads_vikunja/db/. /etc/vikunja/db/
sudo cp -a /var/lib/rancher/k3s/storage/pvc-615448ea-6047-44ff-8adb-fff1515e7229_workloads_vikunja/files/. /etc/vikunja/files/
sudo ls -la /etc/vikunja/db /etc/vikunja/files
```

- [ ] **Step 3: Verify the SQLite file copied cleanly**

```bash
sudo ls -la /etc/vikunja/db/vikunja.db
```

Expected: a single `vikunja.db` file, no `-wal`/`-shm` companion files left mid-transaction (vikunja's SQLite driver checkpoints on clean shutdown, same pattern as trilium in part 1).

---

### Task 4: `vikunja` + `vikunja-notify-relay` — compose files, bring up, verify, commit

**Files:**
- Create: `vps_oracle/compose/vikunja/docker-compose.yml`

**Interfaces:**
- Depends on: Task 3 (vikunja's data), Task 1 (`apprise` container must already be up — `vikunja-notify-relay` calls `http://apprise:8000`).
- Produces: running `vikunja` (port 3456) and `vikunja-notify-relay` (port 8080, internal-only) containers on `proxy`. Task 5 (NPM) and any future webhook re-registration depend on this.

`vikunja-notify-relay` keeps the same pre-built, already-signed image k3s used (`ghcr.io/jeromefromcn/vikunja-notify-relay@sha256:...`) rather than reverting to `build: ./notify-relay` — same reasoning as part 1's homepage/trilium images: it's already built, already digest-pinned, no reason to rebuild. Carries forward k3s's extra hardening (`runAsNonRoot`, uid 65534, dropped capabilities) via compose's `user:`/`cap_drop:` equivalents.

- [ ] **Step 1: Write `docker-compose.yml`**

```yaml
services:
  vikunja:
    image: vikunja/vikunja:2.4.0
    container_name: vikunja
    hostname: vikunja
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "5"
    env_file:
      - .env   # 需要一行 VIKUNJA_SERVICE_SECRET=<值>，见 Step 2
    environment:
      TZ: "Asia/Hong_Kong"
      VIKUNJA_DATABASE_TYPE: sqlite
      VIKUNJA_DATABASE_PATH: /db/vikunja.db
      VIKUNJA_SERVICE_PUBLICURL: "https://vikunja.jerome.cloudns.asia"
      VIKUNJA_SERVICE_ENABLEREGISTRATION: "false"
      VIKUNJA_OUTGOINGREQUESTS_ALLOWNONROUTABLEIPS: "true"
    volumes:
      - /etc/vikunja/files:/app/vikunja/files
      - /etc/vikunja/db:/db
    networks:
      - proxy
    # NPM 反代配置: Forward Hostname/IP = vikunja, Forward Port = 3456（未发布到宿主机）

  vikunja-notify-relay:
    image: ghcr.io/jeromefromcn/vikunja-notify-relay@sha256:163e88a174aad5e477e475d8d5d4f2dea66f44de08ecf0ea0771ff24327214b7
    container_name: vikunja-notify-relay
    hostname: vikunja-notify-relay
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    user: "65534:65534"
    cap_drop:
      - ALL
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "5"
    environment:
      TZ: "Asia/Hong_Kong"
      VIKUNJA_BASE_URL: "https://vikunja.jerome.cloudns.asia"
      APPRISE_BASE_URL: "http://apprise:8000"
      PORT: "8080"
    networks:
      - proxy
    # 纯内部 glue 服务：接 Vikunja webhook，拼好 project/task/超链接的 HTML 消息后转发给 apprise。
    # 不接 NPM、不发布端口，只在 proxy 网络内被 vikunja 用容器名访问。见 notify-relay/app.py。

networks:
  proxy:
    external: true
```

- [ ] **Step 2: Write `.env` with the live `VIKUNJA_SERVICE_SECRET` (never printed to a terminal/log)**

```bash
cd /home/ubuntu/jerome/docker-gitops/vps_oracle/compose/vikunja
{
  echo "VIKUNJA_SERVICE_SECRET=$(kubectl get secret vikunja -n workloads -o jsonpath='{.data.VIKUNJA_SERVICE_SECRET}' | base64 -d)"
} > .env
chmod 600 .env
wc -l .env
```

Must reuse the same secret — it signs vikunja's JWTs; rotating it would invalidate every existing session/API token.

- [ ] **Step 3: Commit in the worktree, merge to `main`, push (compose file only — `.env` stays untracked)**

```bash
cd <worktree-root>
git add vps_oracle/compose/vikunja/docker-compose.yml
git commit -m "Add vikunja + vikunja-notify-relay compose stack, rebuilt from k3s state with migrated data"
cd /home/ubuntu/jerome/docker-gitops
git fetch origin main && git merge-base --is-ancestor origin/main HEAD && echo ok
git merge --ff-only <worktree-branch>
git push origin main
```

- [ ] **Step 4: Copy `.env` from the worktree into the main checkout (gitignored — merge doesn't carry it), then bring up FROM THE MAIN CHECKOUT**

```bash
cp <worktree-root>/vps_oracle/compose/vikunja/.env /home/ubuntu/jerome/docker-gitops/vps_oracle/compose/vikunja/.env
cd /home/ubuntu/jerome/docker-gitops/vps_oracle/compose/vikunja
docker compose up -d
docker compose ps
docker logs vikunja --tail 40
docker logs vikunja-notify-relay --tail 20
```

- [ ] **Step 5: Verify internally**

```bash
docker run --rm --network proxy curlimages/curl -sf -o /dev/null -w '%{http_code}\n' http://vikunja:3456/
```

Expected: `200`, and vikunja's logs show it opened the migrated SQLite DB without a "database is locked"/corruption error.

---

### Task 5: `vikunja` — NPM cutover

**Files:** none.

**Interfaces:**
- Depends on: Task 4.
- Produces: `vikunja.jerome.cloudns.asia` served by compose. (`vikunja-notify-relay` has no NPM entry — internal only, unchanged.)

- [ ] **Step 1: Fetch a fresh API token, PATCH proxy host id 19**

```bash
source /home/ubuntu/jerome/docker-gitops/vps_oracle/compose/npm/.npm-automation.env
TOKEN=$(docker exec npm sh -c "curl -s -X POST http://localhost:81/api/tokens \
  -H 'Content-Type: application/json' \
  -d '{\"identity\":\"$NPM_AUTOMATION_EMAIL\",\"secret\":\"$NPM_AUTOMATION_PASSWORD\"}' | jq -r .token")
docker exec npm sh -c "curl -s -H 'Authorization: Bearer $TOKEN' http://localhost:81/api/nginx/proxy-hosts/19 | \
  jq 'del(.id, .created_on, .modified_on, .owner_user_id) | .forward_host = \"vikunja\" | .forward_port = 3456' > /tmp/npm-19.json"
docker exec npm sh -c "curl -s -X PUT http://localhost:81/api/nginx/proxy-hosts/19 \
  -H 'Authorization: Bearer $TOKEN' -H 'Content-Type: application/json' \
  -d @/tmp/npm-19.json" | head -c 200
echo
docker exec npm grep -E 'set +\$server|set +\$port' /data/nginx/proxy_host/19.conf
```

- [ ] **Step 2: Verify externally — confirm existing tasks/projects are present, not a blank instance**

```bash
curl -sf -o /dev/null -w '%{http_code}\n' https://vikunja.jerome.cloudns.asia/
```

Open in a browser and confirm existing projects/tasks load. Also re-check the Telegram webhook still fires on a task event (relay depends on `vikunja`'s outgoing webhook config, which is stored inside the migrated SQLite DB, so it should already be intact — spot check per `docs/2026-08-03-vikunja-apprise-telegram-webhooks.md`).

---

### Task 6: `llm` — extract secret, dump/copy data (while k3s is still running)

**Files:**
- Create: `vps_oracle/compose/llm/.env` (gitignored)

**Interfaces:**
- Depends on: nothing.
- Produces: `.env` with `WEBUI_SECRET_KEY`; `/tmp/llm-migration/` holds nothing (file-based copy only, no DB dump needed — open-webui uses SQLite too but the copy happens after scale-down in Task 7, this task only handles the secret + confirms current live state).

- [ ] **Step 1: Write `.env` from the live k8s Secret**

```bash
mkdir -p /home/ubuntu/jerome/docker-gitops/vps_oracle/compose/llm
cd /home/ubuntu/jerome/docker-gitops/vps_oracle/compose/llm
{
  echo "WEBUI_SECRET_KEY=$(kubectl get secret open-webui -n llm -o jsonpath='{.data.WEBUI_SECRET_KEY}' | base64 -d)"
} > .env
chmod 600 .env
wc -l .env
```

Must reuse the same key — rotating it invalidates every existing open-webui session.

- [ ] **Step 2: Confirm current live state (both currently 1/1, not scaled to 0)**

```bash
kubectl get deploy -n llm llama-cpp open-webui
```

---

### Task 7: `llm` — scale down, copy data, compose files, bring up, verify, commit

**Files:**
- Create: `vps_oracle/compose/llm/docker-compose.yml`

**Interfaces:**
- Depends on: Task 6 (`.env` must exist first — this task's Step 1 stops the source pods).
- Produces: running `llama-cpp` and `open-webui` containers, `open-webui` reachable at `http://open-webui:8080` on `proxy`. Task 8 (NPM) depends on this.

- [ ] **Step 1: Scale down both k3s deployments**

```bash
kubectl scale deployment llama-cpp open-webui -n llm --replicas=0
kubectl wait --for=delete pod -l 'app in (llama-cpp,open-webui)' -n llm --timeout=90s
```

- [ ] **Step 2: Copy both PVCs to host bind-mount paths**

```bash
sudo mkdir -p /etc/llama-cpp/models /etc/openwebui/data
sudo cp -a /var/lib/rancher/k3s/storage/pvc-b266bc14-9d33-44fd-81a5-972a27d029bf_llm_llama-cpp/. /etc/llama-cpp/models/
sudo cp -a /var/lib/rancher/k3s/storage/pvc-d051ea00-2865-4ed8-9864-dfbb4c958b16_llm_open-webui/. /etc/openwebui/data/
sudo du -sh /etc/llama-cpp/models /etc/openwebui/data
```

Expected: sizes matching the source PVCs (~1.9GB, ~890MB) — confirms the copy didn't truncate.

- [ ] **Step 3: Write `docker-compose.yml`**

```yaml
services:
  llama-cpp:
    image: amperecomputingai/llama.cpp:3.4.2   # Ampere Altra 优化版，注意不是 -ampereone 后缀（那是另一颗芯片，在 A1 上跑不了）
    container_name: llama-cpp
    hostname: llama-cpp
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "5"
    environment:
      TZ: "Asia/Hong_Kong"
      LLAMA_ARG_THREADS: "3"
      LLAMA_ARG_CTX_SIZE: "8192"
      LLAMA_ARG_CACHE_RAM: "4096"
    command: >
      --models-dir /models
      --models-max 1
      --host 0.0.0.0
      --port 8080
    volumes:
      - /etc/llama-cpp/models:/models
    networks:
      - proxy
    deploy:
      resources:
        limits:
          cpus: "3"
          memory: "9G"

  open-webui:
    image: ghcr.io/open-webui/open-webui:0.11.0
    container_name: open-webui
    hostname: open-webui
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "5"
    env_file:
      - .env   # WEBUI_SECRET_KEY，见 Task 6
    environment:
      TZ: "Asia/Hong_Kong"
      ENABLE_OLLAMA_API: "false"
      OPENAI_API_BASE_URLS: "http://llama-cpp:8080/v1"
      OPENAI_API_KEYS: "sk-not-required"
    volumes:
      - /etc/openwebui/data:/app/backend/data
    networks:
      - proxy
    depends_on:
      - llama-cpp
    # NPM 反代配置: Forward Hostname/IP = open-webui, Forward Port = 8080（未发布到宿主机）
    # 域名仍是 ollama.jerome.cloudns.asia（历史命名，后端早已换成 llama.cpp，未改域名）

networks:
  proxy:
    external: true
```

Note: `sillytavern` is deliberately **not** included — it was fully decommissioned on 2026-08-16 (removed from k8s + compose + NPM + homepage card), not part of this reversal.

- [ ] **Step 4: Commit in the worktree, merge to `main`, push**

```bash
cd <worktree-root>
git add vps_oracle/compose/llm/docker-compose.yml
git commit -m "Add llm compose stack (llama-cpp + open-webui), rebuilt from k3s state with migrated data"
cd /home/ubuntu/jerome/docker-gitops
git fetch origin main && git merge-base --is-ancestor origin/main HEAD && echo ok
git merge --ff-only <worktree-branch>
git push origin main
```

- [ ] **Step 5: Copy `.env` from the worktree into the main checkout, bring up FROM THE MAIN CHECKOUT**

```bash
cp <worktree-root>/vps_oracle/compose/llm/.env /home/ubuntu/jerome/docker-gitops/vps_oracle/compose/llm/.env
cd /home/ubuntu/jerome/docker-gitops/vps_oracle/compose/llm
docker compose up -d
docker compose ps
```

- [ ] **Step 6: Verify internally (llama-cpp needs time to load the model into memory before it answers)**

```bash
docker logs llama-cpp --tail 40
docker logs open-webui --tail 40
docker run --rm --network proxy curlimages/curl -sf http://llama-cpp:8080/v1/models 2>&1
docker run --rm --network proxy curlimages/curl -sf -o /dev/null -w '%{http_code}\n' http://open-webui:8080/
```

Expected: `/v1/models` lists the same gguf model filename that was in the source `/models` dir; open-webui returns `200`.

---

### Task 8: `llm` (open-webui) — NPM cutover

**Files:** none.

**Interfaces:**
- Depends on: Task 7.
- Produces: `ollama.jerome.cloudns.asia` served by compose.

- [ ] **Step 1: Fetch a fresh API token, PATCH proxy host id 22**

```bash
source /home/ubuntu/jerome/docker-gitops/vps_oracle/compose/npm/.npm-automation.env
TOKEN=$(docker exec npm sh -c "curl -s -X POST http://localhost:81/api/tokens \
  -H 'Content-Type: application/json' \
  -d '{\"identity\":\"$NPM_AUTOMATION_EMAIL\",\"secret\":\"$NPM_AUTOMATION_PASSWORD\"}' | jq -r .token")
docker exec npm sh -c "curl -s -H 'Authorization: Bearer $TOKEN' http://localhost:81/api/nginx/proxy-hosts/22 | \
  jq 'del(.id, .created_on, .modified_on, .owner_user_id) | .forward_host = \"open-webui\" | .forward_port = 8080' > /tmp/npm-22.json"
docker exec npm sh -c "curl -s -X PUT http://localhost:81/api/nginx/proxy-hosts/22 \
  -H 'Authorization: Bearer $TOKEN' -H 'Content-Type: application/json' \
  -d @/tmp/npm-22.json" | head -c 200
echo
docker exec npm grep -E 'set +\$server|set +\$port' /data/nginx/proxy_host/22.conf
```

- [ ] **Step 2: Verify externally — log in with an existing account and send a test chat message**

```bash
curl -sf -o /dev/null -w '%{http_code}\n' https://ollama.jerome.cloudns.asia/
```

Open in a browser, confirm existing chat history is present, and send one message to confirm the llama-cpp backend actually answers through the full NPM→open-webui→llama-cpp chain.

---

### Task 9: k3s cleanup — ArgoCD, sealed-secrets, shared namespace manifest, live resources

**Files:**
- Delete: `vps_oracle/k3s/argocd/apps/apprise.yaml`, `vikunja.yaml`, `llm.yaml`
- Delete: `vps_oracle/k3s/sealed-secrets/secrets/vikunja.sealed.yaml`, `open-webui.sealed.yaml`
- Modify: `vps_oracle/k3s/manifests/pod-security-labels.yaml` (remove the `llm` Namespace block — `workloads` stays, it's shared with apps that remain on k3s)

**Interfaces:**
- Depends on: Tasks 2, 5, 8 (every app cut over and verified working first — same rollback-safety reasoning as part 1).
- Produces: no more ArgoCD-managed resources for these 3 apps.

Apply part 1's lesson directly: deleting only the per-app Application left the `dify` namespace being re-created by a **third**, unrelated Application (`phase-a-foundation`, via the shared `pod-security-labels.yaml`) — check for that here too before declaring done.

- [ ] **Step 1: Check finalizers on all 3 Applications**

```bash
for app in apprise vikunja llm; do
  echo "=== $app ==="
  kubectl get application $app -n argocd -o jsonpath='{.metadata.finalizers}'
  echo
done
```

- [ ] **Step 2: Remove the 3 Application manifests + 2 sealed-secret manifests, commit, push**

```bash
cd /home/ubuntu/jerome/docker-gitops
git rm vps_oracle/k3s/argocd/apps/apprise.yaml vps_oracle/k3s/argocd/apps/vikunja.yaml vps_oracle/k3s/argocd/apps/llm.yaml
git rm vps_oracle/k3s/sealed-secrets/secrets/vikunja.sealed.yaml vps_oracle/k3s/sealed-secrets/secrets/open-webui.sealed.yaml
git commit -m "Remove ArgoCD Applications and SealedSecrets for services migrated back to compose"
git push origin main
```

- [ ] **Step 3: Delete the live SealedSecret/Secret objects and the ArgoCD Application objects directly (don't wait for the poll interval — same as part 1, avoids a selfHeal race)**

```bash
kubectl delete sealedsecret vikunja -n workloads
kubectl delete sealedsecret open-webui -n llm
kubectl delete application apprise vikunja llm -n argocd
```

- [ ] **Step 4: Remove the `llm` Namespace block from the shared foundation manifest, commit, push, force-sync**

Edit `vps_oracle/k3s/manifests/pod-security-labels.yaml`: delete the `Namespace: llm` block (keep `workloads` — apprise/vikunja lived there alongside apps staying on k3s, e.g. `placeholder-hello`).

```bash
git add vps_oracle/k3s/manifests/pod-security-labels.yaml
git commit -m "Remove llm namespace declaration from cluster foundation manifest"
git push origin main
argocd app sync phase-a-foundation --prune
```

- [ ] **Step 5: Manually delete the underlying k8s resources (Applications had no finalizer in part 1 — verify same here via Step 1's output; if still empty, deletes are needed)**

```bash
kubectl delete namespace llm
kubectl delete deployment apprise vikunja vikunja-notify-relay -n workloads
kubectl delete service apprise vikunja vikunja-notify-relay -n workloads
kubectl delete pvc apprise vikunja -n workloads
```

- [ ] **Step 6: Full sweep — confirm nothing remains anywhere in the cluster**

```bash
kubectl get all,pvc,pv,configmap,secret,networkpolicy,sealedsecret,resourcequota -A 2>&1 | grep -i -E "apprise|vikunja|llama-cpp|open-webui"
echo "(empty = clean)"
kubectl get ns llm 2>&1
kubectl get applications -n argocd -o name
```

---

### Task 10: Update docs

**Files:**
- Modify: `vps_oracle/README.md`
- Modify: `vps_oracle/k3s/README.md`

**Interfaces:**
- Depends on: Task 9.
- Produces: no repo doc still claims these 3 apps are k3s-hosted.

- [ ] **Step 1: Update the root README's "已经迁移完成并从 k3s 提供服务" sentence** (currently reads, after part 1's edit: "以及 `vikunja`/`apprise`/`llm`（llama-cpp/open-webui）已经迁移完成并从 k3s 提供服务") — remove these three, note they also moved back to compose on the same day as part 1 (or today's date if this runs later), pointing at this plan doc.

- [ ] **Step 2: Add "migrated back to compose" notes to `vps_oracle/k3s/README.md`'s existing `vikunja`/apprise/llm sections** (same pattern as part 1's homepage/trilium notes — check for section headers first: `grep -n "^## " vps_oracle/k3s/README.md`), without rewriting the historical migration narrative underneath.

- [ ] **Step 3: Commit and push**

```bash
cd /home/ubuntu/jerome/docker-gitops
git add vps_oracle/README.md vps_oracle/k3s/README.md
git commit -m "Update docs: vikunja/apprise/llm migrated back to compose"
git push origin main
```

---

## Verification (end-to-end, after all 10 tasks)

- [ ] All 3 domains load: `for d in apprise:apprise vikunja:vikunja ollama:llm; do domain="${d%%:*}"; curl -s -o /dev/null -w "$domain: %{http_code}\n" https://$domain.jerome.cloudns.asia/; done`
- [ ] `kubectl get applications -n argocd` no longer lists `apprise`/`vikunja`/`llm`.
- [ ] `kubectl get ns` no longer lists `llm`.
- [ ] Before deleting the worktree at the end: `docker inspect <every container touched> --format '{{.Mounts}}'` for `apprise`, `vikunja`, `vikunja-notify-relay`, `llama-cpp`, `open-webui` — confirm **zero** `Source` paths contain `.worktrees/` (the part-1 regression check).
- [ ] `git -C <worktree> status --porcelain --ignored` before worktree removal — confirm no `.env` or other needed file only exists there.

## Rollback safety

Same as part 1: don't run Task 9 (k3s deletion) until Tasks 2/5/8's external verification passed for real (browser-checked where noted, not just curl 200). Until then, k3s workloads are simply scaled to 0 and NPM can be flipped back to `10.0.0.95:<nodeport>` instantly.
