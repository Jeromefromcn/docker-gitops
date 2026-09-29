# Lab PR Lanes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A PR on the fork gets its own lane in `lab-environment` — CI-built, scanned and signed, deployed by ArgoCD next to the baseline, reached only by requests carrying `x-pr-lane: <N>` across every hop — and the whole lab runs only signed GHCR images.

**Architecture:** Fork CI (`lab-images.yml`, native arm64) → GHCR → Trivy → Cosign. The baseline is promoted by a digest-pinned git commit here. A matrix ApplicationSet (service list × PR generator filtered by `lane:<service>`) renders one `lanes/<service>/` kustomize per labelled service: a Deployment with the baseline's ServiceAccount but `app: <service>-lane`, a Service, and a header-only HTTPRoute parented on the baseline Service, evaluated before the resident VirtualService. Micrometer baggage carries the header across RestTemplate hops. Kyverno verifies signatures (a looser signer rule for lane pods) and refuses non-GHCR images for business services.

**Tech Stack:** GitHub Actions (arm64 runners), Maven / Spring Boot 4.0.1 / Micrometer Tracing, GHCR, Trivy, Cosign keyless, Kyverno 1.18.2, ArgoCD 3.5.0 ApplicationSet, Istio ambient waypoint + Gateway API HTTPRoute, kustomize 5.8, bash + jq + python3/PyYAML tests.

**Spec:** [`docs/superpowers/specs/2026-09-29-lab-pr-lanes-design.md`](../specs/2026-09-29-lab-pr-lanes-design.md) (Task 1 corrects it).

## Global Constraints

