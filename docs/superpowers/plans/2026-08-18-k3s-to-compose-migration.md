# Migrate homepage / trilium / dify / evidence-os-website back to compose Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild docker-compose stacks for `homepage`, `trilium`, `dify`, and `evidence-os-website` that match their current live k3s state, migrate their persistent data back to host bind mounts, cut Nginx Proxy Manager back over to the compose containers, then remove the k3s footprint for just these 4 apps.

**Architecture:** `homepage`/`trilium`/`dify` previously ran as compose stacks before being migrated to k3s (old files deleted from git in commit `1e6bcf9`, still recoverable via `git show`); rebuild them from that history, patched only where the live k3s state diverged (image digests). `evidence-os-website` has no compose history — build fresh from its k3s manifests. Persistent data lives in k3s PVCs backed by `local-path-provisioner` on this same single-node host, at `/var/lib/rancher/k3s/storage/<pv>_<ns>_<pvc>/` — data migration is a same-host file copy (with `pg_dumpall`/`BGSAVE` for the two Postgres instances and Redis, to avoid copying live/inconsistent data files), not a network transfer.

**Tech Stack:** Docker Compose, k3s/kubectl, ArgoCD (GitOps), Nginx Proxy Manager (REST API via `curl`+`jq` from inside the `npm` container).

**Spec:** No separate spec doc — this plan is self-contained; all research (live cluster state, git history, NPM config) was gathered directly and is embedded below.

## Global Constraints

(From `/home/ubuntu/jerome/docker-gitops/README.md` and `CLAUDE.md` — apply to every new compose file.)

- TZ: every service gets `environment: TZ: "Asia/Hong_Kong"`.
- Logging: every service gets `logging: {driver: json-file, options: {max-size: "10m", max-file: "5"}}`.
- Restart policy: `restart: unless-stopped` on every service.
- Security: `security_opt: [no-new-privileges:true]` unless a documented exception applies (none here).
- Networking: join the external `proxy` network (`docker network ls` confirms it already exists, subnet `172.19.0.0/16`); do not publish ports to the host unless the service is one of the documented exceptions (none here — all 4 apps go through NPM only).
- Image pinning: tags or digests only, never `latest`.
- No secrets committed: `.env` files are gitignored already (`.env`/`.env.*`/`*.env` in root `.gitignore`); never put secret values directly in `docker-compose.yml`.
- One git commit per compose stack, scoped to that stack.
- Apply changes with `cd <host>/compose/<compose> && docker compose up -d` after editing.

---

### Task 1: `homepage` — compose files

**Files:**
- Create: `vps_oracle/compose/homepage/docker-compose.yml`
- Create: `vps_oracle/compose/homepage/config/` (copied from k3s)

**Interfaces:**
- Depends on: nothing (stateless service, no prior task).
- Produces: a running `homepage` container reachable at `http://homepage:3000` from other containers on the `proxy` network. Later tasks (NPM cutover) consume this container name/port.

- [ ] **Step 1: Copy the current homepage config from its k3s source of truth**

```bash
mkdir -p /home/ubuntu/jerome/docker-gitops/vps_oracle/compose/homepage
cp -r /home/ubuntu/jerome/docker-gitops/vps_oracle/k3s/apps/homepage/k8s/config \
      /home/ubuntu/jerome/docker-gitops/vps_oracle/compose/homepage/config
```

This pulls `settings.yaml`, `widgets.yaml`, `bookmarks.yaml`, `services.yaml`, `custom.css`, `custom.js` verbatim — these are the exact live cards/theme, no transcription.

- [ ] **Step 2: Write `docker-compose.yml`**

```yaml
services:
  homepage:
    image: ghcr.io/jeromefromcn/homepage@sha256:02b2641e7097b67656f8408edf01c28f2e7d6c61008ed720f888d6355a018040
    container_name: homepage
    hostname: homepage
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
      HOMEPAGE_ALLOWED_HOSTS: "homepage.jerome.cloudns.asia"  # 需与访问用的域名一致，不然 403
    volumes:
      - ./config:/app/config
    networks:
      - proxy
    # NPM 反代配置: Forward Hostname/IP = homepage, Forward Port = 3000（未发布到宿主机）

networks:
  proxy:
    external: true
```

The image is the CVE-2026-59873-patched build (`vps_oracle/k3s/images/homepage/Dockerfile`, v2.0.0 base + npm 11.19.0) that k3s currently runs — not the stock `gethomepage/homepage:v1.13.2`. No `docker.sock` mount: k3s dropped the container-status widget during its migration (no docker socket in k8s) and the copied `services.yaml` cards have no `container`/`server` keys — matching current k3s behavior rather than reviving the old compose-only feature.

- [ ] **Step 3: Bring it up and verify internally**

```bash
cd /home/ubuntu/jerome/docker-gitops/vps_oracle/compose/homepage
docker compose up -d
docker compose ps
docker logs homepage --tail 50
docker run --rm --network proxy curlimages/curl -sf -o /dev/null -w '%{http_code}\n' http://homepage:3000/
```

