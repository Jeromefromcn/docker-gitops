# K3s Phase F+G — Service-Mesh-Driven PR Lane Design

Date: 2026-08-18

Corresponds to the F+G phases of the [K3s cloud-native experiment platform roadmap](2026-08-05-k3s-cloud-native-platform-roadmap.md) (the original F "multi-environment PR lanes" and G "service mesh + progressive delivery" merged; merge rationale in the roadmap's "reasons for the F+G merge" paragraph).

Precondition: [Phase B GitOps design](2026-08-07-k3s-phase-b-gitops-design.md) (ArgoCD + ApplicationSet controller installed, CI build→Trivy→Cosign skeleton already working), [Phase E supply chain security design](2026-08-15-k3s-phase-e-supply-chain-security-design.md) (all three Kyverno policies already flipped to Enforce).

## Scope

**To be done in this phase:**

- Install Istio Ambient (istiod + ztunnel + istio-cni) and Gateway API CRDs, all through GitOps
- Change the practice-purpose `placeholder-hello` from single-tier to **two-tier** (`hello-frontend` → `hello-backend`), moving it into a new `pr-lanes` namespace; only this namespace joins the mesh
- Attach a waypoint proxy (L7) to the `hello-backend` Service
- ArgoCD ApplicationSet PR Generator: each open PR carrying the `pr-lane` label generates one lane (copying only the single `hello-backend` service, **not a whole environment**)
- Lane routing: requests carrying an `x-pr-lane: <PR number>` header, when forwarded by the baseline frontend to the backend, are steered by the waypoint to that PR's backend version based on the header; headerless requests fall back to the shared baseline backend
- CI extension: on the `pull_request` event, build and sign `hello-backend`, tagging with the PR head SHA
- Kyverno policy adjustment so that images signed from PR branches pass verification in `pr-lanes` (see "Kyverno policy adjustment" below)

**Not done in this phase:**

- **Canary / progressive delivery** (Argo Rollouts, weighted traffic shifting) — this part of the original G phase isn't in this deliverable. The waypoint established this phase is the same mechanism; when canary is wanted later, plug straight in without reinstalling the mesh
- **Onboarding existing services into the mesh** — the `workloads`, `llm`, `lab-environment` namespaces don't join ambient in this batch. This isn't "the mesh is only for the lab", it's **progressive onboarding**: the standard way to adopt a service mesh in the real world is to first validate a non-critical namespace, then onboard one by one after stability, not to enable the whole cluster at once. `pr-lanes` is the first batch; after the full checklist passes and it runs stably, the next batch can be `workloads` (vikunja/apprise, stateless, L4 mTLS with near-zero overhead because ztunnel is per-node and already running). Keeping stateful services out of the mesh is an established roadmap principle, not relaxed per-batch
- **Exposing lanes externally** — lanes get no dedicated domain and don't enter NPM. Verification curls from inside the cluster or from the host with a header
- **Mesh security capabilities like mTLS / AuthorizationPolicy** — ambient grants mTLS to traffic inside `pr-lanes` by default, but that's a side effect, not this phase's goal; no authorization policy is designed separately

## Why "shared base + traffic routing", and why it must be two-tier

The industry splits PR preview environments into two camps:

- **Camp A: namespace-per-PR** — each PR copies the whole service plus dependencies into its own namespace. Faithful and simple, but cost grows linearly with "service count × open PR count"
- **Camp B: shared base + traffic routing** (represented by tools like Signadot, used by large companies with deep dependency graphs): only the one service "this PR actually changed" gets an extra copy; all other dependencies share the resident baseline environment; requests carry a routing key, hitting the changed service routes into the PR version, everything else falls back to the baseline

This phase implements Camp B. **But Camp B's essence is east-west (service → service) routing** — a request enters and propagates the routing key hop by hop across the dependency graph, each hop deciding "does the next service have a version for this lane". If there's only a single dependency-free service, the routing decision happens once at the entry, which any ingress controller's header splitting can do — the mesh adds no value, it's "wearing B's name to do A's simplified version".

So `placeholder-hello` must be split from single-tier to two-tier, to have a real east-west hop for the waypoint to intercept. This is a step that looks superfluous but is actually irreducible in this design: **without the second hop, there's no Camp B to speak of.**

Responsibilities of the two tiers:

- `hello-frontend`: baseline, constant and unchanging, always exactly one copy. nginx, `/` serves its own page, `/api` uses `proxy_pass` to `hello-backend`. It plays the role of "the part of the shared base the PR didn't touch, but which calls downstream"
- `hello-backend`: one baseline copy + one per lane. This is what PRs change. It plays "the service the PR changed"

Header propagation relies on nginx `proxy_pass` forwarding the client request headers to the upstream by default (`x-pr-lane` uses a hyphen rather than an underscore, so it's unaffected by nginx's default-disabled `underscores_in_headers`). In the real world this step usually needs explicit passing by application code or a tracing library; nginx gives it for free here — the design should note this is a simplification, not the general rule.

## Current-state constraints

**Resources (measured 2026-08-18, same day as the k3s→compose reverse migration)**: host 23Gi total, 16Gi used, 6.5Gi available, **4Gi swap with 3.0Gi already used**, `kubectl top node` shows memory at 78%.

The same day `homepage`/`trilium`/`dify`/`evidence-os-website` migrated back to compose and the `dify` namespace was deleted, releasing its 2Gi requests / 4Gi limits quota — **k8s-side quota space got looser, but host-wide memory did not get looser** (those services still run on the same machine as compose, just no longer counted against k8s quota). Swap instead rose from 2.0Gi to 3.0Gi.

Cluster current state measured: k3s platform fixed overhead about 3.4Gi (`k3s server` process RSS 1.9Gi + argocd/cilium/kyverno/trivy-operator/sealed-secrets/headlamp pods totaling 1.46Gi), application load on k8s about 6.7Gi (`llm` 4.0Gi, `lab-environment` 2.0Gi, `workloads` about 0.6Gi). The 4 new resident components added this phase (about 576Mi requests) must be evaluated against this backdrop.

**Cilium `cni.exclusive` is unset**: `vps_oracle/k3s/cilium/values.yaml` currently has no `cni:` block, and the chart's default is `cni.exclusive=true`, meaning Cilium **actively deletes other CNI plugins' config files**. istio-cni is a chained plugin and would be wiped out under this setting, so ztunnel's traffic interception wouldn't take effect. Must first change Cilium to `cni.exclusive: false` — this is a change to the live cluster CNI, see "Precondition change" below.

**Cilium `bpf.masquerade` must stay off**: currently unset (chart default false), which is correct. Istio uses link-local IPs for health checks; enabling BPF masquerade would break pod health checks, and it's officially flagged unsupported. This item is "confirm, don't touch", not a change.

**Cilium L7 policy is incompatible with ambient**: currently no L7 rules in CiliumNetworkPolicy, just keep it that way.

**Kyverno `restrict-image-registry` would block lane images (Enforce)**: the policy requires `ghcr.io/jeromefromcn/*` signature identities to match `^https://github\.com/Jeromefromcn/docker-gitops/\.github/workflows/[^/]+\.yml@refs/heads/main$`. A workflow triggered by a `pull_request` event has an OIDC identity of `...@refs/pull/<N>/merge`, which **doesn't match this regex**, so lane pods get rejected at admission. Must make a namespace-scoped exception, see "Kyverno policy adjustment" below.

**Kyverno `require-vuln-scan-clean`(Enforce)**: matches pod label `app in (placeholder-hello, vikunja-notify-relay)`. The new two-tier app labels aren't in this list, so they aren't blocked by default. It checks "whether that pod owner's existing VulnerabilityReport exists"; a brand-new image has no report yet on first deploy (empty set → condition unmet → allow), so there's no "can't deploy before scan, can't scan before deploy" deadlock.

## Architecture

```
                  external / host curl
                        │
                        │  Host: ...   X-PR-Lane: 42(optional)
                        ▼
              hello-frontend Service (NodePort)
                        │
                 ┌──────┴──────┐
                 │ hello-      │  baseline constant, one copy, not replicated per PR
                 │ frontend    │  nginx: /api → proxy_pass http://hello-backend
                 │ (baseline)  │  (forwards the X-PR-Lane header as-is)
                 └──────┬──────┘
                        │  ← this hop enters the mesh: ztunnel intercepts,
                        │     and because hello-backend has a waypoint, routes to the waypoint
                        ▼
              ┌───────────────────┐
              │  waypoint proxy   │  Envoy, L7. Reads HTTPRoute rules:
              │  (pr-lanes ns)    │   - header x-pr-lane=42 → hello-backend-pr-42
              └─────────┬─────────┘   - no match(catch-all) → hello-backend
                        │
          ┌─────────────┼─────────────┐
          ▼             ▼             ▼
   hello-backend  hello-backend  hello-backend
    (baseline)      -pr-42         -pr-57
                  ↑ dynamically generated/reclaimed by the ApplicationSet PR Generator

Namespace layout:
  istio-system : istiod / ztunnel(DaemonSet) / istio-cni(DaemonSet)
  pr-lanes     : hello-frontend, hello-backend(baseline), waypoint,
                 + per lane one Deployment/Service/HTTPRoute group
                 (the only istio.io/dataplane-mode=ambient namespace)
  other namespaces  : not in the mesh at all
```

## Components and configuration

| Item | Decision | Rationale |
|---|---|---|
| Istio install method | Helm (`istio/base` + `istio/istiod` + `istio/cni` + `istio/ztunnel`, `profile=ambient`), version pinned by checking the latest stable at install time and written back into `vps_oracle/k3s/README.md` | follows the phase A/B pattern of installing Cilium and ArgoCD. Version isn't hardcoded in this design doc to avoid staleness (same as phase B) |
| Gateway API CRDs | separate GitOps Application, standard channel | the waypoint is a `Gateway` resource and the lane routing is `HTTPRoute`, both needing this CRD set; k3s doesn't bundle them (confirmed no gateway CRD, no IngressClass, no Traefik in the cluster) |
| Mesh onboarding scope | only the `pr-lanes` namespace gets the `istio.io/dataplane-mode=ambient` label | blast-radius control. All existing services unaffected; if something breaks, only the practice app is hit |
| Waypoint granularity | one, attached to the `hello-backend` **Service** (`istio.io/use-waypoint`), not to the whole namespace | only the backend needs L7 routing; the frontend needs no waypoint, so don't spend an extra Envoy's resources. This is also ambient's core advantage over sidecar — L7 proxies attach on demand, not one per pod |
| Entry path | keep NodePort direct to `hello-frontend`, **don't install the Istio ingress gateway** | the lane's routing decision happens in the east-west hop (frontend → backend); the entry only needs to carry the header in. Installing an ingress gateway adds an extra Envoy (~128Mi) that participates in no routing decision. This trade-off satisfies both "close to real" (a routing key working inside the mesh is the essence of Camp B) and "runs at all" |
| Lane replication scope | copy only `hello-backend`; frontend and everything else shares the baseline | this is the definition of Camp B. Copying the whole thing regresses to Camp A |
| routing key | HTTP header `x-pr-lane: <PR number>` | pure header, no need to change the frontend's code logic (nginx forwards by default) |
| Lane trigger condition | a PR generates a lane only if it carries the `pr-lane` label | this repo normally follows a single-person push-to-main flow; without label filtering, any compose-change PR would pointlessly spin up a lane |
| image tag propagation | the ApplicationSet template computes the image tag directly with `{{head_sha}}`; no Argo CD Image Updater, no cluster credentials given to CI | no new resident components, no new credentials; ArgoCD recomputes the desired state on each poll cycle, naturally idempotent. Cost is polling latency (default 30s), irrelevant for a practice app |
| Lane reclamation | PR closed/merged → next poll the generator no longer produces that parameter → the Application auto-deletes; the Application carries `resources-finalizer.argocd.argoproj.io` | industry consensus is "ephemeral must genuinely expire"; a preview environment without auto-reclamation is a resource leak. Two layers guarantee it here: generator + finalizer |
| Lane count ceiling | no hard cap in the ApplicationSet; the `pr-lanes` ResourceQuota provides backpressure instead | ApplicationSet has no native "generate at most N"; when quota runs out, extra lane pods stay Pending — graceful degradation rather than cluster damage. Enough for the PR volume of a single-person repo |

## Lane routing mechanism

The waypoint's L7 routing is a superposition of multiple `HTTPRoute`s, all with `parentRefs` pointing at the same `hello-backend` Service (ambient east-west routing convention is parentRef to a Service, not a Gateway):

- **baseline route** (static, hardcoded in the repo): catch-all with no match → `hello-backend`
- **one route per lane** (generated by the ApplicationSet): match `headers: [{name: x-pr-lane, value: "<PR number>"}]` → `hello-backend-pr-<N>`

The Gateway API spec defines that multiple HTTPRoutes on the same parent merge, with rule precedence compared in order: longest path match → method match → **header match count** → query param count. Lane rules have 1 header match, the baseline rule has 0, so lane rules always take precedence over the baseline — no manual ordering needed, and no baseline-route change when adding lanes.

This design's advantage: each lane's three resources (Deployment / Service / HTTPRoute) are exclusively owned by that PR's Application; closing the PR prunes them all together, and the baseline files are never touched from start to finish.

## Image tag propagation and CI

CI adds one workflow (reusing `placeholder-hello.yml`'s existing skeleton: QEMU → buildx arm64 → Trivy → Cosign keyless → GHCR), differing only in trigger and tag:

- `push` to main: tag `${{ github.sha }}` (for the baseline)
- `pull_request` (and the PR carries the `pr-lane` label, filtered with `if: contains(github.event.pull_request.labels.*.name, 'pr-lane')`): tag `${{ github.event.pull_request.head.sha }}`

**Must use `github.event.pull_request.head.sha`, not `github.sha`**: under a `pull_request` event, `github.sha` is the merge-commit SHA GitHub auto-generates, while the ArgoCD PR generator's `{{head_sha}}` gives the commit SHA at the PR branch tip; the two differ. Getting it wrong makes the ApplicationSet pull a tag that doesn't exist, leaving lane pods permanently `ImagePullBackOff`. This is the easiest gotcha to hit in this pipeline.

## Kyverno policy adjustment

`restrict-image-registry`(Enforce) currently requires the signature identity to end in `@refs/heads/main`; PR-built images have identity `@refs/pull/<N>/merge`, and get blocked hard. Approach:

1. The existing `restrict-image-registry` rule **excludes the `pr-lanes` namespace** — when two verifyImages policies both match, both must pass, so without exclusion the new relaxed policy is useless
2. Add `restrict-image-registry-pr-lanes`, matching only Pods in the `pr-lanes` namespace, with `subjectRegExp` accepting both `@refs/heads/main` and `@refs/pull/[0-9]+/merge`, and the same issuer and rekor settings as the original policy

Deliberately not relaxing the original policy's regex: that would let images from PR-branch signatures deploy across the **whole cluster**, using a practice feature's needs to weaken the whole cluster's main-branch guarantee. A namespace-scoped exception confines the cost to the practice namespace.

`require-vuln-scan-clean`(Enforce)'s label selector gains `hello-frontend`, `hello-backend`, maintaining phase E's "all self-built images governed" principle.

## Label and Service selector conventions

Three labels, each with its own job, not to be mixed up:

| label | value | purpose |
|---|---|---|
| `app` | `hello-frontend` / `hello-backend` | the service identity across baseline and all lanes. The Kyverno selector uses it — one entry covers all |
| `lane` | `baseline` / `pr-<N>` | distinguishes the baseline version from each lane version of the same service |
| (GitHub PR label)`pr-lane` | — | the marker on the PR deciding whether the generator creates a lane for it; unrelated to k8s labels |

**The Service selector must match both `app` and `lane`**: the baseline `hello-backend` Service selector is `app=hello-backend, lane=baseline`, and a lane's `hello-backend-pr-<N>` Service selector is `app=hello-backend, lane=pr-<N>`. With only `app`, the baseline Service would select all lane pods too, and headerless requests would land on lane versions at random — exactly the failure mode checklist item 7e is meant to falsify.

## Precondition change: Cilium `cni.exclusive: false`(high risk)

Before installing Istio, `vps_oracle/k3s/cilium/values.yaml` must be changed to add:

```yaml
cni:
  exclusive: false
```

Otherwise Cilium deletes the plugin configs istio-cni writes, ztunnel interception fails, and the whole mesh silently doesn't take effect (not an error, but "installed yet intercepts nothing", hard to diagnose).

**This is a change to the live cluster CNI, the riskiest step of the phase**: Cilium is the network source for every pod on the single-node cluster; `helm upgrade` restarts the cilium-agent DaemonSet. Existing connections of existing pods are usually unaffected (Cilium's eBPF datapath keeps running in the kernel during the agent restart), but new connections and Service resolution may fail within the tens-of-seconds agent-restart window. This step must:

- be a single isolated change with isolated verification, not mixed into the same commit as the Istio install
- confirm beforehand that `bpf.masquerade` is still off
- run a connectivity check over existing services afterward (see checklist item 1) before moving on

## Repo layout

```
vps_oracle/k3s/
  cilium/values.yaml              # modified: add cni.exclusive: false
  gateway-api/                    # new: Gateway API standard CRD(kustomization pointing at an upstream tag)
  istio/
    base-values.yaml              # new
    istiod-values.yaml            # new(incl. resources)
    cni-values.yaml               # new
    ztunnel-values.yaml           # new
  apps/
    hello/                        # reworked from placeholder-hello
      backend/
        Dockerfile                # new: nginx + a version-marking index.html
        index.html
      k8s/
        namespace.yaml            # pr-lanes, with istio.io/dataplane-mode=ambient
        resourcequota.yaml        # lane-total backpressure
        limitrange.yaml
        frontend-configmap.yaml   # nginx.conf: /api → proxy_pass hello-backend
        frontend-deployment.yaml  # reuse the existing placeholder-hello image (pin digest)
        frontend-service.yaml     # NodePort, the external entry
        backend-deployment.yaml   # baseline
        backend-service.yaml      # with istio.io/use-waypoint: waypoint
        backend-httproute.yaml    # catch-all → baseline
        waypoint-gateway.yaml     # gatewayClassName: istio-waypoint
      lane/                       # the ApplicationSet's lane template(kustomize base)
        kustomization.yaml
        deployment.yaml
        service.yaml
        httproute.yaml
  argocd/apps/
    hello.yaml                    # replaces placeholder-hello.yaml
    istio.yaml                    # new
    gateway-api.yaml              # new
    pr-lanes-appset.yaml          # new: ApplicationSet(PR Generator)
  kyverno/policies/
    restrict-image-registry.yaml           # modified: exclude pr-lanes
    restrict-image-registry-pr-lanes.yaml  # new
    require-vuln-scan-clean.yaml           # modified: label selector gains two apps

.github/workflows/
  hello-backend.yml               # new(reworked from placeholder-hello.yml)
```

The original `apps/placeholder-hello/` directory and `argocd/apps/placeholder-hello.yaml` are removed — it was a placeholder service set up in phase B for practicing CI, and this phase upgrades it into a two-tier lane practice target, not a second parallel practice app. During migration ArgoCD prunes the old one from `workloads` and creates the new one in `pr-lanes`; stateless, no PVC, no data migration involved.

## Resource budget

New resident components (initial values, adjusted after install based on measurement):

| Component | requests | limits | location |
|---|---|---|---|
| istiod | 100m / 256Mi | 500m / 512Mi | istio-system |
| ztunnel (DaemonSet ×1) | 50m / 128Mi | 200m / 256Mi | istio-system |
| istio-cni (DaemonSet ×1) | 50m / 64Mi | 100m / 128Mi | istio-system |
| waypoint | 50m / 128Mi | 200m / 256Mi | pr-lanes(counted toward the namespace quota) |
| **subtotal** | **250m / 576Mi** | **1000m / 1152Mi** | |

The industry's istiod recommendation for "small clusters" is 500m/512Mi requests, premised on about 100 mesh pods; this phase has 3~10 pods in the mesh, so it scales down. These are initial values, not final — if istiod gets OOMKilled, raise it, and write the result back to the README.

`pr-lanes` namespace ResourceQuota:

| Item | Value | Occupancy estimate |
|---|---|---|
| requests.cpu | 400m | waypoint 50m + frontend 25m + backend baseline 25m = 100m, 300m remaining |
| requests.memory | 768Mi | 128 + 64 + 64 = 256Mi,512Mi remaining |
| limits.cpu | 1200m | |
| limits.memory | 1536Mi | |

Each lane at 25m/64Mi requests → the quota fits about **8 simultaneous lanes**; from the 9th on, pods stay Pending (graceful degradation). The LimitRange reuses the `workloads` shape (defaultRequest 25m/64Mi, default 100m/128Mi) so pods without resources (including the Istio auto-generated waypoint Deployment) still get defaults and can't blow the quota.

**Overall impact**: adds about 576Mi requests. The k8s quota side has room (the `dify` namespace deletion freed 2Gi requests), but host-wide memory did not get looser — swap already at 3.0Gi. Record `free -h` and `kubectl top node` before and after install; the decision criterion is **swap usage and whether existing services get OOMKilled**, not how much k8s quota remains (loose quota is an illusion from dify's move; those services still eat memory on the same machine as compose).

## Verification checklist (phase F+G pass criteria)

1. **Existing services unharmed after the Cilium change**: after applying `cni.exclusive: false` and waiting for the cilium-agent restart to finish, `kubectl get pods -A` shows no new CrashLoop/NotReady; spot-check connectivity of the services **still on k8s** (curl vikunja, apprise, llm, lab-environment once each) and cross-pod DNS resolution, confirming the network behavior since phase A isn't broken. compose-side services ride the docker bridge, not Cilium, and aren't in this check's scope
2. `kubectl -n istio-system get pods` all Running; `istioctl version` can reach the control plane
3. `kubectl get crd | grep gateway.networking.k8s.io` shows GatewayClass/Gateway/HTTPRoute
4. `kubectl -n pr-lanes get gateway waypoint` shows `PROGRAMMED=True`, with the corresponding waypoint Deployment Running
5. `istioctl ztunnel-config workload` shows pods in `pr-lanes` onboarded (protocol field is HBONE), and pods in other namespaces **not** onboarded — direct evidence the blast-radius limit holds
6. **baseline path**: `curl http://<node>:<nodeport>/api` returns the baseline backend's content
7. **lane end-to-end**: open a PR changing `hello-backend/index.html` and add the `pr-lane` label →
   a. GitHub Actions green; GHCR has an image tagged with the PR head SHA
   b. `kubectl -n argocd get applications` shows the PR's Application, Synced + Healthy
   c. `kubectl -n pr-lanes get pods -l lane=pr-<N>` Running (proving the Kyverno signature exception took effect, not blocked at admission)
   d. `curl -H "x-pr-lane: <N>" http://<node>:<nodeport>/api` returns **that PR's content**
   e. `curl http://<node>:<nodeport>/api` (no header) still returns **baseline content** — the shared base isn't polluted by lanes; the core evidence that Camp B holds
8. **lane update**: push another commit to that PR, wait for CI + generator polling, confirm the lane auto-switches to the new image (the image tag in `kubectl -n pr-lanes describe pod` equals the new head SHA)
9. **lane reclamation**: close the PR → confirm the Application disappears and the lane's Deployment/Service/HTTPRoute in `pr-lanes` are all pruned, no residue
10. **an unlabelded PR spawns no lane**: open a PR without the `pr-lane` label, confirm the ApplicationSet generates no Application for it
11. **Kyverno exception scope is correct**: try deploying a PR-branch-signed image to `workloads` (not `pr-lanes`), confirm it's **still blocked** — proving the exception only opens on `pr-lanes`, no cluster-wide relaxation
12. Record `free -h` / `kubectl top node` before and after install; write back the pinned Istio and Gateway API versions to `vps_oracle/k3s/README.md`

## Known limitations / failure modes

- **Single-service-depth Camp B is a scaled-down model**: a real lane system must handle multi-hop propagation, data pollution when databases are shared, and routing-key propagation over non-HTTP protocols (gRPC metadata, message queues). This phase's two-tier topology validates the mechanism skeleton, not a drop-in for stateful services
- **Header propagation in real services needs application code**: nginx `proxy_pass` forwarding headers for free is a coincidence of this practice topology; switch to any self-written service, and without explicitly copying inbound headers to the outbound request, the lane breaks at the second hop
- **Polling latency**: the PR generator's default 30s poll + ArgoCD sync cycle means from CI completion to lane update there's tens-of-seconds to minutes of latency, not instant
- **Cilium + Istio ambient compatibility is a known-risky pairing**: community reports exist of ztunnel not starting under specific CNI chaining configs. If ztunnel can't start healthily and the cause isn't found quickly, rollback is cheaper than grinding — the rollback path is removing Istio's four Applications and dropping `pr-lanes`'s ambient label; Cilium's `cni.exclusive: false` can stay (harmless for a pure-Cilium environment)
- **Resources are a hard constraint, not a conservative estimate**: the host already pushed 3.0Gi into swap. If swap usage rises noticeably or existing services get OOMKilled after install, roll back the mesh directly rather than squeezing other services' quotas further — this phase's value is learning, not worth trading existing services' stability for
- **This phase needs the PR flow, but this repo normally pushes straight to main**: verifying lanes means actually opening PRs. This isn't a defect, but it means to keep using lanes after this phase, the working habit must shift to PR-based flow, else the mechanism is installed with nothing to trigger it
- **ApplicationSet has no hard generation cap**: backpressure comes from the ResourceQuota, so excess lanes stay Pending. Fine at a single-person repo's PR volume, but this design doesn't transfer directly to a multi-person team
- **The PR-branch signature exception is a real security concession**: any image in `pr-lanes` signed from this repo's PR branches can deploy. The scope is confined to the practice namespace, but that namespace shares the same kernel and API server as the others — namespaces are scope boundaries, not sandboxes

## Handoff to H

After this phase, `pr-lanes` is the only mesh-onboarded namespace in the cluster; everything else stays as phases A~E left it. Phase H (compose decommission evaluation / NPM keep-or-drop) doesn't depend on any output from this phase; conversely, if H decides to use k8s-native ingress to replace NPM, the Gateway API CRDs and Istio installed this phase can directly be one of the ingress candidates (Istio Gateway), without re-evaluating from scratch — but this is an incidental possibility, not a promised deliverable of this phase.

If canary / progressive delivery (the second half of the original G phase) is wanted later, this phase's waypoint is the L7 traffic-split point needed, plus Argo Rollouts and weighted `backendRefs.weight` in HTTPRoute — no mesh reinstall or redesign needed.