- Every push that touches `k3s/` is approved by the owner first (memory: `feedback_k3s_push_needs_approval`). Pushes to the fork are approved too (outward-facing).
- Lab roadmap work commits straight to `main`, one logical change per commit, English commit messages ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Other sessions may commit to `main` in the same checkout: `git status` and `git log -3` before every commit, `git pull --ff-only` before every push.
- Fork: `/home/ubuntu/jerome/spring-petclinic-microservices` (`Jeromefromcn/spring-petclinic-microservices`, public, branches `main`, `lab-v2`).
- Image names: `ghcr.io/jeromefromcn/petclinic-<service>` for `<service>` ∈ `api-gateway customers-service vets-service visits-service`; negative-test image `ghcr.io/jeromefromcn/petclinic-unsigned:demo`.
- Baseline image refs are **digest-pinned** — `ghcr.io/jeromefromcn/petclinic-<service>@sha256:<digest> # fork <sha12>` — because `restrict-image-registry` has the default `verifyDigest: true` (hello's baseline is pinned the same way). Lane refs are tags (`:<head_sha>`), allowed by `verifyDigest: false` on the lane rule.
- Lane header: `x-pr-lane`, value = PR number. Lane label on pods: `lab.jerome/lane: pr-<N>`. Lane pod `app` label: `<service>-lane`, **never** `<service>`.
- Signer subjects: baseline `…/spring-petclinic-microservices/.github/workflows/lab-images.yml@refs/heads/(main|lab-v2)`; lanes additionally `@refs/pull/<N>/merge`.
- Capacity: at most 2 lane pods at once; lanes never coexist with page 12's 5-replica green. Lane pods request 384Mi / 20m like the baseline.
- `customers-service`'s VirtualService/DestinationRule and pages 09–13 do not change (patches only get their image lines rewritten in Task 5).
- Execution ledger (gitignored): `.superpowers/sdd/2026-09-29-lab-pr-lanes/progress.md` — rulings, measurements, deviations. Append after every task.

## Review Focus

1. **A lane pod selected by the baseline Service** (a lane manifest carrying `app: <service>`) — ordinary traffic would silently reach PR code. Pinned by `tests/test-lanes.sh` (Task 7).
2. **Lane manifest drifting from the baseline** (env, SA, resources, probes) — a lane that fails for config reasons looks like a PR bug. Pinned by `tests/test-lanes.sh`'s equality check (Task 7).
3. **A leftover lane pod** after a demo (PR not closed, label not removed, finalizer stuck) — it eats the blue-green headroom and page 12 then hits `FailedCreate`. Pinned by the `routing_baseline` lane check and its stub tests (Task 8).
4. **The ApplicationSet's patches missing a renamed field** (selector not patched → two lanes' Services select each other's pods; header value not patched → every lane answers `x-pr-lane: 0`). Pinned by `tests/test-lanes.sh` rendering the appset's patches against each lane base (Task 7).
5. **A demo patch no longer applying** after the canary image line changes — page 10/13 would fail live. Pinned by the existing `git apply --check` in `tests/test-demo-helpers.sh`, run in Task 5.

---

### Task 1: Correct the spec before building on it

Five facts found while planning change the spec. Fix it first so the plan and spec agree.

**Files:**
- Modify: `docs/superpowers/specs/2026-09-29-lab-pr-lanes-design.md`

- [ ] **Step 1: Apply the corrections**

1. Blue-green is **page 12**, not page 10 (09 instance ratio, 10 weight, 11 header, 12 blue-green, 13 mirror). Replace every "page 10" / "10's" that refers to the 5-replica green with page 12 (Decisions table "Capacity" row, §3 bullets, §4 "Demo order", §5 "Capacity", §5 "Service choice", Implementation order step 6 "page 10's precondition", acceptance criterion references). "Demo order: 18 … must not overlap 10" becomes "must not overlap 12".
2. §1 Fork CI trigger table: PR builds select services **by changed paths**, not by label — replace the `pull_request` row with: `pull_request` (`opened`, `synchronize`, `reopened`) | the services whose `spring-petclinic-<service>/` directory the PR changes; all four if the root `pom.xml` or `docker/` changes. Add a bullet: "Why not by label: a label triggers the ApplicationSet (polling every 30 s) and CI at the same moment, so the lane pod would be created minutes before its image is signed and Kyverno would refuse it (`FailedCreate`, then ReplicaSet backoff). Building on every PR push means the image is signed before anyone adds the label; the page waits for CI, then labels." Also add `workflow_dispatch` (inputs `sha`, `unsigned`) — used to build the two `lab-v2` commits the canary patches pin (`ce942c9` v2, `16b18eb` v2-bad), and to publish the unsigned negative-test image `ghcr.io/jeromefromcn/petclinic-unsigned:demo`.
3. §1 Baseline promotion: baseline refs are digest-pinned (`@sha256:` with a `# fork <sha12>` comment) because `restrict-image-registry` keeps the default `verifyDigest: true`.
4. §1 Kyverno, `require-vuln-scan-clean` bullet: replace with "the `app` list gains the four lab services. It only bites when a VulnerabilityReport exists, and lab pods carry `trivy-operator.skip` (added 2026-09-24 because local `ops-lab/*` images could not be scanned). The four baseline Deployments drop that label once they run GHCR images; `customers-service-canary` (normally 0 replicas) and lane pods keep it — lanes are short-lived and CI's Trivy step is their gate. As for hello, a new ReplicaSet's first pod is admitted before its report exists; CI's Trivy step is the primary gate."
5. §1 "Possible owner action" becomes a confirmed one: `k3s/README.md` "Rotating the GitHub PAT" scopes the token to `Jeromefromcn/docker-gitops` only, so the owner must regenerate it with the fork added (Task 6).
6. §4 Evidence: the Kyverno pass evidence is the Pod annotation `kyverno.io/verify-images` (`{"<image>":"pass"}`), confirmed on hello's pods 2026-09-29. The flow's visible change is a response header `X-Visits-Build: lane` added by a commit on the fork branch `demo/pr-lane`, which is kept for reuse (the PR is closed, not merged).

- [ ] **Step 2: Commit**

```bash
git status --short && git log --oneline -3
git add docs/superpowers/specs/2026-09-29-lab-pr-lanes-design.md
git commit -F - <<'EOF'
docs: correct the PR lanes spec from planning findings

Blue-green is page 12, not 10. PR images are built on changed paths so
they are signed before the lane label creates a pod. Baseline refs are
digest-pinned for verifyDigest. The vulnerability gate needs the lab's
trivy-operator.skip label dropped. The PR generator token must be
regenerated with the fork added.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

### Task 2: Spike — header HTTPRoute ahead of the resident VirtualService (live, hand-applied)

Verifies the one assumption the routing design rests on. **Stop and report to the owner if any check fails** — the design goes back to the spec.

**Files:**
- Create (scratch only, never committed): `$SCRATCH/spike-lane.yaml` where `SCRATCH` is the session scratchpad directory.
- Ledger: `.superpowers/sdd/2026-09-29-lab-pr-lanes/progress.md`

- [ ] **Step 1: Confirm the lab is at baseline**

Run: `k3s/apps/lab-environment/demo/demo-reset preflight`
Expected: `baseline OK`. If not, stop — do not spike on a dirty lab.

- [ ] **Step 2: Write the spike manifest**

A lane of visits-service on its **current baseline image** with a marker env, a Service, the header HTTPRoute, and a temporary L4 policy (without it no ALLOW policy selects the pod and anyone could reach it; with it only the waypoint can).

```yaml
# $SCRATCH/spike-lane.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: visits-service-spike
  namespace: lab-environment
  labels: {app: visits-service-lane, lab.jerome/lane: spike}
spec:
  replicas: 1
  strategy: {type: Recreate}
  selector:
    matchLabels: {app: visits-service-lane, lab.jerome/lane: spike}
  template:
    metadata:
      labels: {app: visits-service-lane, lab.jerome/lane: spike, trivy-operator.skip: "true"}
    spec:
      serviceAccountName: visits-service
      enableServiceLinks: false
      containers:
        - name: visits-service
          image: ops-lab/visits-service:21d8461c6ce4
          env:
            - {name: TZ, value: "Asia/Hong_Kong"}
            - {name: SPRING_CLOUD_CONSUL_HOST, value: "consul"}
            - {name: SPRING_CLOUD_CONSUL_PORT, value: "8500"}
            - name: DATA_DB_PASSWORD
              valueFrom: {secretKeyRef: {name: lab-db-credentials, key: password}}
            - {name: SPRING_SQL_INIT_MODE, value: "never"}
            - {name: SPRING_DATASOURCE_HIKARI_MAXIMUMPOOLSIZE, value: "5"}
            - {name: JAVA_TOOL_OPTIONS, value: "-Xmx192m -Xms64m -XX:MaxDirectMemorySize=64m -XX:MaxRAM=512m"}
            - {name: MALLOC_ARENA_MAX, value: "2"}
          ports: [{containerPort: 8082}]
          resources:
            requests: {cpu: 20m, memory: 384Mi}
            limits: {cpu: 1000m, memory: 768Mi}
          startupProbe:
            httpGet: {path: /actuator/health/liveness, port: 8082}
            periodSeconds: 5
            failureThreshold: 60
          readinessProbe:
            httpGet: {path: /actuator/health/readiness, port: 8082}
            periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: visits-service-spike
  namespace: lab-environment
spec:
  selector: {app: visits-service-lane, lab.jerome/lane: spike}
  ports: [{port: 8082, targetPort: 8082}]
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: visits-service-spike
  namespace: lab-environment
spec:
  parentRefs:
    - {group: "", kind: Service, name: visits-service}
  rules:
    - matches:
        - headers:
            - {name: x-pr-lane, value: "999"}
      backendRefs:
        - {name: visits-service-spike, port: 8082}
      timeouts: {request: 3s}
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: lane-direct-spike
  namespace: lab-environment
spec:
  selector:
    matchLabels: {lab.jerome/lane: spike}
  action: ALLOW
  rules:
    - from:
        - source: {principals: [cluster.local/ns/lab-environment/sa/waypoint]}
```

- [ ] **Step 3: Apply and wait**

ArgoCD's `lab-environment` app only prunes resources it tracks, so these untracked objects survive its sync.

```bash
kubectl apply -f "$SCRATCH/spike-lane.yaml"
kubectl -n lab-environment rollout status deploy/visits-service-spike --timeout=6m
```
Expected: `successfully rolled out`.

- [ ] **Step 4: Check routing — header goes to the lane, everything else to the baseline**

```bash
T0=$(date +%s)
U=http://10.0.0.95:30097
for i in $(seq 1 10); do curl -s -o /dev/null -w '%{http_code}\n' -H 'x-pr-lane: 999' "$U/api/visit/pets/visits?petId=1"; done | sort | uniq -c
for i in $(seq 1 10); do curl -s -o /dev/null -w '%{http_code}\n' "$U/api/visit/pets/visits?petId=1"; done | sort | uniq -c
sleep 40; T1=$(date +%s)
Q='sum by (upstream_cluster) (count_over_time({service="istio-proxy"} | json | __error__="" | authority=~"visits-service.*" ['$((T1-T0))'s]))'
curl -sf -G http://10.0.0.95:30094/api/datasources/proxy/uid/loki/loki/api/v1/query --data-urlencode "query=$Q" --data-urlencode "time=${T1}000000000" | jq -r '.data.result[] | "\(.value[1]) \(.metric.upstream_cluster)"'
```
Expected: 20 × `200`; Loki shows exactly **10** on an upstream cluster containing `visits-service-spike` and the rest (≥ 10, plus generator traffic) on `visits-service.lab-environment…`. Record the exact `upstream_cluster` string of the lane in the ledger — Task 8's evidence parses it.

- [ ] **Step 5: Check the resident policy still applies to header-less traffic**

```bash
k3s/apps/lab-environment/demo/demo-reset preflight
kubectl -n lab-environment exec deploy/waypoint -- pilot-agent request GET 'config_dump?resource=dynamic_route_configs' \
  | jq -r '.configs[].route_config.virtual_hosts[]? | select(.name | test("visits-service")) | .routes[] | "\(.match | tojson) -> \(.route.cluster // .route.weighted_clusters // "?") retries=\(.route.retry_policy.num_retries // 0) timeout=\(.route.timeout // "-")"'
```
(`istioctl` is not installed on vps_oracle; the waypoint's own `pilot-agent` serves the Envoy config dump. If the jq path prints nothing, dump `.configs[0] | keys` and adjust — the route list is what matters.)
Expected: `baseline OK` (customers pin, rate-limit TrafficExtension, generator clean). The route list shows the header-matched route to `visits-service-spike` **first** and the VirtualService routes (GET with `retries=2`, `timeout=3s`; others `timeout=5s`) after it. If the VirtualService routes are gone or the header route is not first, **stop**: record the dump in the ledger and report.

- [ ] **Step 6: Check the rate limit still applies on vets**

```bash
for i in $(seq 1 30); do curl -s -o /dev/null -w '%{http_code}\n' http://10.0.0.95:30097/api/vet/vets; done | sort | uniq -c
```
Expected: some `429` (the resident limiter: ~6 admitted per second).

- [ ] **Step 7: Remove the spike and confirm the baseline**

```bash
kubectl delete -f "$SCRATCH/spike-lane.yaml"
k3s/apps/lab-environment/demo/demo-reset preflight
```
Expected: `baseline OK`.

- [ ] **Step 8: Record in the ledger**

Append to `.superpowers/sdd/2026-09-29-lab-pr-lanes/progress.md`: date, the 10/10 split, the lane's `upstream_cluster` string, the waypoint route order, the 429 check. Nothing to commit (the ledger is gitignored).

---

### Task 3: Fork — baggage propagation and the `lab-images` workflow

**Files (fork repo):**
- Modify: `spring-petclinic-{api-gateway,customers-service,vets-service,visits-service}/src/main/resources/application.yml` (the `management.tracing` block of the first document)
- Create: `.github/workflows/lab-images.yml`

**Interfaces:**
- Produces: images `ghcr.io/jeromefromcn/petclinic-<service>:<sha>` (full 40-char SHA), signed by `…/lab-images.yml@refs/heads/<branch>` or `@refs/pull/<N>/merge`; each build job writes `<service> <image>@<digest>` to the run's job summary. `workflow_dispatch` inputs `sha` (string) and `unsigned` (boolean).

- [ ] **Step 1: Add the baggage config to all four services**

In each of the four `application.yml` files, replace

```yaml
  tracing:
    sampling:
      probability: 1
```

(first document, under `management:`) with

```yaml
  tracing:
    sampling:
      probability: 1
    # x-pr-lane selects a PR lane at every hop (docker-gitops lab PR lanes):
    # remote-fields copies the incoming header onto instrumented outgoing
    # calls, tag-fields puts it on the span (searchable in Jaeger),
    # correlation puts it in the log MDC.
    baggage:
      remote-fields: x-pr-lane
      tag-fields: x-pr-lane
      correlation:
        fields: x-pr-lane
```

- [ ] **Step 2: Build locally to catch YAML mistakes**

Run (fork root): `./mvnw -B -q -pl spring-petclinic-api-gateway,spring-petclinic-customers-service,spring-petclinic-vets-service,spring-petclinic-visits-service -am package -DskipTests`
Expected: exit 0. (Propagation itself is verified live in Task 5 — it needs the mesh.)

- [ ] **Step 3: Write the workflow**

```yaml
# .github/workflows/lab-images.yml
# Builds the lab's business-service images for docker-gitops' lab-environment:
# build (native arm64) -> push to GHCR -> Trivy -> Cosign keyless sign.
# Kyverno in the cluster admits only images signed by this workflow file.
name: lab-images

on:
  push:
    branches: [main, lab-v2]
  pull_request:
    types: [opened, synchronize, reopened]
  workflow_dispatch:
    inputs:
      sha:
        description: Commit to build (default = the ref the workflow runs on)
        required: false
        default: ''
      unsigned:
        description: Push only visits-service as ghcr.io/jeromefromcn/petclinic-unsigned:demo and skip signing (negative-test image)
        type: boolean
        default: false

permissions:
  contents: read
  packages: write
  id-token: write

jobs:
  plan:
    runs-on: ubuntu-latest
    outputs:
      services: ${{ steps.pick.outputs.services }}
      sha: ${{ steps.pick.outputs.sha }}
    steps:
      - name: Checkout
        uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - name: Pick services and commit
        id: pick
        env:
          EVENT: ${{ github.event_name }}
          BASE: ${{ github.event.pull_request.base.sha }}
          HEAD: ${{ github.event.pull_request.head.sha }}
          INPUT_SHA: ${{ inputs.sha }}
          UNSIGNED: ${{ inputs.unsigned }}
        run: |
          all='["api-gateway","customers-service","vets-service","visits-service"]'
          case "$EVENT" in
            pull_request)
              sha=$HEAD
              changed=$(git diff --name-only "$BASE" "$HEAD")
              if grep -qE '^(pom\.xml|docker/)' <<< "$changed"; then
                services=$all
              else
                # grep exits 1 on no match; with the runner's pipefail that
                # would fail the step instead of yielding [].
                services=$({ grep -oP '^spring-petclinic-\K(api-gateway|customers-service|vets-service|visits-service)(?=/)' <<< "$changed" || true; } \
                  | sort -u | jq -R . | jq -sc .)
              fi ;;
            workflow_dispatch)
              sha=${INPUT_SHA:-$GITHUB_SHA}
              if [ "$UNSIGNED" = true ]; then services='["visits-service"]'; else services=$all; fi ;;
            *)
              sha=$GITHUB_SHA; services=$all ;;
          esac
          echo "sha=$sha" >> "$GITHUB_OUTPUT"
          echo "services=$services" >> "$GITHUB_OUTPUT"
          echo "Building $services at $sha" >> "$GITHUB_STEP_SUMMARY"

  build-scan-sign:
    needs: plan
    if: needs.plan.outputs.services != '[]'
    runs-on: ubuntu-24.04-arm
    strategy:
      fail-fast: false
      matrix:
        service: ${{ fromJSON(needs.plan.outputs.services) }}
    env:
      IMAGE: ${{ inputs.unsigned && 'ghcr.io/jeromefromcn/petclinic-unsigned' || format('ghcr.io/jeromefromcn/petclinic-{0}', matrix.service) }}
      TAG: ${{ inputs.unsigned && 'demo' || needs.plan.outputs.sha }}
      MODULE: spring-petclinic-${{ matrix.service }}
    steps:
      - name: Checkout
        uses: actions/checkout@v4
        with:
          ref: ${{ needs.plan.outputs.sha }}

      - name: Set up JDK 17
        uses: actions/setup-java@v4
        with:
          java-version: '17'
          distribution: temurin
          cache: maven

      # Native arm64 runner: QEMU emulation crashes in the layertools extract
      # step of docker/Dockerfile (lab-environment/scripts/build.sh).
      - name: Build the jar
        run: ./mvnw -B -pl "$MODULE" -am package -DskipTests

      - name: Locate the jar
        id: jar
        run: |
          jar=$(ls "$MODULE"/target/"$MODULE"-*.jar | grep -v -- '-plain\.jar$' | head -1)
          echo "name=$(basename "$jar" .jar)" >> "$GITHUB_OUTPUT"

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
          context: ${{ env.MODULE }}/target
          file: docker/Dockerfile
          platforms: linux/arm64
          # EXPOSED_PORT is only the image's EXPOSE metadata; the services'
          # real ports come from their config (8080-8083).
          build-args: |
            ARTIFACT_NAME=${{ steps.jar.outputs.name }}
            EXPOSED_PORT=8080
          push: true
          tags: ${{ env.IMAGE }}:${{ env.TAG }}

      - name: Scan image with Trivy
        uses: aquasecurity/trivy-action@v0.36.0
        env:
          TRIVY_PLATFORM: linux/arm64
        with:
          image-ref: ${{ env.IMAGE }}:${{ env.TAG }}
          severity: CRITICAL
          exit-code: '1'
          ignore-unfixed: true

      - name: Install Cosign
        if: ${{ !inputs.unsigned }}
        uses: sigstore/cosign-installer@v4.1.2
        with:
          cosign-release: v3.1.3

      - name: Sign image (keyless)
        if: ${{ !inputs.unsigned }}
        env:
          IMAGE_REF: ${{ env.IMAGE }}@${{ steps.build.outputs.digest }}
        run: cosign sign --yes "$IMAGE_REF"

      - name: Record the digest
        run: echo "${{ matrix.service }} ${{ env.IMAGE }}@${{ steps.build.outputs.digest }}" >> "$GITHUB_STEP_SUMMARY"