Expected: container `Up`/healthy, logs clean, curl prints `200`.

- [ ] **Step 4: Commit**

```bash
cd /home/ubuntu/jerome/docker-gitops
git add vps_oracle/compose/homepage/
git commit -m "Add homepage compose stack, rebuilt from k3s state"
```

---

### Task 2: `homepage` — NPM cutover

**Files:** none (live NPM state change only, no repo files).

**Interfaces:**
- Depends on: Task 1 (container `homepage` must be up and passing the internal curl check).
- Produces: `homepage.jerome.cloudns.asia` served by the compose container instead of the k3s NodePort. Task 13 (k3s cleanup) depends on this being verified first.

Each NPM-cutover task (this one, Task 4, Task 7, Task 11) is self-contained and fetches its own fresh token — don't assume shell variables persist between tasks if they run in separate sessions/subagents.

- [ ] **Step 1: Fetch a fresh API token and confirm the current forward target for proxy host id 21**

```bash
source /home/ubuntu/jerome/docker-gitops/vps_oracle/compose/npm/.npm-automation.env
TOKEN=$(docker exec npm sh -c "curl -s -X POST http://localhost:81/api/tokens \
  -H 'Content-Type: application/json' \
  -d '{\"identity\":\"$NPM_AUTOMATION_EMAIL\",\"secret\":\"$NPM_AUTOMATION_PASSWORD\"}' | jq -r .token")
docker exec npm sh -c "curl -s -H 'Authorization: Bearer $TOKEN' http://localhost:81/api/nginx/proxy-hosts/21 | jq '{forward_host, forward_port}'"
```

Expected output before the change: `{"forward_host": "10.0.0.95", "forward_port": 30081}`.

- [ ] **Step 2: PATCH forward_host/forward_port to the compose container**

```bash
docker exec npm sh -c "curl -s -H 'Authorization: Bearer $TOKEN' http://localhost:81/api/nginx/proxy-hosts/21 | \
  jq '.forward_host = \"homepage\" | .forward_port = 3000' > /tmp/npm-21.json"
docker exec npm sh -c "curl -s -X PUT http://localhost:81/api/nginx/proxy-hosts/21 \
  -H 'Authorization: Bearer $TOKEN' -H 'Content-Type: application/json' \
  -d @/tmp/npm-21.json"
```

- [ ] **Step 3: Verify the on-disk conf actually changed (documented gotcha: DB write can silently not re-render the file)**

```bash
docker exec npm grep -E 'set +\$server|set +\$port' /data/nginx/proxy_host/21.conf
```

Expected: `set $server "homepage";` and `set $port 3000;`. If it still shows the old NodePort values, run `docker exec npm nginx -s reload` and re-check.

- [ ] **Step 4: Verify externally**

```bash
curl -sf -o /dev/null -w '%{http_code}\n' https://homepage.jerome.cloudns.asia/
```

Expected: `200`.

---

### Task 3: `evidence-os-website` — compose file

**Files:**
- Create: `vps_oracle/compose/evidence-os-website/docker-compose.yml`

**Interfaces:**
- Depends on: nothing.
- Produces: a running `evidence-os-website` container reachable at `http://evidence-os-website:80` on the `proxy` network.

- [ ] **Step 1: Write `docker-compose.yml`**

No compose predecessor exists for this app (scaffolded directly in k3s) — this is a new file, built purely from the current k3s Deployment/Service (public GHCR image, stateless, no env vars, no volumes, confirmed via `kubectl get deploy evidence-os-website -n workloads -o yaml`).

```yaml
services:
  evidence-os-website:
    image: ghcr.io/bridgetlai/evidence-os-website:21aab6e7a2ec2d7a7afeb57519186fa934d92cd9
    container_name: evidence-os-website
    hostname: evidence-os-website
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
    networks:
      - proxy
    # NPM 反代配置: Forward Hostname/IP = evidence-os-website, Forward Port = 80（未发布到宿主机）

networks:
  proxy:
    external: true
```

- [ ] **Step 2: Bring it up and verify internally**

```bash
mkdir -p /home/ubuntu/jerome/docker-gitops/vps_oracle/compose/evidence-os-website
cd /home/ubuntu/jerome/docker-gitops/vps_oracle/compose/evidence-os-website
docker compose up -d
docker compose ps
docker run --rm --network proxy curlimages/curl -sf -o /dev/null -w '%{http_code}\n' http://evidence-os-website:80/
```

Expected: `Up`, curl prints `200`.

- [ ] **Step 3: Commit**

```bash
cd /home/ubuntu/jerome/docker-gitops
git add vps_oracle/compose/evidence-os-website/
git commit -m "Add evidence-os-website compose stack (new — no prior compose history)"
```

---

### Task 4: `evidence-os-website` — NPM cutover

**Files:** none.

**Interfaces:**
- Depends on: Task 3.
- Produces: `evidence.jerome.cloudns.asia` served by the compose container.

- [ ] **Step 1: Fetch a fresh API token, then PATCH proxy host id 29**

