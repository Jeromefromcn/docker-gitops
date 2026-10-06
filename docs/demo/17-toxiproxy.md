# 17 — Network faults on a dependency (Toxiproxy)

## Purpose
Put Toxiproxy between visits-service and its data stores, then make the
network misbehave: first slow Redis, then a black hole in front of
Postgres. Watch the mesh's 1 s per-try timeout answer for the caller while
the app keeps waiting on its own, far longer, timeouts.

## Preconditions
Preflight passed; 15 reset. Costs two visits-service rollouts (in and
out).

## Before you start: open the views
1. **Grafana — Lab Mesh Overview**, last 15 minutes, auto-refresh 10 s:
   <https://grafana.lab.jerome.cloudns.asia/d/lab-mesh-overview/lab-mesh-overview?from=now-15m&to=now&refresh=10s>
   **Envoy response flags**: `UT` is the waypoint's upstream timeout.
   Nothing for visits-service yet.
2. **Grafana — Lab Endpoint Detail for visits-service `GET /pets/visits`**,
   last 15 minutes, auto-refresh 10 s:
   <https://grafana.lab.jerome.cloudns.asia/d/lab-endpoint-detail/lab-endpoint-detail?var-service=visits-service&var-method=GET&var-uri=%2Fpets%2Fvisits&var-window_s=300&from=now-15m&to=now&refresh=10s>
   **Max latency**: well under a second. This is visits-service's own
   measure of how long it worked on a request.
3. **Grafana — Explore**, data source **Loki**, last 15 minutes. The
   waypoint's log of visits-service requests that did not succeed:
   ```logql
   {service="istio-proxy"} | json | authority=~"visits-service.*" | response_code!="200" | line_format "{{.response_code}} {{.response_flags}} {{.duration_ms}}ms {{.path}}"
   ```

## Steps

### 1. Wire visits-service through Toxiproxy
```bash
# Bring the checkout up to date with origin/main
git pull --ff-only origin main
```
Toxiproxy is already deployed but sits outside the data path. Four
edits put it in.

**`k3s/apps/lab-environment/k8s/toxiproxy.yaml`**: give Toxiproxy two
proxies to serve.
- Before the `Deployment`, add its config:
  ```yaml
  # Demo-only (docs/demo/17): the two proxies visits-service is pointed at.
  apiVersion: v1
  kind: ConfigMap
  metadata:
    name: toxiproxy-config
    namespace: lab-environment
  data:
    toxiproxy.json: |
      [
        {"name": "postgres", "listen": "0.0.0.0:5432", "upstream": "postgres:5432", "enabled": true},
        {"name": "redis", "listen": "0.0.0.0:6379", "upstream": "redis:6379", "enabled": true}
      ]
  ---
  ```
- In the Deployment's pod `spec`, under `enableServiceLinks: false`, add
  the volume:
  ```yaml
        volumes:
          - name: config
            configMap:
              name: toxiproxy-config
  ```
- In the `toxiproxy` container, under its `image:` line, add:
  ```yaml
            args: ["-host=0.0.0.0", "-config=/config/toxiproxy.json"]
            volumeMounts:
              - name: config
                mountPath: /config
  ```
- In the same container's `limits`, raise `cpu: 25m` to `cpu: 200m`: it
  now carries real traffic.
- In the `Service`, under the existing `api` port, add:
  ```yaml
      - port: 5432
        targetPort: 5432
        name: postgres
      - port: 6379
        targetPort: 6379
        name: redis
  ```

**`k3s/apps/lab-environment/k8s/visits-service.yaml`**: in the container's
`env`, under `SPRING_CLOUD_CONSUL_PORT`, point both data stores at the
proxy:
```yaml
            # Demo-only (docs/demo/17): route postgres and redis through
            # toxiproxy. Env beats the Consul KV values (data.db.host,
            # data.redis.host), which stay untouched.
            - name: DATA_DB_HOST
              value: "toxiproxy"
            - name: DATA_REDIS_HOST
              value: "toxiproxy"
```

**`k3s/apps/lab-environment/k8s/authz.yaml`**: Postgres and Redis only
admit the identities they know. Now the connection comes from
Toxiproxy's identity, not visits', so add
`- cluster.local/ns/lab-environment/sa/toxiproxy` to the `principals` list
of both `postgres-clients` (after `sa/db-init`) and `redis-clients` (after
`sa/visits-service`).

```bash
# Review: toxiproxy config, visits env, and the two grants
git diff

# Commit to main with the demo: prefix
git commit -m "demo: route visits-service's data stores through toxiproxy" -- k3s/apps/lab-environment/k8s

# Push; ArgoCD deploys from git
git push
```
In ArgoCD, click **Refresh**. toxiproxy restarts with its config, and
visits-service rolls to pick up the new env (~2 minutes).