```

- [ ] **Step 4: Lint the workflow**

Run (fork root): `docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:latest .github/workflows/lab-images.yml`
Expected: no output, exit 0.

- [ ] **Step 5: Commit on `main`, then put the workflow on `lab-v2` too**

`workflow_dispatch` runs the workflow file of the ref it is dispatched on, so `lab-v2` needs the file.

```bash
cd /home/ubuntu/jerome/spring-petclinic-microservices
git status --short
git add spring-petclinic-*/src/main/resources/application.yml
git commit -m "Propagate x-pr-lane as tracing baggage across services" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git add .github/workflows/lab-images.yml
git commit -m "Build, scan and sign the lab images in CI" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git checkout lab-v2 && git cherry-pick main && git checkout main
```

- [ ] **Step 6: Ask the owner, then push both branches**

Show `git log --oneline -3 main lab-v2`. After approval:

```bash
git push origin main lab-v2
```
The push to `main` builds all four baseline images; the push to `lab-v2` builds its head (the cherry-pick, which carries v2-bad's code).

- [ ] **Step 7: Build the two canary commits the demo patches pin, and the unsigned image**

```bash
gh workflow run lab-images.yml -R Jeromefromcn/spring-petclinic-microservices --ref lab-v2 -f sha=ce942c9e7124
gh workflow run lab-images.yml -R Jeromefromcn/spring-petclinic-microservices --ref lab-v2 -f sha=16b18ebc7230
gh workflow run lab-images.yml -R Jeromefromcn/spring-petclinic-microservices --ref main -f unsigned=true
```
`ce942c9e7124` is the canary's v2 (`X-App-Version` header), `16b18ebc7230` is v2-bad (the patches' bad build). Note: dispatched on `lab-v2`, the jar is built from the old commit but the workflow file comes from `lab-v2`'s head — which is why Step 5 cherry-picked it.

- [ ] **Step 8: Wait for all runs and verify signatures**

```bash
end=$((SECONDS + 1800)); until [ -z "$(gh run list -R Jeromefromcn/spring-petclinic-microservices -w lab-images.yml --json status -q '.[] | select(.status != "completed") | .status')" ]; do [ $SECONDS -lt $end ] || { echo "CI WAIT TIMED OUT"; break; }; sleep 30; done
gh run list -R Jeromefromcn/spring-petclinic-microservices -w lab-images.yml -L 6 --json conclusion,headBranch,event,databaseId
for s in api-gateway customers-service vets-service visits-service; do
  cosign verify "ghcr.io/jeromefromcn/petclinic-$s:$(git rev-parse main)" \
    --certificate-identity-regexp '^https://github\.com/Jeromefromcn/spring-petclinic-microservices/\.github/workflows/lab-images\.yml@refs/heads/main$' \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com >/dev/null && echo "OK $s" || echo "FAIL $s"
done
```
Expected: every run `success`; four `OK`. If `cosign` is not installed locally, use `docker run --rm cgr.dev/chainguard/cosign verify …` with the same arguments. Make the GHCR packages public if they are not: `gh api -X PATCH /user/packages/container/petclinic-<service>/visibility -f visibility=public` is not available for user packages — do it in the GitHub UI (Package settings → Change visibility → Public) and **ask the owner** if it needs their hand. Check anonymously: `docker logout ghcr.io; docker manifest inspect ghcr.io/jeromefromcn/petclinic-visits-service:$(git rev-parse main) >/dev/null && echo public`.

- [ ] **Step 9: Record the digests in the ledger**

From each run's summary (`gh run view <id> -R Jeromefromcn/spring-petclinic-microservices`), copy the `Record the digest` lines **verbatim** into the ledger (`<service> <image>@sha256:<digest>`), each under a heading naming its source: `main <fork sha12>`, `lab-v2 ce942c9e7124`, `lab-v2 16b18ebc7230`, `unsigned`. Tasks 4 and 5 grep them by image name.

---

### Task 4: Kyverno — fork signer, lane rule, GHCR-only rule (Audit), vuln gate

**Files:**
- Modify: `k3s/kyverno/policies/restrict-image-registry.yaml`
- Create: `k3s/kyverno/policies/restrict-image-registry-lab-lanes.yaml`
- Create: `k3s/kyverno/policies/lab-business-images-from-ghcr.yaml`
- Modify: `k3s/kyverno/policies/require-vuln-scan-clean.yaml`
- Modify: `k3s/kyverno/policies/README.md` (one row per new policy, matching its table)

**Interfaces:**
- Consumes: Task 3's signer subjects.
- Produces: ClusterPolicies `restrict-image-registry-lab-lanes`, `lab-business-images-from-ghcr` (Audit) used by Tasks 5, 7, 8.

- [ ] **Step 1: Write the failing check**

The Task 3 images must be refused today (wrong signer):

```bash
D=$(grep -oP 'ghcr\.io/jeromefromcn/petclinic-visits-service@sha256:[0-9a-f]+' .superpowers/sdd/2026-09-29-lab-pr-lanes/progress.md | head -1)
cat > "$SCRATCH/probe-signed.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata: {name: probe-signed, namespace: lab-environment, labels: {app: visits-service}}
spec:
  containers:
    - name: c
      image: $D
      resources: {requests: {cpu: 10m, memory: 16Mi}}
EOF
kubectl apply --dry-run=server -f "$SCRATCH/probe-signed.yaml"
```
Expected now: **refused** by `restrict-image-registry` (no matching signer). This probe must pass after Step 4.

- [ ] **Step 2: Edit `restrict-image-registry.yaml`**

Replace the rule's `exclude` block and `subjectRegExp`:

```yaml
      exclude:
        any:
          - resources:
              namespaces:
                - pr-lanes
          # Lab PR lanes carry lab.jerome/lane and are verified by
          # restrict-image-registry-lab-lanes, which also accepts PR builds.
          - resources:
              namespaces:
                - lab-environment
              selector:
                matchExpressions:
                  - key: lab.jerome/lane
                    operator: Exists
```

```yaml
                    subjectRegExp: "^https://github\\.com/Jeromefromcn/(docker-gitops/\\.github/workflows/[^/]+\\.yml@refs/heads/main|spring-petclinic-microservices/\\.github/workflows/lab-images\\.yml@refs/heads/(main|lab-v2))$"
```

- [ ] **Step 3: Create the two new policies**

```yaml
# k3s/kyverno/policies/restrict-image-registry-lab-lanes.yaml
# Signature verification for lab PR lanes (docs/superpowers/specs/2026-09-29-lab-pr-lanes-design.md).
# Lane pods (lab.jerome/lane) are excluded from restrict-image-registry and
# verified here instead, where a pull_request build of the fork's lab-images
# workflow (signed as refs/pull/<N>/merge) is also accepted. verifyDigest is
# off because lanes reference the PR head SHA as a tag, like pr-lanes.
#
# Known gap, accepted: anyone who can create a Pod in lab-environment can add
# the label and get this looser signer rule. Single-operator cluster; the rule
# is confined to this one namespace.
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: restrict-image-registry-lab-lanes
spec:
  validationFailureAction: Enforce
  webhookTimeoutSeconds: 30
  rules:
    - name: verify-lab-lane-signature
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - lab-environment
              selector:
                matchExpressions:
                  - key: lab.jerome/lane
                    operator: Exists
      verifyImages:
        - imageReferences:
            - "ghcr.io/jeromefromcn/*"
          type: SigstoreBundle
          mutateDigest: false
          verifyDigest: false
          attestors:
            - entries:
                - keyless:
                    subjectRegExp: "^https://github\\.com/Jeromefromcn/spring-petclinic-microservices/\\.github/workflows/lab-images\\.yml@refs/(heads/main|pull/[0-9]+/merge)$"
                    issuer: "https://token.actions.githubusercontent.com"
                    rekor:
                      url: https://rekor.sigstore.dev