```bash
source /home/ubuntu/jerome/docker-gitops/vps_oracle/compose/npm/.npm-automation.env
TOKEN=$(docker exec npm sh -c "curl -s -X POST http://localhost:81/api/tokens \
  -H 'Content-Type: application/json' \
  -d '{\"identity\":\"$NPM_AUTOMATION_EMAIL\",\"secret\":\"$NPM_AUTOMATION_PASSWORD\"}' | jq -r .token")
docker exec npm sh -c "curl -s -H 'Authorization: Bearer $TOKEN' http://localhost:81/api/nginx/proxy-hosts/29 | \
  jq '.forward_host = \"evidence-os-website\" | .forward_port = 80' > /tmp/npm-29.json"
docker exec npm sh -c "curl -s -X PUT http://localhost:81/api/nginx/proxy-hosts/29 \
  -H 'Authorization: Bearer $TOKEN' -H 'Content-Type: application/json' \
  -d @/tmp/npm-29.json"
docker exec npm grep -E 'set +\$server|set +\$port' /data/nginx/proxy_host/29.conf
```

Expected: `set $server "evidence-os-website";`, `set $port 80;`. Reload nginx (`docker exec npm nginx -s reload`) if the file didn't update.

- [ ] **Step 2: Verify externally**

```bash
curl -sf -o /dev/null -w '%{http_code}\n' https://evidence.jerome.cloudns.asia/
```

Expected: `200`.

---

### Task 5: `trilium` — data migration

**Files:** none (host filesystem + k3s state only).

**Interfaces:**
- Depends on: nothing.
- Produces: `/etc/trilium/data` populated with trilium's real notes DB, owned `1000:1000`. Task 6 mounts this path.

This is the **only live copy** of trilium's notes (the old compose bind mount `/etc/trilium/data` and the git-tracked old compose file are both gone). Do not skip the scale-to-0 step — copying while the pod is live risks grabbing a torn sqlite WAL file.

- [ ] **Step 1: Stop the k3s trilium pod (stops writes)**

```bash
kubectl scale deployment trilium -n workloads --replicas=0
kubectl wait --for=delete pod -l app=trilium -n workloads --timeout=60s
```

- [ ] **Step 2: Copy the PVC's backing directory to the new compose bind-mount path**

```bash
sudo mkdir -p /etc/trilium/data
sudo cp -a /var/lib/rancher/k3s/storage/pvc-7773c3fb-d5a9-4927-87dc-929316773079_workloads_trilium/. /etc/trilium/data/
sudo chown -R 1000:1000 /etc/trilium/data
```

- [ ] **Step 3: Verify the copy**

```bash
ls -la /etc/trilium/data
```

Expected: `config.ini`, `document.db`, `document.db-shm`, `document.db-wal`, `session_secret.txt`, `backup/`, `log/`, `tmp/` — all owned `1000:1000`, sizes matching the source (`document.db` ~4MB).

---

### Task 6: `trilium` — compose file, bring up, verify

**Files:**
- Create: `vps_oracle/compose/trilium/docker-compose.yml`

**Interfaces:**
- Depends on: Task 5 (`/etc/trilium/data` must be populated first).
- Produces: a running `trilium` container reachable at `http://trilium:8080` on the `proxy` network, serving the migrated notes.

- [ ] **Step 1: Write `docker-compose.yml`**

```yaml
services:
  trilium:
    image: ghcr.io/jeromefromcn/trilium@sha256:e88f87b97d31a6304fe9798148f3585d818fa2640f65e36a52a99c8d79f79614
    container_name: trilium
    hostname: trilium
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
    volumes:
      - /etc/trilium/data:/home/node/trilium-data
    networks:
      - proxy
    # NPM 反代配置: Forward Hostname/IP = trilium, Forward Port = 8080（未发布到宿主机）

networks:
  proxy:
    external: true
```

Same CVE-patched digest k3s currently runs (`vps_oracle/k3s/images/trilium/Dockerfile`, same `v0.104.1` base + npm 11.19.0). No `user:`/`runAsUser` override — the image's entrypoint starts as root and self-drops to uid 1000; forcing a different startup UID breaks it (confirmed by k3s's own manifest deliberately omitting this).

- [ ] **Step 2: Bring it up and verify internally**

```bash
mkdir -p /home/ubuntu/jerome/docker-gitops/vps_oracle/compose/trilium
cd /home/ubuntu/jerome/docker-gitops/vps_oracle/compose/trilium
docker compose up -d
docker compose ps
docker logs trilium --tail 50
docker run --rm --network proxy curlimages/curl -sf -o /dev/null -w '%{http_code}\n' http://trilium:8080/
```