### 2. Check the proxy and warm visits up
```bash
# Shortcut for toxiproxy-cli inside the toxiproxy pod
T="kubectl -n lab-environment exec deploy/toxiproxy -- /toxiproxy-cli"

# Base URL of the owners API, via the lab ingress
U=http://10.0.0.95:30097/api/customer/owners

# List the proxies; expect postgres and redis, no toxics
$T list

# visits just restarted: a cold JVM's first requests can take over 1 s and
# would 504 before any toxic. Warm it on owners the steps below do not use
for i in $(seq 1 10); do curl -s -o /dev/null $U/6/visits; curl -s -o /dev/null $U/9/visits; done

# Through the proxy, no toxic yet: expect 200 in ~0.2 s
for i in 1 2 3; do curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' $U/6/visits; done
```

### 3. Slow Redis
```bash
# Add 1.5 s of latency to Redis
$T toxic add -t latency -a latency=1500 redis

# Expect 504 at ~1 s: the mesh's per-try timeout answers for the caller
for i in 1 2 3; do curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' $U/6/visits; done

# Remove the Redis latency
$T toxic remove -n latency_downstream redis
```
`504` at ~1.01 s. Now and then a fast `502` appears instead: the
connection the timed-out request left behind was closed under the next
one, which the waypoint logs as `503 UC`.

In the Loki tab, run the query again: `504 UT 10xxms /pets/visits`. The
waypoint gave up after its 1 s per-try timeout. On Lab Mesh Overview,
**Envoy response flags** shows a `visits-service UT` line.

### 4. Black-hole Postgres
```bash
# Black-hole Postgres: connections hang and no data flows
$T toxic add -t timeout -a timeout=0 postgres

# Owners the traffic generator never reads: their visits are not in the
# 60 s Redis cache, so the request really goes to Postgres
for o in 3 5 7; do curl -s -o /dev/null -w "owner $o %{http_code} %{time_total}s\n" $U/$o/visits; done
```
`504` at ~1.01 s for each.

Now look at the app's side. On the visits-service Endpoint Detail tab,
**Max latency** climbs far above 1 s. The mesh answered the caller after
one second, but visits-service kept the thread and the database
connection waiting on its own timeouts, and finished long after the
client had gone.

### 5. Recover without a restart
```bash
# Remove the Postgres black hole
$T toxic remove -n timeout_downstream postgres

# Same owners again: expect 200 at once, no rollout needed
for o in 3 5 7; do curl -s -o /dev/null -w "owner $o %{http_code} %{time_total}s\n" $U/$o/visits; done
```
`200` at once.

### 6. The mesh saw the detour
ztunnel, the node's L4 proxy, logs every connection with the identity of
both ends when the connection closes. The black hole in step 4 closed
visits' pooled database connections, so they are on record now:
```bash
# The ztunnel on the lab node
Z=$(kubectl -n istio-system get pods -l app=ztunnel --field-selector spec.nodeName=vps-oracle2 -o name)

# visits-service -> toxiproxy on the postgres port
kubectl -n istio-system logs $Z --since=10m | grep 'src.workload="visits-service.*dst.service="toxiproxy' | grep -c ':5432'

# toxiproxy -> postgres, under toxiproxy's own identity
kubectl -n istio-system logs $Z --since=10m | grep -c 'src.identity="spiffe://cluster.local/ns/lab-environment/sa/toxiproxy".*dst.service="postgres'
```
Both counts are non-zero (10 each in the rehearsal). Postgres saw
toxiproxy's identity, not visits', which is why the grant in step 1 was
needed.

### 7. Roll back
```bash
# Roll back: revert the demo commit
git revert --no-edit HEAD

# Push; ArgoCD deploys the rollback
git push
```
In ArgoCD, click **Refresh**. visits-service rolls back to its direct
connections, and Postgres and Redis stop admitting Toxiproxy's identity.

## Talking points
- **Network faults vs 05's toggle.** 05's chaos is the app cooperating
  (`redis-timeout` makes it throw on purpose). Here the app opted into
  nothing: it just finds its network slow or silent.
- **The mesh is the backstop.** visits' own Redis timeout is 2 s and
  Hikari waits 30 s for a connection; the waypoint's 1 s `perTryTimeout`
  answers the caller long before either. The app, meanwhile, keeps the
  thread and the connection busy. 504/UT is not in `retryOn`, so there is
  one attempt, not three.
- **Recovery without a restart.** When the black hole is removed, Hikari
  fails validation on the stalled connections, drops them and opens new
  ones — the next request is already `200`.
- **Least privilege is weaker for exactly as long as the demo lasts.** While
  the proxy sits in the path, Postgres and Redis see toxiproxy's identity,
  not visits'. The revert takes the grant away.
- **Ready is not warm.** visits' first requests after the rollout can take
  over 1 s (cold JVM) and hit the same 504 the toxics produce — hence the
  warm-up (rehearsal 2026-09-29, twice: one 504 before any toxic without
  it).
- **Toxiproxy is not resident in the data path** — production would not
  have it. It stays deployed with its own (unprivileged) identity; only the
  wiring is temporary.

## Reset
The page's revert undoes the wiring and the grant (one more visits
rollout). Before the next page, check that visits no longer points at the
proxy:
```bash
# Expect no DATA_DB_HOST / DATA_REDIS_HOST in the list
kubectl -n lab-environment get deploy visits-service -o jsonpath='{.spec.template.spec.containers[0].env[*].name}'; echo
```