```

```yaml
# k3s/kyverno/policies/lab-business-images-from-ghcr.yaml
# verifyImages only checks references that match ghcr.io/jeromefromcn/* — a
# locally built ops-lab/* image never matches, so it would be admitted
# unverified. This closes that: the lab's business services (and their PR
# lanes) run only CI-built GHCR images, which the restrict-image-registry*
# policies then verify.
# Audit while the baseline still runs ops-lab/* images; Enforce once every
# business Deployment is on GHCR (lab PR lanes plan, Task 5).
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: lab-business-images-from-ghcr
spec:
  validationFailureAction: Audit
  background: true
  rules:
    - name: business-images-from-ghcr
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - lab-environment
              selector:
                matchExpressions:
                  - key: app
                    operator: In
                    values:
                      - api-gateway
                      - customers-service
                      - vets-service
                      - visits-service
                      - api-gateway-lane
                      - customers-service-lane
                      - vets-service-lane
                      - visits-service-lane
      validate:
        message: >-
          {{ request.object.metadata.name }}: lab business services run only
          CI-built images from ghcr.io/jeromefromcn/ — a local ops-lab/* build
          is refused.
        pattern:
          spec:
            containers:
              - image: "ghcr.io/jeromefromcn/*"
```

- [ ] **Step 4: Extend `require-vuln-scan-clean.yaml`'s `values:` list**

```yaml
                    values:
                      - hello-frontend
                      - hello-backend
                      - api-gateway
                      - customers-service
                      - vets-service
                      - visits-service
```

- [ ] **Step 5: Validate the YAML and add the README rows**

Run: `for f in k3s/kyverno/policies/*.yaml; do kubectl apply --dry-run=client -f "$f" >/dev/null || echo "BAD $f"; done`
Expected: no `BAD`. Add a row for each new policy to `k3s/kyverno/policies/README.md`, in its existing table format.

- [ ] **Step 6: Commit, ask, push, wait for sync**

```bash
git status --short && git log --oneline -3
git add k3s/kyverno/policies/
git commit -F - <<'EOF'
k3s: verify lab images signed by the fork's CI

restrict-image-registry accepts the fork's lab-images workflow on main
and lab-v2; lab PR lanes get their own rule that also accepts PR builds.
lab-business-images-from-ghcr (Audit for now) refuses non-GHCR images
for the lab's business services, which verifyImages alone would admit.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```
Ask the owner; after approval: `git pull --ff-only && git push`. Then:
```bash
argocd app get kyverno --core --refresh >/dev/null
end=$((SECONDS + 300)); until kubectl get clusterpolicy lab-business-images-from-ghcr restrict-image-registry-lab-lanes -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -qx 'True True'; do [ $SECONDS -lt $end ] || { echo "POLICY WAIT TIMED OUT"; break; }; sleep 5; done
```
(If the Application that owns `k3s/kyverno/policies` is not named `kyverno`, use the name from `k3s/argocd/apps/kyverno.yaml`.)

- [ ] **Step 7: Run the probes**

```bash
kubectl apply --dry-run=server -f "$SCRATCH/probe-signed.yaml"
U=$(grep -oP 'petclinic-unsigned@sha256:[0-9a-f]+' .superpowers/sdd/2026-09-29-lab-pr-lanes/progress.md | head -1)
sed "s|image: .*|image: ghcr.io/jeromefromcn/$U|; s/probe-signed/probe-unsigned/" "$SCRATCH/probe-signed.yaml" > "$SCRATCH/probe-unsigned.yaml"
kubectl apply --dry-run=server -f "$SCRATCH/probe-unsigned.yaml"
kubectl -n lab-environment get pods -l app=visits-service   # still Running on ops-lab/*
```
Expected: `probe-signed` → `created (server dry run)`; `probe-unsigned` → refused by `restrict-image-registry` (no signature); the live pods are untouched (Audit). Record in the ledger.

---

### Task 5: Switch the baseline and canary to GHCR, verify propagation, then Enforce

**Files:**
- Modify: `k3s/apps/lab-environment/k8s/{api-gateway,customers-service,vets-service,visits-service}.yaml` (image line; drop the `trivy-operator.skip: "true"` pod label)
- Modify: `k3s/apps/lab-environment/k8s/customers-service-canary.yaml` (image line only — keeps `trivy-operator.skip`)
- Modify: `k3s/apps/lab-environment/demo/patches/canary-weight.patch`, `mirror.patch` (their `-`/`+ image:` lines)
- Modify: `k3s/apps/lab-environment/tests/test-demo-helpers.sh:185` (the off-git canary image fixture)
- Modify: `k3s/kyverno/policies/lab-business-images-from-ghcr.yaml` (Audit → Enforce, second commit)

**Interfaces:**
- Consumes: Task 3's digests (ledger), Task 4's policies.
- Produces: baseline image refs in the form `ghcr.io/jeromefromcn/petclinic-<service>@sha256:<digest> # fork <sha12>`.

- [ ] **Step 1: Rewrite the image lines**

For each of the four services (digest and 12-char fork SHA from the ledger, `main` build):

```yaml
          image: ghcr.io/jeromefromcn/petclinic-visits-service@sha256:<digest> # fork <sha12>
```
and delete the pod-template line `        trivy-operator.skip: "true"` in those four files only. In `customers-service-canary.yaml`, set the image to the `ce942c9e7124` customers-service digest with `# fork ce942c9e7124`.

- [ ] **Step 2: Rewrite the patches' image lines and the test fixture**

```bash
V2='ghcr.io/jeromefromcn/petclinic-customers-service@sha256:<ce942c9 digest> # fork ce942c9e7124'
V2BAD='ghcr.io/jeromefromcn/petclinic-customers-service@sha256:<16b18eb digest> # fork 16b18ebc7230'
cd k3s/apps/lab-environment
sed -i "s|^-          image: ops-lab/customers-service:ce942c9e7124\$|-          image: $V2|; s|^+          image: ops-lab/customers-service:16b18ebc7230\$|+          image: $V2BAD|" demo/patches/canary-weight.patch demo/patches/mirror.patch
sed -i 's|FAKE_CANARY_IMAGE=ops-lab/customers-service:badbadbadbad|FAKE_CANARY_IMAGE=ghcr.io/jeromefromcn/petclinic-customers-service@sha256:bad|' tests/test-demo-helpers.sh
grep -rn "ops-lab/" demo tests k8s | grep -v mcp-toolkit
```
Expected: the last grep prints nothing.

- [ ] **Step 3: Run the helper tests (patches must still apply)**

Run: `bash k3s/apps/lab-environment/tests/test-demo-helpers.sh | tail -3`
Expected: `ALL PASS`. A patch that fails `git apply --check` shows as `FAIL` — fix its image line, do not regenerate its hunks.

- [ ] **Step 4: Commit, ask, push, watch the rollout**

```bash
git status --short && git log --oneline -3
git add k3s/apps/lab-environment
git commit -F - <<'EOF'
k3s: run the lab's business services on signed GHCR images

The four services and the canary slot move from local ops-lab/* builds
to digest-pinned images the fork's CI built, scanned and signed; the
demo patches pin the matching v2 / v2-bad digests. The four baseline
Deployments drop trivy-operator.skip so the vulnerability gate has
reports to read.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```
Ask the owner (this rolls all four services — ~24-84 s per the README). After approval: `git pull --ff-only && git push`, then:
```bash
argocd app get lab-environment --core --refresh >/dev/null
end=$((SECONDS + 300)); until argocd app get lab-environment --core -o json | jq -e --arg r "$(git rev-parse HEAD)" '.status.operationState.syncResult.revision == $r and .status.operationState.phase == "Succeeded"' >/dev/null; do [ $SECONDS -lt $end ] || { echo "SYNC WAIT TIMED OUT"; break; }; sleep 5; done
for d in api-gateway customers-service vets-service visits-service; do kubectl -n lab-environment rollout status deploy/$d --timeout=8m; done
kubectl -n lab-environment get pods -l 'app in (api-gateway,customers-service,vets-service,visits-service)' -o json | jq -r '.items[] | "\(.metadata.name) \(.metadata.annotations["kyverno.io/verify-images"] // "NO ANNOTATION")"'
k3s/apps/lab-environment/demo/demo-reset preflight
```
Expected: every pod's annotation shows its GHCR digest as `"pass"`; `baseline OK`. If any pod is `FailedCreate` (`kubectl -n lab-environment get events --field-selector reason=FailedCreate`), stop and read the Kyverno message.

- [ ] **Step 5: Verify header propagation customers → visits (Jaeger)**

```bash
T0=$(date +%s)
curl -s -o /dev/null -w '%{http_code}\n' -H 'x-pr-lane: 999' http://10.0.0.95:30097/api/customer/owners/1/visits
sleep 20
curl -sf -G "http://10.0.0.95:30095/api/traces" --data-urlencode service=visits-service --data-urlencode 'tags={"x-pr-lane":"999"}' \
  --data-urlencode "start=${T0}000000" --data-urlencode limit=5 \
  | jq -r '.data[] | [.processes[].serviceName] | unique | join(",")'
```
Expected: `200`, and at least one trace whose services include `api-gateway,customers-service,visits-service`. If none: check the tag on the customers span (`service=customers-service`); if customers has it but visits does not, RestTemplate is not propagating baggage — stop, record, fix in the fork (Task 3) before lanes.

- [ ] **Step 6: Wait for Trivy reports, then Enforce the GHCR-only rule**

```bash
end=$((SECONDS + 1800)); until [ "$(kubectl -n lab-environment get vulnerabilityreports -o json | jq '[.items[] | select(.metadata.labels["trivy-operator.resource.name"] | test("^(api-gateway|customers-service|vets-service|visits-service)-"))] | length')" -ge 4 ]; do [ $SECONDS -lt $end ] || { echo "REPORT WAIT TIMED OUT"; break; }; sleep 30; done
kubectl -n lab-environment get vulnerabilityreports -o json | jq -r '.items[] | "\(.metadata.labels["trivy-operator.resource.name"]) critical=\(.report.summary.criticalCount)"'
```
Expected: four reports. A report with `criticalCount > 0` that has a fix would block the next pod of that ReplicaSet — record it and ask the owner before continuing.

Then in `lab-business-images-from-ghcr.yaml` change `validationFailureAction: Audit` to `Enforce` and replace the header comment's last two lines with `# Enforced since the baseline moved to GHCR (2026-09-29).`

- [ ] **Step 7: Commit, ask, push, run the negative probe**

```bash
git add k3s/kyverno/policies/lab-business-images-from-ghcr.yaml
git commit -F - <<'EOF'
k3s: enforce GHCR-only images for the lab's business services

Every business Deployment now runs a signed GHCR image, so a local
ops-lab/* build is refused instead of reported.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```
After approval and sync:
```bash
sed 's|image: .*|image: ops-lab/visits-service:21d8461c6ce4|; s/probe-signed/probe-local/' "$SCRATCH/probe-signed.yaml" > "$SCRATCH/probe-local.yaml"
kubectl apply --dry-run=server -f "$SCRATCH/probe-local.yaml"
kubectl apply --dry-run=server -f "$SCRATCH/probe-unsigned.yaml"
kubectl apply --dry-run=server -f "$SCRATCH/probe-signed.yaml"
```
Expected: `probe-local` refused by `lab-business-images-from-ghcr`; `probe-unsigned` refused by `restrict-image-registry`; `probe-signed` accepted. Record all three in the ledger (acceptance criteria 1 and 2).

---

### Task 6: Regenerate the PR-generator token with the fork added (owner action)

**Files:**
- Modify: `k3s/sealed-secrets/secrets/github-pr-generator-token.sealed.yaml`
- Modify: `k3s/README.md` ("Rotating the GitHub PAT", step 2)
- Modify: `k3s/sealed-secrets/secrets/README.md` (the token's row)

- [ ] **Step 1: Ask the owner to create the token**

Tell the owner (Chinese): on github.com create a fine-grained PAT, repository access **only** `Jeromefromcn/docker-gitops` and `Jeromefromcn/spring-petclinic-microservices`, permissions Pull requests: Read-only, Contents: Read-only; then run the reseal command from `k3s/README.md` "Rotating the GitHub PAT" step 3 themselves (the token must not pass through this session), and step 4's plaintext check. Wait for them to say it is done.

- [ ] **Step 2: Update the docs**

`k3s/README.md` step 2: "Repository access: **Only** `Jeromefromcn/docker-gitops` and `Jeromefromcn/spring-petclinic-microservices` (the `lab-lanes` ApplicationSet reads the fork's PRs)." `k3s/sealed-secrets/secrets/README.md`: the row's purpose becomes "Fine-grained GitHub PAT for the `pr-lanes` and `lab-lanes` ApplicationSet PR generators".

- [ ] **Step 3: Verify, commit, ask, push**

```bash
grep -q 'ghp_\|github_pat_' k3s/sealed-secrets/secrets/github-pr-generator-token.sealed.yaml && echo STOP || echo OK
git add k3s/sealed-secrets/secrets/github-pr-generator-token.sealed.yaml k3s/README.md k3s/sealed-secrets/secrets/README.md
git commit -F - <<'EOF'
k3s: give the PR generator token read access to the lab fork

The lab-lanes ApplicationSet lists the fork's pull requests with the
same token as pr-lanes.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```
Expected: `OK`. After approval and sync: `kubectl -n argocd get applicationset pr-lanes -o jsonpath='{.status.conditions[?(@.type=="ErrorOccurred")].status}'` prints `False` (the existing generator still works with the new token).

---

### Task 7: Lanes — `lane-direct` policy, lane kustomize bases, render test, ApplicationSet

**Files:**
- Create: `k3s/apps/lab-environment/tests/test-lanes.py`, `k3s/apps/lab-environment/tests/test-lanes.sh`
- Create: `k3s/apps/lab-environment/lanes/<service>/{kustomization.yaml,deployment.yaml,service.yaml,httproute.yaml}` for the four services
- Create: `k3s/argocd/apps/lab-lanes-appset.yaml`
- Modify: `k3s/apps/lab-environment/k8s/authz.yaml` (append `lane-direct`)
- Modify: `.github/workflows/repo-conventions.yml` (job `lab-demo-helpers`: run the lanes test)

**Interfaces:**
- Consumes: Task 4's lane signer rule, Task 6's token.
- Produces: resources named `<service>-pr-<N>` labelled `app: <service>-lane`, `lab.jerome/lane: pr-<N>`; Applications `lab-<service>-pr-<N>`. Task 8 selects lane pods by `lab.jerome/lane`.

- [ ] **Step 1: Write the render test**

`test-lanes.sh` wraps the Python test so CI and humans run one command:

```bash
#!/bin/bash
# Renders every lab PR lane the way the lab-lanes ApplicationSet does and
# checks it against the baseline it shadows. Needs kubectl (kustomize),
# python3 and PyYAML; no cluster access.
set -euo pipefail
exec python3 "$(dirname "$0")/test-lanes.py"
```

```python
#!/usr/bin/env python3
"""Lab PR lanes: render each lanes/<service>/ with the ApplicationSet's own
patches and image override for a sample PR, then check it against the
baseline Deployment in k8s/<service>.yaml."""
import copy, os, shutil, subprocess, sys, tempfile
import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
LAB = os.path.normpath(os.path.join(HERE, ".."))
REPO = os.path.normpath(os.path.join(LAB, "../../.."))
APPSET = os.path.join(REPO, "k3s/argocd/apps/lab-lanes-appset.yaml")
PR, SHA = "42", "0123456789abcdef0123456789abcdef01234567"
fails = []

def check(ok, msg):
    print(("PASS " if ok else "FAIL ") + msg)
    if not ok:
        fails.append(msg)

def fill(text, service):
    return (text.replace("{{.service}}", service).replace("{{.number}}", PR)
                .replace("{{.head_sha}}", SHA))

def render(service, template):
    src = template["spec"]["source"]
    tmp = tempfile.mkdtemp()
    try:
        base = os.path.join(tmp, "base")
        shutil.copytree(os.path.join(LAB, "lanes", service), base)
        kust = {"apiVersion": "kustomize.config.k8s.io/v1beta1", "kind": "Kustomization",
                "resources": ["base"],
                "images": [], "patches": []}
        for img in src["kustomize"]["images"]:
            ref = fill(img, service)
            name, tag = ref.rsplit(":", 1)
            kust["images"].append({"name": name, "newTag": tag})
        for p in src["kustomize"]["patches"]:
            kust["patches"].append({"target": {k: fill(v, service) for k, v in p["target"].items()},
                                    "patch": fill(p["patch"], service)})
        with open(os.path.join(tmp, "kustomization.yaml"), "w") as f:
            yaml.safe_dump(kust, f)
        out = subprocess.run(["kubectl", "kustomize", tmp], check=True, capture_output=True, text=True).stdout
        return {(d["kind"], d["metadata"]["name"]): d for d in yaml.safe_load_all(out) if d}
    finally:
        shutil.rmtree(tmp)

def baseline(service):
    with open(os.path.join(LAB, "k8s", f"{service}.yaml")) as f:
        docs = [d for d in yaml.safe_load_all(f) if d]
    return next(d for d in docs if d["kind"] == "Deployment" and d["metadata"]["name"] == service)

with open(APPSET) as f:
    appset = yaml.safe_load(f)
gens = appset["spec"]["generators"][0]["matrix"]["generators"]
services = [e["service"] for e in gens[0]["list"]["elements"]]
check(sorted(services) == ["api-gateway", "customers-service", "vets-service", "visits-service"],
      f"appset lists the four services ({services})")
check(gens[1]["pullRequest"]["github"]["repo"] == "spring-petclinic-microservices",
      "PR generator reads the fork")
check(gens[1]["pullRequest"]["github"]["labels"] == ["lane:{{.service}}"], "PR generator filters on lane:<service>")
template = appset["spec"]["template"]
check(template["spec"]["destination"]["namespace"] == "lab-environment", "lanes deploy into lab-environment")

for s in services:
    name, lane = f"{s}-pr-{PR}", f"pr-{PR}"
    docs = render(s, template)
    dep, svc, rt = docs.get(("Deployment", name)), docs.get(("Service", name)), docs.get(("HTTPRoute", name))
    check(dep is not None and svc is not None and rt is not None, f"{s}: renders Deployment, Service, HTTPRoute named {name}")
    if not (dep and svc and rt):
        continue
    labels = dep["spec"]["template"]["metadata"]["labels"]
    check(labels.get("app") == f"{s}-lane", f"{s}: pod app label is {s}-lane, never {s}")
    check(labels.get("lab.jerome/lane") == lane, f"{s}: pod carries lab.jerome/lane={lane}")
    check(labels.get("lab.jerome/lane-pod") == "true", f"{s}: pod carries lab.jerome/lane-pod=true (lane-direct selects it)")
    check(dep["spec"]["selector"]["matchLabels"] == {"app": f"{s}-lane", "lab.jerome/lane": lane},
          f"{s}: Deployment selector is per-lane")
    check(svc["spec"]["selector"] == {"app": f"{s}-lane", "lab.jerome/lane": lane}, f"{s}: Service selects only this lane")
    check(dep["spec"]["replicas"] == 1, f"{s}: one replica")
    c = dep["spec"]["template"]["spec"]["containers"][0]
    check(c["image"] == f"ghcr.io/jeromefromcn/petclinic-{s}:{SHA}", f"{s}: image is the PR head SHA ({c['image']})")
    b = baseline(s)
    bc = b["spec"]["template"]["spec"]["containers"][0]
    check(dep["spec"]["template"]["spec"]["serviceAccountName"] == b["spec"]["template"]["spec"]["serviceAccountName"],
          f"{s}: same ServiceAccount as the baseline")
    for field in ("env", "ports", "resources", "startupProbe", "readinessProbe", "lifecycle"):
        check(c.get(field) == bc.get(field), f"{s}: container {field} equals the baseline's")
    rule = rt["spec"]["rules"][0]
    check(rt["spec"]["parentRefs"] == [{"group": "", "kind": "Service", "name": s}], f"{s}: HTTPRoute parented on the baseline Service")
    check(rule["matches"] == [{"headers": [{"name": "x-pr-lane", "value": PR}]}], f"{s}: matches only x-pr-lane: {PR}")
    check([r["name"] for r in rule["backendRefs"]] == [name], f"{s}: routes to {name}")
    check(rule.get("timeouts", {}).get("request") == "3s", f"{s}: 3s request timeout like the VirtualService")

print("ALL PASS" if not fails else f"{len(fails)} FAILED")
sys.exit(1 if fails else 0)
```

- [ ] **Step 2: Run it to see it fail**

Run: `bash k3s/apps/lab-environment/tests/test-lanes.sh`
Expected: FAIL — `FileNotFoundError` for `lab-lanes-appset.yaml`.

- [ ] **Step 3: Create the visits-service lane base**

```yaml
# k3s/apps/lab-environment/lanes/visits-service/kustomization.yaml
# One lab PR lane of visits-service. The lab-lanes ApplicationSet renames
# everything to visits-service-pr-<N>, sets lab.jerome/lane: pr-<N> and the
# header value, and overrides the image with the PR head SHA.
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: lab-environment
resources:
  - deployment.yaml
  - service.yaml
  - httproute.yaml
```

`deployment.yaml` — the container's `env`, `ports`, `resources`, `lifecycle`, `startupProbe` and `readinessProbe` are the baseline's (`k8s/visits-service.yaml` as of 2026-09-29, comments shortened); the test fails if they drift:

```yaml
# k3s/apps/lab-environment/lanes/visits-service/deployment.yaml
# app: visits-service-lane, never visits-service: the baseline Service
# selects on app, and a lane pod it selected would take ordinary traffic.
# Same ServiceAccount as the baseline, so postgres/redis admit it and it
# shares the baseline's data. Recreate: a lane never runs two pods (the
# lanes live inside page 12's blue-green headroom, 2 lane pods at most).
# Container fields mirror k8s/visits-service.yaml - tests/test-lanes.sh
# fails if they drift; see the baseline for why each value is what it is.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: visits-service-lane
  labels:
    app: visits-service-lane
    lab.jerome/lane: template
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: visits-service-lane
      lab.jerome/lane: template
  template:
    metadata:
      labels:
        app: visits-service-lane
        lab.jerome/lane: template
        # Fixed value for the lane-direct L4 policy: Istio selectors match
        # label values, not label presence.
        lab.jerome/lane-pod: "true"
        # Short-lived; CI's Trivy step is a lane's vulnerability gate.
        trivy-operator.skip: "true"
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8082"
        prometheus.io/path: /actuator/prometheus
    spec:
      serviceAccountName: visits-service
      enableServiceLinks: false
      containers:
        - name: visits-service
          # Never exists on GHCR: the ApplicationSet's kustomize.images sets
          # the PR head SHA. Unresolved, Kyverno refuses it at admission.
          image: ghcr.io/jeromefromcn/petclinic-visits-service:placeholder
          env:
            - name: TZ
              value: "Asia/Hong_Kong"
            - name: SPRING_CLOUD_CONSUL_HOST
              value: "consul"
            - name: SPRING_CLOUD_CONSUL_PORT
              value: "8500"
            - name: DATA_DB_PASSWORD
              valueFrom:
                secretKeyRef: {name: lab-db-credentials, key: password}
            - name: SPRING_SQL_INIT_MODE
              value: "never"
            - name: SPRING_DATASOURCE_HIKARI_MAXIMUMPOOLSIZE
              value: "5"
            - name: JAVA_TOOL_OPTIONS
              value: "-Xmx192m -Xms64m -XX:MaxDirectMemorySize=64m -XX:MaxRAM=512m"
            - name: MALLOC_ARENA_MAX
              value: "2"
          ports:
            - containerPort: 8082
          resources:
            requests:
              cpu: 20m
              memory: 384Mi
            limits:
              cpu: 1000m
              memory: 768Mi
          lifecycle:
            preStop:
              sleep:
                seconds: 10
          startupProbe:
            httpGet:
              path: /actuator/health/liveness
              port: 8082
            periodSeconds: 5
            failureThreshold: 60
          readinessProbe:
            httpGet:
              path: /actuator/health/readiness
              port: 8082
            periodSeconds: 10
            failureThreshold: 3
```
If Task 5 or anything since changed `k8s/visits-service.yaml`'s container fields, the test tells you — copy the baseline's current values.

```yaml
# k3s/apps/lab-environment/lanes/visits-service/service.yaml
# No istio.io/use-waypoint: lane traffic arrives through the baseline
# Service's waypoint route; nothing addresses this Service directly.
apiVersion: v1
kind: Service
metadata:
  name: visits-service-lane
  labels:
    app: visits-service-lane
    lab.jerome/lane: template
spec:
  selector:
    app: visits-service-lane
    lab.jerome/lane: template
  ports:
    - port: 8082
      targetPort: 8082
```

```yaml
# k3s/apps/lab-environment/lanes/visits-service/httproute.yaml
# On the waypoint, HTTPRoute rules are evaluated before the resident
# VirtualService's (verified by the lab PR lanes spike): this header-only
# rule takes just the lane's requests and everything else falls through to
# the VirtualService untouched. An unconditional rule here would swallow the
# whole host (phase I). Lane traffic does not get the VirtualService's
# retries or outlier detection - deliberately, a lane is a test path.
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: visits-service-lane
  labels:
    app: visits-service-lane
    lab.jerome/lane: template
spec:
  parentRefs:
    - group: ""
      kind: Service
      name: visits-service
  rules:
    - matches:
        - headers:
            - name: x-pr-lane
              value: "0"
      backendRefs:
        - name: visits-service-lane
          port: 8082
      timeouts:
        request: 3s
```

- [ ] **Step 4: Create the other three lane bases**

Same four files with these substitutions everywhere (names, labels, SA, container name, image, `prometheus.io/port`, Service/HTTPRoute ports) and the same `lab.jerome/lane-pod: "true"` and `trivy-operator.skip` labels; the six container fields are copied from each baseline manifest's container (the test compares them field by field):

| Service | Port | ServiceAccount | Baseline manifest |
|---|---|---|---|
| `api-gateway` | 8080 | `api-gateway` | `k8s/api-gateway.yaml` |
| `customers-service` | 8081 | `customers-service` | `k8s/customers-service.yaml` |
| `vets-service` | 8083 | `vets-service` | `k8s/vets-service.yaml` |

Do not copy the baseline's `track`/`version` labels (customers) or its `lab.jerome/rollout-rev` annotation — the test compares container fields only, and those labels would put a lane pod into customers' DestinationRule subsets.

- [ ] **Step 5: Create the ApplicationSet**

```yaml
# k3s/argocd/apps/lab-lanes-appset.yaml
# Lab PR lanes (docs/superpowers/specs/2026-09-29-lab-pr-lanes-design.md):
# one Application per (fork PR, service) whose PR carries lane:<service>.
# The fork's lab-images workflow builds and signs a PR's changed services on
# every push, so by the time the label is added the image exists. At most 2
# lane pods at once, never alongside page 12's 5-replica green (capacity).
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: lab-lanes
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - matrix:
        generators:
          - list:
              elements:
                - service: api-gateway
                - service: customers-service
                - service: vets-service
                - service: visits-service
          - pullRequest:
              requeueAfterSeconds: 30
              github:
                owner: Jeromefromcn
                repo: spring-petclinic-microservices
                tokenRef:
                  secretName: github-pr-generator-token
                  key: token
                labels:
                  - "lane:{{.service}}"
  template:
    metadata:
      name: "lab-{{.service}}-pr-{{.number}}"
      annotations:
        argocd.argoproj.io/pull-request-number: "{{.number}}"
      finalizers:
        - resources-finalizer.argocd.argoproj.io
    spec:
      project: default
      source:
        repoURL: https://github.com/Jeromefromcn/docker-gitops.git
        targetRevision: main
        path: "k3s/apps/lab-environment/lanes/{{.service}}"
        kustomize:
          # Plain-string form: this ArgoCD's CRD rejects the object form.
          images:
            - "ghcr.io/jeromefromcn/petclinic-{{.service}}:{{.head_sha}}"
          patches:
            - target:
                kind: Deployment
                name: "{{.service}}-lane"
              patch: |-
                - op: replace
                  path: /metadata/name
                  value: "{{.service}}-pr-{{.number}}"
                - op: replace
                  path: /metadata/labels/lab.jerome~1lane
                  value: "pr-{{.number}}"
                - op: replace
                  path: /spec/selector/matchLabels/lab.jerome~1lane
                  value: "pr-{{.number}}"
                - op: replace
                  path: /spec/template/metadata/labels/lab.jerome~1lane
                  value: "pr-{{.number}}"
            - target:
                kind: Service
                name: "{{.service}}-lane"
              patch: |-
                - op: replace
                  path: /metadata/name
                  value: "{{.service}}-pr-{{.number}}"
                - op: replace
                  path: /metadata/labels/lab.jerome~1lane
                  value: "pr-{{.number}}"
                - op: replace
                  path: /spec/selector/lab.jerome~1lane
                  value: "pr-{{.number}}"
            - target:
                kind: HTTPRoute
                name: "{{.service}}-lane"
              patch: |-
                - op: replace
                  path: /metadata/name
                  value: "{{.service}}-pr-{{.number}}"
                - op: replace
                  path: /metadata/labels/lab.jerome~1lane
                  value: "pr-{{.number}}"
                - op: replace
                  path: /spec/rules/0/matches/0/headers/0/value
                  value: "{{.number}}"
                - op: replace
                  path: /spec/rules/0/backendRefs/0/name
                  value: "{{.service}}-pr-{{.number}}"
      destination:
        server: https://kubernetes.default.svc
        namespace: lab-environment
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
  syncPolicy:
    preserveResourcesOnDeletion: false
```

- [ ] **Step 6: Run the test to see it pass**

Run: `bash k3s/apps/lab-environment/tests/test-lanes.sh`
Expected: every line `PASS`, last line `ALL PASS`.

- [ ] **Step 7: Append the `lane-direct` policy to `k8s/authz.yaml`**

After `vets-service-direct` (Istio selectors match values, not label presence — hence the fixed `lab.jerome/lane-pod: "true"` label on every lane pod; an empty selector would cover every pod in the namespace):

```yaml
---
# L4 for lab PR lanes: same shape as the <service>-direct policies above.
# Without it no ALLOW policy selects a lane pod and any caller could reach
# it directly. Istio selectors match values, not label presence, so lane
# pods carry the fixed label lab.jerome/lane-pod: "true" for this.
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: lane-direct
  namespace: lab-environment
spec:
  selector:
    matchLabels:
      lab.jerome/lane-pod: "true"
  action: ALLOW
  rules:
    - from:
        - source:
            principals:
              - cluster.local/ns/lab-environment/sa/waypoint
    - from:
        - source:
            principals:
              - cluster.local/ns/lab-environment/sa/prometheus
      to:
        - operation:
            ports: ["8080", "8081", "8082", "8083"]
```

- [ ] **Step 8: Wire the test into CI**

In `.github/workflows/repo-conventions.yml`, job `lab-demo-helpers`, after `Run demo helper tests`:

```yaml
      - name: Run lab PR lane render tests
        run: |
          python3 -c 'import yaml' 2>/dev/null || pip install pyyaml
          bash k3s/apps/lab-environment/tests/test-lanes.sh
```
(`ubuntu-latest` ships `kubectl` with kustomize.)

- [ ] **Step 9: Commit, ask, push, check the ApplicationSet**

```bash
chmod +x k3s/apps/lab-environment/tests/test-lanes.sh
git status --short && git log --oneline -3
git add k3s/apps/lab-environment/lanes k3s/apps/lab-environment/tests/test-lanes.* k3s/apps/lab-environment/k8s/authz.yaml k3s/argocd/apps/lab-lanes-appset.yaml .github/workflows/repo-conventions.yml
git commit -F - <<'EOF'
k3s: add PR lanes for the lab's business services

A fork PR labelled lane:<service> gets that service deployed as
<service>-pr-<N> next to the baseline, reached only by requests with
x-pr-lane: <N> through a header-only HTTPRoute ahead of the resident
VirtualService. lane-direct admits only the waypoint to lane pods. A
render test checks each lane against the baseline it shadows.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```
Ask the owner; after approval push, then:
```bash
argocd app get root --core --refresh >/dev/null 2>&1 || true
end=$((SECONDS + 180)); until kubectl -n argocd get applicationset lab-lanes >/dev/null 2>&1; do [ $SECONDS -lt $end ] || { echo "APPSET WAIT TIMED OUT"; break; }; sleep 5; done
kubectl -n argocd get applicationset lab-lanes -o json | jq -r '.status.conditions[] | "\(.type)=\(.status) \(.message)"'
kubectl -n lab-environment get authorizationpolicy lane-direct
```
Expected: `ErrorOccurred=False`, `ResourcesUpToDate=True`; no `lab-*-pr-*` Applications yet (no labelled PRs); `lane-direct` exists. (Use the root Application's real name from `k3s/argocd/apps/root.yaml`.)

---

### Task 8: Baseline lane check, scenario 18, runbook page, capacity docs

**Files:**
- Modify: `k3s/apps/lab-environment/demo/lib.sh` (`routing_baseline`)
- Modify: `k3s/apps/lab-environment/tests/test-demo-helpers.sh` (kubectl stub + tests)
- Create: `k3s/apps/lab-environment/demo/scenarios/pr-lane.sh`
- Create: `docs/demo/18-pr-lane.md`
- Modify: `docs/demo/README.md` (Order table), `docs/demo/12-blue-green.md` (Preconditions)
- Modify: `k3s/apps/lab-environment/k8s/namespace.yaml` (quota derivation comment), `k3s/apps/lab-environment/README.md`
- Fork: branch `demo/pr-lane` with the visible change

**Interfaces:**
- Consumes: lane labels (Task 7), the lane `upstream_cluster` string (ledger, Task 2).
- Produces: `routing_baseline` fails with `lane pods still present: …`; scenario `pr-lane` reads env `LANE_PR` (the PR number).

- [ ] **Step 1: Write the failing baseline tests**

In `test-demo-helpers.sh`'s kubectl stub `case`, before the `*" get deploy "*` line, add:

```bash
  *"get pods -l lab.jerome/lane -o name"*) printf '%s' "${FAKE_LANE_PODS:-}" ;;
```
After the `reset passes at the routing baseline` check add:

```bash
FAKE_LANE_PODS='pod/visits-service-pr-42-abc' check "reset fails while a PR lane pod exists" 1 "$DEMO/demo-reset" preflight
has "$WORK/out" "lane pods still present: pod/visits-service-pr-42-abc"
```

- [ ] **Step 2: Run to see it fail**

Run: `bash k3s/apps/lab-environment/tests/test-demo-helpers.sh | grep -E 'lane|FAILED|ALL PASS'`
Expected: `FAIL reset fails while a PR lane pod exists (exit 0, want 1)`.

- [ ] **Step 3: Implement the check in `routing_baseline`**

After the `pods=$(… track=canary …)` check add:

```bash
  # PR lanes (page 18) live in the headroom page 12's green needs: none may
  # be left behind. Closing the PR or dropping its lane: label removes it.
  pods=$(kubectl -n "$NS" get pods -l lab.jerome/lane -o name)
  [ -z "$pods" ] || { echo "lane pods still present: $(tr "\n" " " <<< "$pods")"; bad=1; }
```
Update the function's header comment to: `# Every routing demo returns here: slot empty and on git's image, no PR lane pod, every VirtualService route pinned to stable - no weights, mirror or header rule.`

- [ ] **Step 4: Run to see it pass**

Run: `bash k3s/apps/lab-environment/tests/test-demo-helpers.sh | tail -1`
Expected: `ALL PASS`.

- [ ] **Step 5: Create the demo branch in the fork**

A servlet filter in visits-service that adds `X-Visits-Build: lane` to every response. On a branch off the fork's `main`:

```bash
cd /home/ubuntu/jerome/spring-petclinic-microservices
git checkout -b demo/pr-lane main
```
Create `spring-petclinic-visits-service/src/main/java/org/springframework/samples/petclinic/visits/web/LaneBuildHeaderFilter.java`:

```java
package org.springframework.samples.petclinic.visits.web;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;

/**
 * Demo change for the lab's PR lane scenario (docker-gitops docs/demo/18):
 * marks every response from this build so a lane is visible at the client.
 * Lives only on the demo/pr-lane branch; its PR is opened and closed, never merged.
 */