Expected: `Up`, logs show no crash/permission errors, curl prints `200` (trilium's login page).

- [ ] **Step 3: Commit**

```bash
cd /home/ubuntu/jerome/docker-gitops
git add vps_oracle/compose/trilium/
git commit -m "Add trilium compose stack, rebuilt from k3s state with migrated notes"
```

---

### Task 7: `trilium` — NPM cutover

**Files:** none.

**Interfaces:**
- Depends on: Task 6.
- Produces: `trilium.jerome.cloudns.asia` served by the compose container.

- [ ] **Step 1: Fetch a fresh API token, then PATCH proxy host id 18**

```bash
source /home/ubuntu/jerome/docker-gitops/vps_oracle/compose/npm/.npm-automation.env
TOKEN=$(docker exec npm sh -c "curl -s -X POST http://localhost:81/api/tokens \
  -H 'Content-Type: application/json' \
  -d '{\"identity\":\"$NPM_AUTOMATION_EMAIL\",\"secret\":\"$NPM_AUTOMATION_PASSWORD\"}' | jq -r .token")
docker exec npm sh -c "curl -s -H 'Authorization: Bearer $TOKEN' http://localhost:81/api/nginx/proxy-hosts/18 | \
  jq '.forward_host = \"trilium\" | .forward_port = 8080' > /tmp/npm-18.json"
docker exec npm sh -c "curl -s -X PUT http://localhost:81/api/nginx/proxy-hosts/18 \
  -H 'Authorization: Bearer $TOKEN' -H 'Content-Type: application/json' \
  -d @/tmp/npm-18.json"
docker exec npm grep -E 'set +\$server|set +\$port' /data/nginx/proxy_host/18.conf
```

- [ ] **Step 2: Verify externally — confirm existing notes are present, not a blank instance**

```bash
curl -sf -o /dev/null -w '%{http_code}\n' https://trilium.jerome.cloudns.asia/
```

Expected: `200`. Then open `https://trilium.jerome.cloudns.asia/` in a browser and confirm the existing note tree loads (not the first-run setup screen) — this is the real proof the data migration in Task 5 worked, not just that the container starts.

---

### Task 8: `dify` — restore compose files from git history

**Files:**
- Create: `vps_oracle/compose/dify/docker-compose.yml`
- Create: `vps_oracle/compose/dify/README.md`
- Create: `vps_oracle/compose/dify/ssrf_proxy/docker-entrypoint.sh`
- Create: `vps_oracle/compose/dify/ssrf_proxy/squid.conf.template`

**Interfaces:**
- Depends on: nothing.
- Produces: compose files ready for `.env` (Task 9) and data (Task 9/10) before `up -d`.

Research already confirmed **zero drift** between the deleted pre-migration compose file and the current k3s manifests — every image digest, env var, URL, and internal secret constant (`SERVER_KEY`, `DIFY_INNER_API_KEY`, `PLUGIN_DAEMON_KEY`, `INNER_API_KEY_FOR_PLUGIN`) matches exactly. Restore verbatim from the commit right before deletion — no edits needed.

- [ ] **Step 1: Restore the 4 files verbatim from git history**

```bash
cd /home/ubuntu/jerome/docker-gitops
mkdir -p vps_oracle/compose/dify/ssrf_proxy
git show 1e6bcf9053236825183b2d0c9ceceaa55e3bb881^:vps_oracle/compose/dify/docker-compose.yml \
  > vps_oracle/compose/dify/docker-compose.yml
git show 1e6bcf9053236825183b2d0c9ceceaa55e3bb881^:vps_oracle/compose/dify/README.md \
  > vps_oracle/compose/dify/README.md
git show 1e6bcf9053236825183b2d0c9ceceaa55e3bb881^:vps_oracle/compose/dify/ssrf_proxy/docker-entrypoint.sh \
  > vps_oracle/compose/dify/ssrf_proxy/docker-entrypoint.sh
git show 1e6bcf9053236825183b2d0c9ceceaa55e3bb881^:vps_oracle/compose/dify/ssrf_proxy/squid.conf.template \
  > vps_oracle/compose/dify/ssrf_proxy/squid.conf.template
chmod +x vps_oracle/compose/dify/ssrf_proxy/docker-entrypoint.sh
```

- [ ] **Step 2: Diff-check against the current k3s manifests to reconfirm no drift before proceeding**

```bash
diff <(grep -oE 'image: [^ ]+' vps_oracle/compose/dify/docker-compose.yml | sort) \
     <(kubectl get deploy,statefulset -n dify -o jsonpath='{range .items[*]}{.spec.template.spec.containers[0].image}{"\n"}{end}' | sort)
```

Expected: no meaningful diff (compose lines include the `image:` YAML key prefix, k8s output doesn't — confirm the digests themselves match by eye). If any digest differs, stop and update the restored `docker-compose.yml` to match the live digest before continuing — the whole point of this migration is to match k3s's current state.

- [ ] **Step 3: Do NOT commit yet** — this stack needs `.env` (Task 9) and data (Task 9/10) before it can run; commit happens at the end of Task 10 once verified working.

---

### Task 9: `dify` — extract secrets and dump live databases (while k3s dify is still running)

**Files:**
- Create: `vps_oracle/compose/dify/.env` (gitignored, never committed)

**Interfaces:**
- Depends on: Task 8 (needs the `.env` variable names the restored `docker-compose.yml` expects: `DB_PASSWORD`, `PGVECTOR_PASSWORD`, `REDIS_PASSWORD`, `SECRET_KEY`, `INIT_PASSWORD`).
- Produces: `.env` with live secret values, plus 3 dump/snapshot files under `/tmp/dify-migration/` consumed by Task 10. Must run before Task 10's scale-down (the dumps need the source databases still up).

This must reuse the **exact same** `SECRET_KEY`/DB passwords the live install uses — regenerating them would invalidate existing sessions, encrypted credentials, and admin accounts in the database being restored in Task 10.

- [ ] **Step 1: Write `.env` directly from the live k8s Secret (values never printed to a terminal/log)**

```bash
cd /home/ubuntu/jerome/docker-gitops/vps_oracle/compose/dify
{
  echo "DB_PASSWORD=$(kubectl get secret dify-secrets -n dify -o jsonpath='{.data.DB_PASSWORD}' | base64 -d)"
  echo "PGVECTOR_PASSWORD=$(kubectl get secret dify-secrets -n dify -o jsonpath='{.data.PGVECTOR_PASSWORD}' | base64 -d)"
  echo "REDIS_PASSWORD=$(kubectl get secret dify-secrets -n dify -o jsonpath='{.data.REDIS_PASSWORD}' | base64 -d)"
  echo "SECRET_KEY=$(kubectl get secret dify-secrets -n dify -o jsonpath='{.data.SECRET_KEY}' | base64 -d)"
  echo "INIT_PASSWORD=$(kubectl get secret dify-secrets -n dify -o jsonpath='{.data.INIT_PASSWORD}' | base64 -d)"
} > .env
chmod 600 .env
wc -l .env
```

Expected: `wc -l` reports `5` (5 lines written) — this confirms the file has content without ever displaying the values.

- [ ] **Step 2: Dump both Postgres instances with `pg_dumpall` (captures all databases + roles in each instance — `db-postgres` may hold both `dify` and an auto-created `dify_plugin` database)**

```bash
mkdir -p /tmp/dify-migration
kubectl exec -n dify db-postgres-0 -- pg_dumpall -U postgres -f /tmp/all.sql
kubectl cp dify/db-postgres-0:/tmp/all.sql /tmp/dify-migration/db-postgres-all.sql
kubectl exec -n dify pgvector-0 -- pg_dumpall -U postgres -f /tmp/all.sql
kubectl cp dify/pgvector-0:/tmp/all.sql /tmp/dify-migration/pgvector-all.sql
ls -la /tmp/dify-migration/
```

Expected: both `.sql` files present and non-trivial in size (several hundred KB+ depending on how much data exists).

- [ ] **Step 3: Snapshot Redis (reads `REDIS_PASSWORD` from the pod's own already-injected env var — never typed into this command)**

```bash
kubectl exec -n dify redis-0 -- sh -c 'redis-cli -a "$REDIS_PASSWORD" BGSAVE'
sleep 3
kubectl exec -n dify redis-0 -- sh -c 'redis-cli -a "$REDIS_PASSWORD" LASTSAVE'
kubectl cp dify/redis-0:/data/dump.rdb /tmp/dify-migration/redis-dump.rdb
```

Run `LASTSAVE` twice a few seconds apart if unsure whether the BGSAVE finished — the timestamp should have advanced.

---

### Task 10: `dify` — stop k3s workloads, copy file-based data, bring up compose, restore databases, verify internally

**Files:** none (host filesystem + Docker state).

**Interfaces:**
- Depends on: Task 8 (compose files), Task 9 (`.env` + dumps must exist first — this task's Step 1 stops the source pods).
- Produces: a fully running 9-container dify stack with data restored, internally verified. Task 11 (NPM cutover) depends on this.

- [ ] **Step 1: Scale every dify workload to 0 (stops writes; the dumps/snapshot from Task 9 are already captured)**

```bash
kubectl scale deployment api worker worker-beat plugin-daemon web ssrf-proxy -n dify --replicas=0
kubectl scale statefulset db-postgres pgvector redis -n dify --replicas=0
kubectl wait --for=delete pod --all -n dify --timeout=90s
```

- [ ] **Step 2: Copy the two file-based PVCs (plugin storage + shared api/worker storage) to host bind-mount paths**

```bash
sudo mkdir -p /etc/dify/{db-data,pgvector-data,redis-data,plugin-daemon-storage,storage}
sudo cp -a /var/lib/rancher/k3s/storage/pvc-725b2716-6b62-46f3-9adf-7dabeb2f8615_dify_plugin-daemon/. /etc/dify/plugin-daemon-storage/
sudo cp -a /var/lib/rancher/k3s/storage/pvc-38a3381a-28e5-454b-8a00-578944cd6781_dify_storage/. /etc/dify/storage/
sudo chown -R 1001:1001 /etc/dify/storage
```

`1001` matches the `api`/`worker` containers' runtime uid, per the restored README's documented reasoning (this host's `ubuntu` user happens to also be uid 1001).

- [ ] **Step 3: Copy the Redis RDB snapshot into place**

```bash
sudo cp /tmp/dify-migration/redis-dump.rdb /etc/dify/redis-data/dump.rdb
```

- [ ] **Step 4: Bring up only the two Postgres containers first (need them healthy before restoring SQL dumps)**

```bash
cd /home/ubuntu/jerome/docker-gitops/vps_oracle/compose/dify
docker compose up -d db_postgres pgvector
docker compose ps
```

Wait until both show `healthy` (their `pg_isready` healthchecks) — `docker compose ps` polling, or `docker inspect --format '{{.State.Health.Status}}' dify-db dify-pgvector`.

- [ ] **Step 5: Restore both databases from the `pg_dumpall` dumps**

```bash
docker exec -i dify-db psql -U postgres < /tmp/dify-migration/db-postgres-all.sql
docker exec -i dify-pgvector psql -U postgres < /tmp/dify-migration/pgvector-all.sql
```

- [ ] **Step 6: Verify the restore — row counts should be non-zero if the install has any real usage**

```bash
docker exec dify-db psql -U postgres -d dify -c "\dt" | head -20
docker exec dify-pgvector psql -U postgres -d dify -c "SELECT count(*) FROM embeddings;" 2>/dev/null || \
  docker exec dify-pgvector psql -U postgres -d dify -c "\dt"
```

Expected: `dify`'s `\dt` lists dify's normal table set (apps, accounts, etc., not empty); pgvector's table set is present too.

- [ ] **Step 7: Bring up the rest of the stack**

```bash
docker compose up -d
docker compose ps
```

Expected: all 9 containers `Up`; `dify-api` and `dify-web` show `healthy` once their healthchecks pass (api's healthcheck has a 30s `start_period`, be patient).

- [ ] **Step 8: Verify internally**

```bash
docker logs dify-api --tail 80
docker logs dify-web --tail 80
docker run --rm --network proxy curlimages/curl -sf http://dify-api:5001/health
docker run --rm --network proxy curlimages/curl -sf -o /dev/null -w '%{http_code}\n' http://dify-web:3000/
```

Expected: `/health` returns healthy JSON, `dify-web` returns `200`, no error-level logs referencing DB/Redis connection failures.

- [ ] **Step 9: Commit the dify compose stack**

```bash
cd /home/ubuntu/jerome/docker-gitops
git add vps_oracle/compose/dify/
git commit -m "Add dify compose stack, rebuilt from k3s state with migrated data"
```

---

### Task 11: `dify` — NPM cutover

**Files:** none.

**Interfaces:**
- Depends on: Task 10 (all 9 containers healthy).
- Produces: `dify.jerome.cloudns.asia` served by the compose stack across all its custom locations.

`dify`'s proxy host (id 24) has multiple Custom Locations, not just a single forward target — each one needs its own `forward_host`/`forward_port` patched.

- [ ] **Step 1: Fetch a fresh API token, patch every location, and PUT back the full object (per the documented gotcha: partial updates to a multi-location host can silently fail to re-render the on-disk conf — always resend the complete `locations` array)**

```bash
source /home/ubuntu/jerome/docker-gitops/vps_oracle/compose/npm/.npm-automation.env
TOKEN=$(docker exec npm sh -c "curl -s -X POST http://localhost:81/api/tokens \
  -H 'Content-Type: application/json' \
  -d '{\"identity\":\"$NPM_AUTOMATION_EMAIL\",\"secret\":\"$NPM_AUTOMATION_PASSWORD\"}' | jq -r .token")
docker exec npm sh -c "curl -s -H 'Authorization: Bearer $TOKEN' http://localhost:81/api/nginx/proxy-hosts/24 | \
  jq '
    .forward_host = \"dify-web\" | .forward_port = 3000 |
    .locations = (.locations | map(
      if .path == \"/e/\" then .forward_host = \"dify-plugin-daemon\" | .forward_port = 5002
      else .forward_host = \"dify-api\" | .forward_port = 5001
      end
    ))
  ' > /tmp/npm-24.json"
docker exec npm sh -c "curl -s -X PUT http://localhost:81/api/nginx/proxy-hosts/24 \
  -H 'Authorization: Bearer $TOKEN' -H 'Content-Type: application/json' \
  -d @/tmp/npm-24.json"
```

- [ ] **Step 2: Verify the on-disk conf actually updated, for both the default location and at least one custom location**

```bash
docker exec npm grep -E 'set +\$server|set +\$port|proxy_pass' /data/nginx/proxy_host/24.conf
```

Expected: `set $server "dify-web"`, `set $port 3000`, and `proxy_pass http://dify-api:5001;` / `proxy_pass http://dify-plugin-daemon:5002;` in the relevant location blocks. If any still show the old `10.0.0.95:3008x` values, run `docker exec npm nginx -s reload` and re-check — if still stale after reload, follow the README's documented manual-`sed`-the-conf-file fallback (`docker exec npm cat /data/nginx/proxy_host/24.conf`, edit with `docker exec npm sed -i ...`, `nginx -t`, `nginx -s reload`).

- [ ] **Step 3: Verify externally — log in with the existing admin account and confirm data survived**

```bash
curl -sf -o /dev/null -w '%{http_code}\n' https://dify.jerome.cloudns.asia/
curl -sf -o /dev/null -w '%{http_code}\n' https://dify.jerome.cloudns.asia/console/api/health 2>/dev/null || true
```

Then open `https://dify.jerome.cloudns.asia/` in a browser, log in with the existing account, and confirm at least one pre-existing app/workflow is listed and opens — this proves the Postgres/pgvector restore in Task 10 preserved real data, not just that empty databases boot cleanly.

---

### Task 12: k3s cleanup — remove ArgoCD tracking and delete underlying resources

**Files:**
- Modify: `vps_oracle/k3s/argocd/apps/homepage.yaml` (delete)
- Modify: `vps_oracle/k3s/argocd/apps/trilium.yaml` (delete)
- Modify: `vps_oracle/k3s/argocd/apps/dify.yaml` (delete)
- Modify: `vps_oracle/k3s/argocd/apps/evidence-os-website.yaml` (delete)

**Interfaces:**
- Depends on: Tasks 2, 4, 7, 11 (every app must be cut over to compose and externally verified *before* this task runs — this is the point of no easy rollback for the k3s side).
- Produces: no more ArgoCD-managed resources for these 4 apps; frees their `workloads`/`dify` namespace resource-quota headroom.

- [ ] **Step 1: Check each Application's finalizers, so you know whether deleting cascades**

```bash
for app in homepage trilium dify evidence-os-website; do
  echo "=== $app ==="
  kubectl get application $app -n argocd -o jsonpath='{.metadata.finalizers}'
  echo
done
```

If a finalizer (`resources-finalizer.argocd.argoproj.io`) is present for any app, deleting that Application will cascade-delete its managed resources — factor that into Step 3 below (skip the manual delete for that app, since it'll happen automatically). If empty (`[]` or nothing printed, which is what the committed manifests suggest — none declare a finalizer), deleting only removes ArgoCD's tracking object and Step 3's manual deletes are required.

- [ ] **Step 2: Remove the 4 Application manifests and push, so root stops tracking them**

```bash
cd /home/ubuntu/jerome/docker-gitops
git rm vps_oracle/k3s/argocd/apps/homepage.yaml vps_oracle/k3s/argocd/apps/trilium.yaml \
       vps_oracle/k3s/argocd/apps/dify.yaml vps_oracle/k3s/argocd/apps/evidence-os-website.yaml
git commit -m "Remove ArgoCD Applications for services migrated back to compose"
git push origin main
```

Wait for the `root` Application's next auto-sync (or force it: `argocd app sync root`, or via the ArgoCD UI) — confirm via `kubectl get applications -n argocd` that `homepage`/`trilium`/`dify`/`evidence-os-website` are gone.

- [ ] **Step 3: Manually delete the underlying k8s resources for any app whose Application had no finalizer in Step 1**

```bash
kubectl delete namespace dify
kubectl delete deployment homepage trilium evidence-os-website -n workloads
kubectl delete service homepage trilium evidence-os-website -n workloads
kubectl delete pvc trilium -n workloads
kubectl get configmap -n workloads | grep homepage-config | awk '{print $1}' | xargs -r kubectl delete configmap -n workloads
```

- [ ] **Step 4: Confirm the cluster is clean**

```bash
kubectl get all -n workloads
kubectl get ns dify
```

Expected: `workloads` shows only the still-migrated apps (`apprise`, `placeholder-hello`, `vikunja`, `vikunja-notify-relay`); `dify` namespace reports `NotFound`.

---

### Task 13: k3s cleanup — remove app source manifests, update docs, final commit

**Files:**
- Delete: `vps_oracle/k3s/apps/homepage/` (entire directory)
- Delete: `vps_oracle/k3s/apps/trilium/` (entire directory)
- Delete: `vps_oracle/k3s/apps/dify/` (entire directory)
- Delete: `vps_oracle/k3s/apps/evidence-os-website/` (entire directory)
- Keep: `vps_oracle/k3s/images/homepage/Dockerfile`, `vps_oracle/k3s/images/trilium/Dockerfile`, and the `patched-images.yml` CI workflow — still needed to (re)build the CVE-patched images the new compose files consume; these have no k3s-runtime dependency.
- Modify: `vps_oracle/README.md`
- Modify: `vps_oracle/k3s/README.md` (if it separately lists phase status for these apps — check during execution)

**Interfaces:**
- Depends on: Task 12 (only remove source manifests once the live resources are already gone — otherwise ArgoCD's `selfHeal: true` would recreate them from git before the Application-removal sync lands).
- Produces: final, consistent repo state — no orphaned references to k3s-hosted versions of these 4 apps.

- [ ] **Step 1: Delete the app manifest directories**

```bash
cd /home/ubuntu/jerome/docker-gitops
git rm -r vps_oracle/k3s/apps/homepage vps_oracle/k3s/apps/trilium \
          vps_oracle/k3s/apps/dify vps_oracle/k3s/apps/evidence-os-website
```

- [ ] **Step 2: Update `vps_oracle/README.md` — remove these 4 from the "migrated to k3s" list**

Change this sentence (currently lists all migrated services together):

```
截至目前（phase D 进行中）：叢集基礎（K3s + Cilium + local-path 存儲）、ArgoCD app-of-apps GitOps 迴路、以及 `homepage`/`trilium`/`vikunja`/`apprise`/`llm`（llama-cpp/open-webui）/`dify`（9 容器全家桶，独立 `dify` 命名空间）已经迁移完成并从 k3s 提供服务；其余服务仍在 `<host>/compose/` 下运行，见下方「不会迁移到 k3s 的服务」。
```

to:

```
截至目前（phase D 进行中）：叢集基礎（K3s + Cilium + local-path 存儲）、ArgoCD app-of-apps GitOps 迴路、以及 `vikunja`/`apprise`/`llm`（llama-cpp/open-webui）已经迁移完成并从 k3s 提供服务；`homepage`/`trilium`/`dify` 曾短暂迁移到 k3s，2026-08-18 评估后迁回 compose（详见 `docs/superpowers/plans/2026-08-18-k3s-to-compose-migration.md`）；`evidence-os-website` 同样迁回 compose，不再在 k3s 原生托管；其余服务仍在 `<host>/compose/` 下运行，见下方「不会迁移到 k3s 的服务」。
```

- [ ] **Step 3: Rewrite the "给新服务加 homepage 卡片" section back to the plain-compose flow**

Replace the entire section (currently describes the k3s Kustomize/ConfigMap-hash flow, lines ~88-108 of the current file) with:

```markdown
## 给新服务加 homepage 卡片

配置源文件是 **`vps_oracle/compose/homepage/config/services.yaml`**。每新增一个服务，在对应分类（`Infra Services` / `Apps`）下加一张卡片，跟现有条目保持同样格式：

\`\`\`yaml
    - <服务名>:
        icon: <icon-name>.png
        href: https://<service>.jerome.cloudns.asia
        description: <一句话描述，英文>
\`\`\`

- `icon`：优先用 [walkxcode/dashboard-icons](https://github.com/walkxcode/dashboard-icons) 里对应的文件名（homepage 会自动去 CDN 拉）；没有专门图标的用 `si-<name>`（simple-icons）顶替，如 `si-anthropic`
- `description`：访客可见，按下面"暴露内容用英文"的约定用英文
- 没有 `container`/`server` 字段——迁回 compose 后这个字段本可以恢复（挂 docker.sock），但 2026-08-18 决定继续不挂，保持跟迁移前 k3s 状态一致，只做卡片本身
- **例外**：安全敏感的服务（如 3x-ui）不上卡片，加之前先问一句

改完后 `cd vps_oracle/compose/homepage && docker compose up -d` 直接生效，不用 push/ArgoCD。
```

- [ ] **Step 4: Check `vps_oracle/k3s/README.md` for the same 4 apps' phase status**

```bash
grep -n -E "homepage|trilium|dify|evidence-os-website" /home/ubuntu/jerome/docker-gitops/vps_oracle/k3s/README.md
```

For any line describing these apps as currently migrated/live on k3s, update it to note the 2026-08-18 reversal, consistent with Step 2's wording.

- [ ] **Step 5: Commit**

```bash
cd /home/ubuntu/jerome/docker-gitops
git add -A vps_oracle/k3s/ vps_oracle/README.md
git commit -m "Remove k3s manifests for services migrated back to compose, update docs"
git push origin main
```

---

## Verification (end-to-end, after all 13 tasks)

- [ ] All 4 domains load over HTTPS with the compose containers as the sole backend: `for d in homepage trilium dify evidence; do curl -sf -o /dev/null -w "$d: %{http_code}\n" https://$d.jerome.cloudns.asia/; done` (adjust `evidence` vs `evidence-os-website` domain naming — actual domain is `evidence.jerome.cloudns.asia`).
- [ ] `kubectl get applications -n argocd` no longer lists `homepage`/`trilium`/`dify`/`evidence-os-website`.
- [ ] `kubectl get ns` no longer lists `dify`; `workloads` namespace only has the apps still meant to stay on k3s.
- [ ] `git log --oneline -8` shows one commit per app stack plus the two cleanup commits, each scoped (no mixed-stack commits).
- [ ] Raw data backups (`/tmp/dify-migration/*.sql`, the Redis `.rdb`) are still present on disk — keep for a few days before anyone deletes them, per the rollback-safety note below.

## Rollback safety

Task 12 (deleting k3s resources) is the point of no easy return — until then, the k3s workloads for each app are simply scaled to 0 (not deleted) and NPM can be flipped back to `10.0.0.95:<nodeport>` instantly if a compose cutover looks wrong. Don't run Task 12/13 for an app until its Task-2/4/7/11 external verification step passed for real (browser-checked, not just `curl` 200).