@Component
class LaneBuildHeaderFilter extends OncePerRequestFilter {

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain chain)
            throws ServletException, IOException {
        response.setHeader("X-Visits-Build", "lane");
        chain.doFilter(request, response);
    }
}
```
Add a test `spring-petclinic-visits-service/src/test/java/org/springframework/samples/petclinic/visits/web/LaneBuildHeaderFilterTest.java`:

```java
package org.springframework.samples.petclinic.visits.web;

import org.junit.jupiter.api.Test;
import org.springframework.mock.web.MockFilterChain;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.mock.web.MockHttpServletResponse;

import static org.assertj.core.api.Assertions.assertThat;

class LaneBuildHeaderFilterTest {

    @Test
    void marksTheResponse() throws Exception {
        MockHttpServletResponse response = new MockHttpServletResponse();
        new LaneBuildHeaderFilter().doFilter(new MockHttpServletRequest("GET", "/pets/visits"), response, new MockFilterChain());
        assertThat(response.getHeader("X-Visits-Build")).isEqualTo("lane");
    }
}
```
Run: `./mvnw -B -q -pl spring-petclinic-visits-service test -Dtest=LaneBuildHeaderFilterTest` — expected: `BUILD SUCCESS` (write the test first and see it fail to compile before adding the filter).

```bash
git add spring-petclinic-visits-service/src
git commit -m "Mark visits responses from the PR lane demo build" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
Ask the owner, then `git push -u origin demo/pr-lane && git checkout main`. Pushing a branch does not trigger `lab-images` (only `main`/`lab-v2` pushes and PRs do).

- [ ] **Step 6: Write the scenario's evidence script**

The lane is recognised by its host inside `upstream_cluster`: `|visits-service-pr-<N>.` — a `|` before the host and a `.` after it hold for both Envoy cluster shapes (`outbound|8082||<host>` and `inbound-vip|8082|http|<host>`). Check it against the string Task 2 recorded; if the lane's cluster has neither shape, change `pat` and the stub test's fixture together.

```bash
# 18 — PR lane: a fork PR labelled lane:visits-service runs next to the
# baseline; only requests with x-pr-lane: <N> reach it, across every hop.
# The page exports LANE_PR (the PR number) before running demo-evidence.
SENT_DIRECT=10   # the page sends these to /api/visit/... with the header
SENT_HOP=5       # and these to /api/customer/owners/1/visits (via customers)

evidence_pr_lane() {
  local n=${LANE_PR:?export LANE_PR=<the PR number>} per lane base pod ann tid svcs out ok pat
  pat="[|]visits-service-pr-$n[.]"
  settle
  per=$(loki_by upstream_cluster '{service="istio-proxy"} | json | __error__="" | authority=~"visits-service.*"' "$WINDOW_START" "$WINDOW_END")
  lane=$(echo "$per" | awk -v p="$pat" '$2 ~ p { s += $1 } END { print s + 0 }')
  base=$(echo "$per" | awk -v p="$pat" '$2 !~ p { s += $1 } END { print s + 0 }')
  rec_if envoy "waypoint sent $lane requests to visits-service-pr-$n (want exactly $((SENT_DIRECT + SENT_HOP)): every header request, nothing else) and $base to the baseline (want >= $SENT_DIRECT)" \
    [ "$lane" -eq $((SENT_DIRECT + SENT_HOP)) -a "$base" -ge "$SENT_DIRECT" ]
  pod=$(kubectl -n "$NS" get pods -l "lab.jerome/lane=pr-$n" -o name | head -1)
  ann=$(kubectl -n "$NS" get "${pod:-pod/none}" -o jsonpath='{.metadata.annotations.kyverno\.io/verify-images}' 2>/dev/null || true)
  rec_if kyverno "lane pod ${pod#pod/} signature: ${ann:-none} (want ghcr.io/jeromefromcn/petclinic-visits-service:<sha> pass)" \
    grep -q 'petclinic-visits-service:[0-9a-f]\{40\}":"pass"' <<< "$ann"
  out=$(kubectl apply --dry-run=server -f - 2>&1 <<EOF || true
apiVersion: v1
kind: Pod
metadata: {name: probe-local, namespace: $NS, labels: {app: visits-service}}
spec:
  containers:
    - {name: c, image: "ops-lab/visits-service:21d8461c6ce4", resources: {requests: {cpu: 10m, memory: 16Mi}}}
EOF
)
  rec_if kyverno "a local ops-lab/* image is refused: $(grep -o 'lab-business-images-from-ghcr' <<< "$out" | head -1)" \
    grep -q 'lab-business-images-from-ghcr' <<< "$out"
  tid=$(curl -sf -G "$JAEGER/api/traces" --data-urlencode service=customers-service \
          --data-urlencode "tags={\"x-pr-lane\":\"$n\"}" --data-urlencode "start=${WINDOW_START}000000" \
          --data-urlencode "end=${SETTLED_AT}000000" --data-urlencode limit=1 | jq -r '.data[0].traceID // empty')
  svcs=$([ -n "$tid" ] && jaeger_spans "$tid" || echo "no trace")
  ok=0; grep -q 'customers-service' <<< "$svcs" && grep -q 'visits-service' <<< "$svcs" && ok=1
  rec_if app "a trace tagged x-pr-lane=$n spans customers -> visits: $svcs" [ $ok = 1 ]
}

# The page closes the PR first; this waits for ArgoCD to remove the lane.
reset_pr_lane() {
  local end=$((SECONDS + 300))
  until [ -z "$(kubectl -n "$NS" get pods -l lab.jerome/lane -o name)" ]; do
    [ $SECONDS -lt $end ] || { echo "lane pods still present after 5 min - was the PR closed or its label removed?"; return 1; }
    sleep 5
  done
}
```

- [ ] **Step 7: Stub-test the scenario's evidence**

Add to `test-demo-helpers.sh` before the `# --- runbook pages` section (follow the `hook06` pattern already in the file):

```bash
# --- 18 PR lane ---------------------------------------------------------------
cp "$DEMO/scenarios/pr-lane.sh" "$DEMO_SCENARIO_DIR/"
cat > "$WORK/hook18" <<'EOF'
#!/bin/bash
case "$1" in
  *"loki/api/v1/query"*) echo '{"data":{"result":[{"metric":{"upstream_cluster":"outbound|8082||visits-service-pr-42.lab-environment.svc.cluster.local"},"value":[0,"'"${LANE18:-15}"'"]},{"metric":{"upstream_cluster":"inbound-vip|8082|http|visits-service.lab-environment.svc.cluster.local;"},"value":[0,"30"]}]}}' ;;
  *"api/traces?"*|*"/api/traces "*|*"api/traces --data"*) echo '{"data":[{"traceID":"t18"}]}' ;;
  *"/api/traces/t18"*) echo '{"data":[{"spans":[1,2,3],"processes":{"p1":{"serviceName":"customers-service"},"p2":{"serviceName":"visits-service"}}}]}' ;;
  *"get pods -l lab.jerome/lane=pr-42 -o name"*) echo "pod/visits-service-pr-42-abc" ;;
  *"get pod/visits-service-pr-42-abc"*) echo "{\"ghcr.io/jeromefromcn/petclinic-visits-service:0123456789abcdef0123456789abcdef01234567\":\"${SIG18:-pass}\"}" ;;
  *"apply --dry-run=server"*) echo 'Error from server: admission webhook "validate.kyverno.svc-fail" denied the request: policy Pod/lab-environment/probe-local for resource violation: lab-business-images-from-ghcr' ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$WORK/hook18"
DEMO_NOW=1000 "$DEMO/demo-window" start pr-lane >/dev/null; DEMO_NOW=1001 "$DEMO/demo-window" stop pr-lane >/dev/null
LANE_PR=42 JAEGER_POLL_SECONDS=0 FAKE_CURL_HOOK=$WORK/hook18 FAKE_KUBECTL_HOOK=$WORK/hook18 check "18 passes: lane took every header request, signed, local image refused, trace crosses hops" 0 "$DEMO/demo-evidence" pr-lane
LANE18=14 LANE_PR=42 JAEGER_POLL_SECONDS=0 FAKE_CURL_HOOK=$WORK/hook18 FAKE_KUBECTL_HOOK=$WORK/hook18 check "18 fails when the lane missed a header request" 1 "$DEMO/demo-evidence" pr-lane
SIG18=fail LANE_PR=42 JAEGER_POLL_SECONDS=0 FAKE_CURL_HOOK=$WORK/hook18 FAKE_KUBECTL_HOOK=$WORK/hook18 check "18 fails without a passing signature" 1 "$DEMO/demo-evidence" pr-lane
```
Note: `kubectl apply --dry-run=server -f -` reads its manifest from stdin; the stub ignores stdin, which is fine. `settle()` sleeps until `WINDOW_END + 20` — with `DEMO_NOW=1001` that is in the past, so it returns at once. The `apply` hook prints the denial and exits 0; the real `kubectl` exits 1, which the script's `|| true` absorbs — both paths are covered by the `grep`.

Run: `bash k3s/apps/lab-environment/tests/test-demo-helpers.sh | grep -E '^(PASS|FAIL) 18|ALL PASS|FAILED'`
Expected: three `PASS 18 …` lines and `ALL PASS`. If the curl hook's URL patterns do not match (`FAKE_CURL_HOOK` receives the whole curl argv as one string), print `"$1"` from the hook once and adjust the `case` patterns — the Jaeger search call carries `/api/traces` followed by `--data-urlencode` arguments.

- [ ] **Step 8: Write page 18**

~~~markdown
# 18 — PR lane: a pull request running next to production

## Purpose
Open a pull request on the fork and show it running in the lab next to the
baseline, reached only by requests that ask for it — across every hop —
built, scanned and signed by CI, admitted only because its signature
checks out, and gone when the PR closes.

## Preconditions
Preflight passed; 12 reset (the green is at 0 — a lane uses the same
memory headroom, so the two never run together); no Rollout of
visits-service in progress. The fork's `demo/pr-lane` branch is based on
the current fork `main` (`git -C ../spring-petclinic-microservices log --oneline main..demo/pr-lane` shows exactly one commit; rebase it if `main` moved).

## Commands
```bash
F=Jeromefromcn/spring-petclinic-microservices
LANE_PR=$(gh pr create -R $F --head demo/pr-lane --base main --title "demo: PR lane" --body "Lab PR lane demo (docker-gitops docs/demo/18). Closed, never merged." | grep -oP '/pull/\K[0-9]+'); export LANE_PR; echo "PR $LANE_PR"
end=$((SECONDS + 900)); until gh pr checks $LANE_PR -R $F 2>/dev/null | grep -qP '^build-scan-sign \(visits-service\)\s+pass'; do [ $SECONDS -lt $end ] || { echo "CI WAIT TIMED OUT - stop here"; break; }; sleep 15; done
gh pr edit $LANE_PR -R $F --add-label lane:visits-service
end=$((SECONDS + 600)); until [ "$(kubectl -n lab-environment get pods -l lab.jerome/lane=pr-$LANE_PR -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = True ]; do [ $SECONDS -lt $end ] || { echo "LANE WAIT TIMED OUT - stop here"; break; }; sleep 5; done
argocd app get lab-visits-service-pr-$LANE_PR --core | grep -E '^(Name|Sync Status|Health Status)'
demo-window start pr-lane
U=http://10.0.0.95:30097
for i in $(seq 1 10); do curl -s -D- -o /dev/null -H "x-pr-lane: $LANE_PR" "$U/api/visit/pets/visits?petId=1" | tr -d '\r' | awk 'NR==1{c=$2} tolower($1)=="x-visits-build:"{b=$2} END{print c, (b ? "lane" : "baseline")}'; done | sort | uniq -c
for i in $(seq 1 10); do curl -s -D- -o /dev/null "$U/api/visit/pets/visits?petId=1" | tr -d '\r' | awk 'NR==1{c=$2} tolower($1)=="x-visits-build:"{b=$2} END{print c, (b ? "lane" : "baseline")}'; done | sort | uniq -c
for i in $(seq 1 5); do curl -s -o /dev/null -w '%{http_code}\n' -H "x-pr-lane: $LANE_PR" "$U/api/customer/owners/1/visits"; done | sort | uniq -c
sleep 10
demo-window stop pr-lane
demo-evidence pr-lane
gh pr close $LANE_PR -R $F
```

## Expected result
`10 200 lane`, then `10 200 baseline`, then `5 200`. The evidence shows
exactly 15 requests on `visits-service-pr-<N>` — the 10 direct ones and the
5 that reached visits through customers-service — and none of the
generator's traffic.

## Evidence
- **Envoy (waypoint access log):** 15 requests upstream to the lane, every
  other visits request to the baseline.
- **Kyverno:** the lane pod's `kyverno.io/verify-images` annotation shows
  its PR image `pass`; a server-side dry-run of a local `ops-lab/*` image is
  refused by `lab-business-images-from-ghcr`.
- **App (Jaeger):** a trace tagged `x-pr-lane=<N>` spanning customers and
  visits — the header crossed a hop the client never saw.

## Talking points
- **Only the changed service runs in the lane.** Every other hop is the
  baseline; the lane is chosen again at every hop by the header. That is
  why the apps propagate it (Micrometer baggage) — api-gateway forwards
  request headers anyway, but customers' call to visits is a new request.
- **Routing order is the whole trick.** On the waypoint an HTTPRoute's rules
  are evaluated before the VirtualService's: a header-only rule takes just
  the lane's requests. An unconditional one would swallow the host — hit on
  hello in phase I.
- **A lane is a test path, not production.** Lane traffic skips the
  VirtualService's retries and outlier detection, and the lane runs one pod
  on the baseline's data.
- **Signed or nothing.** The pod ran because Kyverno verified the image was
  signed by this repo's CI for this PR (`refs/pull/<N>/merge`); a local build
  is refused outright — `verifyImages` alone would have let it through,
  since it only checks images that match its pattern.
- **Head SHA, not merge SHA.** The image is tagged with the PR's head commit;
  the signature's subject is the merge ref GitHub builds PRs on.
- **Capacity is shared in time.** Lanes use the headroom page 12's green
  needs: two lane pods at most, never both at once — the reset refuses a
  leftover lane.

## Reset
`gh pr close` (last command) makes the generator drop the PR; ArgoCD deletes
the Application and its resources. `demo-reset pr-lane` waits for the lane
pod to go and verifies the baseline.
~~~

Then in `docs/demo/README.md`'s Order table insert after the `12` row:

```markdown
| 18 | [PR lane: a pull request next to production](18-pr-lane.md) | After 12's reset — lanes use the same headroom as its green |
```
and in `docs/demo/12-blue-green.md`'s Preconditions append: ` No PR lane pod (18) — a lane uses the same memory headroom as the green.`

- [ ] **Step 9: Capacity and README docs**

In `k3s/apps/lab-environment/k8s/namespace.yaml`, at the end of the quota derivation comment add:

```yaml
    # PR lanes (docs/demo/18) have no reservation of their own: up to 2 lane
    # pods (2 x 384Mi / 20m) use the 5-replica green's headroom, so a lane and
    # page 12's green never run at once - demo-reset refuses a leftover lane.
```
In `k3s/apps/lab-environment/README.md` add a section after **Canary slot**:

```markdown
**PR lanes.** A fork PR labelled `lane:<service>` gets that service deployed
as `<service>-pr-<N>` by the `lab-lanes` ApplicationSet
(`k3s/argocd/apps/lab-lanes-appset.yaml`, bases in `lanes/`), reached only by
requests carrying `x-pr-lane: <N>`: a header-only HTTPRoute on the baseline
Service, evaluated on the waypoint before the resident VirtualService.
Lane pods carry `app: <service>-lane` (never `app: <service>`, or the
baseline Service would select them), the baseline's ServiceAccount and data,
and `lab.jerome/lane-pod: "true"` for the `lane-direct` L4 policy.
`tests/test-lanes.sh` renders every lane and checks it against its baseline.
At most 2 lane pods, never alongside page 12's green (see the quota).

**Images.** The four business services and the canary slot run digest-pinned
images the fork's `lab-images` workflow built on a native arm64 runner,
scanned with Trivy and signed with Cosign; Kyverno admits only those
(`restrict-image-registry`, `restrict-image-registry-lab-lanes`,
`lab-business-images-from-ghcr`). A release is still a git commit here that
changes the digest. `lab-environment/scripts/build.sh` and importing
`ops-lab/*` into oracle2's containerd are retired for this k3s lab
(`mcp-toolkit` still uses its local image).
```
Also update the README's opening sentence about Trivy if it mentions lab images being skipped.

- [ ] **Step 10: Run every test**

```bash
bash k3s/apps/lab-environment/tests/test-demo-helpers.sh | tail -1
bash k3s/apps/lab-environment/tests/test-lanes.sh | tail -1
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable -S warning k3s/apps/lab-environment/demo/scenarios/pr-lane.sh k3s/apps/lab-environment/demo/lib.sh
python3 .github/scripts/check-compose-conventions.py >/dev/null && echo conventions OK
```
Expected: `ALL PASS`, `ALL PASS`, no shellcheck output, `conventions OK`.

- [ ] **Step 11: Commit, ask, push**

```bash
git status --short && git log --oneline -3
git add k3s/apps/lab-environment docs/demo
git commit -F - <<'EOF'
demo: add the PR lane scenario (18)

A fork PR labelled lane:visits-service runs next to the baseline and
only header requests reach it. The routing baseline now refuses a
leftover lane pod, since lanes share page 12's green headroom.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```
Ask the owner (touches `k3s/`), then `git pull --ff-only && git push`.

---

### Task 9: Rehearsal, two-lane capacity check, results

**Files:**
- Create: `docs/demo/evidence/pr-lane.txt`
- Modify: `docs/superpowers/specs/2026-09-29-lab-pr-lanes-design.md` (append "Implementation results")
- Modify: `docs/superpowers/specs/2026-09-25-lab-sdlc-demo-roadmap.md` (row 3 status)

- [ ] **Step 1: Run page 18 end to end**

From the repo root on vps_oracle, paste the page's command block as written. Save the `demo-evidence pr-lane` output: `demo-evidence pr-lane > docs/demo/evidence/pr-lane.txt` (rerun it right after the window closes if needed; it is read-only). Then `demo-reset pr-lane`.
Expected: evidence passes (≥ 2 pieces, ≥ 1 infrastructure); `baseline OK`; `kubectl -n argocd get applications | grep -c 'lab-.*-pr-'` prints `0`.

- [ ] **Step 2: Two lanes at once (acceptance 7)**

Reopen the demo PR and label it for two services (visits via its own commit; customers-service needs an image, so push a no-op commit touching `spring-petclinic-customers-service/` on a second branch `demo/pr-lane-2` and open a second PR labelled `lane:customers-service`). Wait for both lane pods Ready, then:

```bash
kubectl -n lab-environment get events --field-selector reason=FailedCreate --sort-by=.lastTimestamp | tail -3
kubectl -n lab-environment get pods -l lab.jerome/lane -o wide
kubectl -n lab-environment describe resourcequota lab-environment-quota | grep requests
```
Expected: no new `FailedCreate`; both pods Running on vps-oracle2; quota `requests.memory` ≈ 5424Mi + 768Mi. Close both PRs, `demo-reset pr-lane`, delete the `demo/pr-lane-2` branch after asking.

- [ ] **Step 3: Pages 09–13 still pass (acceptance 6)**

Run page 10 (`10-canary-weight.md`) end to end — it exercises the rewritten patch image lines and the canary's GHCR digests — and `demo-reset canary-weight`. Expected: its evidence passes and `baseline OK`. (The other routing pages share the same patch mechanism; `git apply --check` covers them in CI.)

- [ ] **Step 4: Record results and close the roadmap row**

Append `## Implementation results` to the spec: one line per acceptance criterion (1–7) with the measured value and date, the spike's route order, the propagation finding, the Trivy report counts, and every deviation from the plan recorded in the ledger. Set roadmap row 3's status to `**Done 2026-MM-DD** — all 7 acceptance criteria pass; [spec](2026-09-29-lab-pr-lanes-design.md) (implementation results at the end), [plan](../plans/2026-09-29-lab-pr-lanes.md), runbook page [18](../../demo/18-pr-lane.md)` (or list which criteria failed).

- [ ] **Step 5: Commit, ask, push**

```bash
git add docs/demo/evidence/pr-lane.txt docs/superpowers/specs/2026-09-29-lab-pr-lanes-design.md docs/superpowers/specs/2026-09-25-lab-sdlc-demo-roadmap.md
git commit -F - <<'EOF'
docs: record the PR lanes results and the rehearsal evidence

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```
Ask the owner, then `git pull --ff-only && git push`.
