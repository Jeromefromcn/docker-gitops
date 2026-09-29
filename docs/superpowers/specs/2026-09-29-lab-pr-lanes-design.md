# Lab Demo — PR Lanes (Sub-project 3)

Date: 2026-09-29

Sub-project 3 of the [lab SDLC demo roadmap](2026-09-25-lab-sdlc-demo-roadmap.md): a pull request on the fork (`Jeromefromcn/spring-petclinic-microservices`) gets its own lane in `lab-environment` — CI builds, scans and signs the changed service, ArgoCD deploys it next to the baseline, and only requests carrying the lane header reach it, across every hop. As a prerequisite the whole lab moves from locally built `ops-lab/*` images to signed GHCR images, so Kyverno's signature verification covers production and lanes alike. The last section fixes the interfaces sub-project 4 (Argo Rollouts, still only proposed) must respect, so 4 never has to reopen this design.

Built on [2a's framework](2026-09-27-lab-demo-runbook-framework-design.md) (fixed page structure, `demo-window` / `demo-evidence` / `demo-reset`, ≥ 2 pieces of evidence with ≥ 1 from the infrastructure layer) and the pr-lanes pattern proven on `hello` (`k3s/argocd/apps/pr-lanes-appset.yaml`, phases F/G and I).

## Decisions (agreed 2026-09-29)

| Topic | Decision | Why |
|---|---|---|
| 3 and 4 together? | No. Designed jointly (§5 of this spec), implemented separately, 3 first | 3 alone spans two repos and four mechanisms. 4 builds on 3's image source — doing 4 first on local images would be reworked once 3 lands. 4 is still not agreed |
| What a lane deploys | **Only the services the PR changes**; every other hop is the baseline | Demonstrates the real mechanism (header propagation + per-hop routing), and one lane costs about one JVM (384Mi). Deploying all four services per lane would cost ~1.5Gi and fit nowhere |
| How a lane knows its services | **PR label `lane:<service>`**, one per service, several allowed | ApplicationSet cannot see a PR's changed files. A label is explicit, is a clear demo step, and is what hello's `pr-lane` label already does. Auto-labelling from the diff can be added later on top without changing anything here |
| Capacity | Lanes live in `lab-environment` and **share the blue-green headroom**; at most 2 lane pods; mutually exclusive with page 12's 5-replica green | The quota and the node have no other room (§3). Same namespace keeps ServiceAccounts, so postgres/redis principals need no change |
| Baseline images | **Migrate the baseline to signed GHCR images too**, including `customers-service-canary` (`lab-v2`) | Otherwise the story is "PR images are signed, production is not". Adds negative evidence: an unsigned or locally built image is refused at admission |
| Lane routing | **One header-only HTTPRoute per lane**, parented on the baseline Service; the resident VirtualServices are not touched | Phase I observed that on one host, HTTPRoute rules are evaluated before VirtualService rules: a header-only HTTPRoute captures only the lane's requests and everything else falls through to the VirtualService. Pages 09–13 stay untouched. Per-lane VirtualServices on the same host are undefined in the mesh (merging is gateway-only); a static rule in the resident VS allows one lane per service and edits customers' VS |

## Design

### 1. Image supply chain

**Fork CI** — new `.github/workflows/lab-images.yml` in the fork:

| Trigger | Builds |
|---|---|
| push to `main` or `lab-v2` | all four services (baseline, canary) |
| `pull_request` (`opened`, `synchronize`, `reopened`) | the services whose `spring-petclinic-<service>/` directory the PR changes; all four if the root `pom.xml` or `docker/` changes |
| `workflow_dispatch` (inputs `sha`, `unsigned`) | all four at a given commit — used to build the two `lab-v2` commits the canary patches pin (`ce942c9` v2, `16b18eb` v2-bad), and to publish the unsigned negative-test image `ghcr.io/jeromefromcn/petclinic-unsigned:demo` |

- Why not by label: a label triggers the ApplicationSet (polling every 30 s) and CI at the same moment, so the lane pod would be created minutes before its image is signed and Kyverno would refuse it (`FailedCreate`, then ReplicaSet backoff). Building on every PR push means the image is signed before anyone adds the label; the page waits for CI, then labels.
- One matrix job per service, on GitHub's native arm64 runner (`ubuntu-24.04-arm`, free for public repos), running the fork's Maven `-PbuildDocker` build. No QEMU: emulation crashes in the Spring Boot layertools extract step (recorded in `lab-environment/scripts/build.sh`).
- Image `ghcr.io/jeromefromcn/petclinic-<service>`. Tag: the PR **head SHA** on `pull_request` (not the merge SHA — hello's pitfall), `github.sha` otherwise.
- Same shape as `.github/workflows/hello-backend.yml` after the build: push → Trivy (`CRITICAL`, `ignore-unfixed`, fail) → Cosign keyless sign by digest. (Briefly report-only on 2026-09-29 while the fork was on Spring Boot 4.0.1, whose dependencies carried fixable CRITICAL CVEs; the gate was restored the same day after the upgrade — see Implementation results.)
- GHCR packages are public, so the cluster needs no pull secret.
- The fork's existing `maven-build.yml` is left as is.

**Baseline promotion stays git-first**: once CI has published a tag, a commit in this repo changes the image in `k3s/apps/lab-environment/k8s/*.yaml`. Baseline refs are digest-pinned (`@sha256:<digest>` with a `# fork <sha12>` comment) because `restrict-image-registry` keeps the default `verifyDigest: true`. No Image Updater — "a release is a git commit" stays true for the demo. `lab-environment/scripts/build.sh` and the local import into oracle2's containerd are marked retired for the k3s lab in its README (the lab-environment repo's own docker-compose use of `ops-lab/*` is out of scope).

**Kyverno**:

- `restrict-image-registry`: `subjectRegExp` also accepts `^https://github\.com/Jeromefromcn/spring-petclinic-microservices/\.github/workflows/[^/]+\.yml@refs/heads/(main|lab-v2)$`; the rule additionally excludes Pods carrying the `lab.jerome/lane` label.
- New `restrict-image-registry-lab-lanes`: matches Pods in `lab-environment` **with** the `lab.jerome/lane` label; accepts the fork's `refs/pull/[0-9]+/merge` subject (as well as `main`) with `verifyDigest: false`, mirroring `restrict-image-registry-pr-lanes`.
- New validate rule `lab-business-images-from-ghcr`: in `lab-environment`, Pods whose `app` is one of the four services (or its `-lane` variant) must use `ghcr.io/jeromefromcn/*` images. `verifyImages` only checks references that match `ghcr.io/jeromefromcn/*` — on its own it would still admit a locally built `ops-lab/*` image, so without this rule "only CI-signed images run" would be false.
- `require-vuln-scan-clean`: the `app` list gains the four lab services, and the four baseline Deployments drop `trivy-operator.skip` so reports exist. `customers-service-canary` and lane pods keep the label — CI's Trivy gate covers their images. Enabled only after the Boot 4.0.8 images showed 0 fixable CRITICALs in Trivy Operator's reports; with fixable CRITICALs present the gate would refuse the next pod of a ReplicaSet (`FailedCreate`).
- **Order**: the Kyverno changes are deployed and confirmed before any lab image is switched, with `lab-business-images-from-ghcr` in `Audit` until the switch is complete and `Enforce` after. Switching first would have the old rule refuse every new pod for the wrong signer; enforcing the registry rule first would refuse the current `ops-lab/*` pods on their next restart.

Known gap, accepted: anyone able to create a Pod in `lab-environment` can add the lane label and get the looser signer rule. This is a single-operator cluster; the rule is confined to one namespace. Recorded in the policy's comment.

Owner action (confirmed): `k3s/README.md` "Rotating the GitHub PAT" scopes the ApplicationSet's `github-pr-generator-token` to `Jeromefromcn/docker-gitops` only, so the owner must regenerate it with the fork added.

### 2. Lanes

**ApplicationSet** `k3s/argocd/apps/lab-lanes-appset.yaml`: a matrix generator — a list of the four services × `pullRequest` on `Jeromefromcn/spring-petclinic-microservices` filtered by label `lane:{{.service}}` (the second generator takes the first's parameters). Each (PR, service) pair becomes Application `lab-<service>-pr-<N>`, destination namespace `lab-environment`, source path `k3s/apps/lab-environment/lanes/<service>/`, `automated {prune, selfHeal}`, the resources finalizer. Closing the PR or removing the label deletes the Application and its resources. `kustomize.images` is the plain-string form (hello's pitfall).

**One kustomize directory per service** (`lanes/<service>/`, because port, env and ServiceAccount differ), renamed per PR by the ApplicationSet's patches like hello's:

| Resource | Content |
|---|---|
| Deployment `<service>-pr-<N>` | 1 replica; the baseline's **ServiceAccount** (so postgres/redis L4 principals and shared data need no change); labels `app: <service>-lane`, `lab.jerome/lane: pr-<N>` — **never** `app: <service>`, or the baseline Service would select it and send it ordinary traffic; resources as the baseline (384Mi / 20m); env as the baseline; no PDB |
| Service `<service>-pr-<N>` | selects the lane pod; no `istio.io/use-waypoint` |
| HTTPRoute `<service>-pr-<N>` | `parentRefs` = the baseline Service `<service>`; one rule matching header `x-pr-lane: <N>` only; `timeouts.request: 3s` matching the VirtualService's GET timeout |

`api-gateway` can have a lane too: the ingress HTTPRoute sends to the `api-gateway` Service, which already goes through the waypoint (`ingress-use-waypoint`), so the same header rule applies there.

**Authorization**:

- The L7 caller policies target the baseline Services. A lane request enters the baseline's VIP on the waypoint, is authorized there, then routed by header — so lanes inherit "who may call" with no change.
- New resident L4 policy `lane-direct` (selector: `lab.jerome/lane` exists) allowing only the waypoint ServiceAccount, plus prometheus on the metrics port — the same shape as the `<service>-direct` policies. Without it a lane pod has no ALLOW policy and anyone could reach it directly.

**Lane header propagation**: the fork adds `management.tracing.baggage.remote-fields: x-pr-lane` to the four services (and `correlation.fields`, so the lane number lands in the log MDC). Micrometer Tracing then copies the incoming header onto every instrumented outgoing call, and each hop's waypoint routes on it. One fork commit, shipped with the first GHCR baseline.

**Spike first** (implementation step 1; a failure sends the design back here):

1. Apply by hand a header HTTPRoute on `visits-service` and a lane Deployment/Service running visits' baseline image with a marker env.
2. Confirm: header requests reach the lane; requests without it still get the VirtualService (retries, outlier detection, customers' `stable` subset pin unchanged — access log and `demo-reset`'s baseline check); vets' Lua rate limit still applies; a request to a customers endpoint that calls visits carries the header through gateway → customers → visits. api-gateway is reactive Spring Cloud Gateway, so its baggage propagation is the part most worth measuring rather than assuming. Since the header propagation needs the fork change, this part of the spike runs once step 2's images exist; the routing part runs first.
3. Delete the hand-applied resources.

### 3. Capacity

Measured 2026-09-29: lab quota 5424Mi used of 9472Mi — the remaining ~4Gi is the derived room for a 5-replica blue-green green (1920Mi), one surge pod per rolling Deployment (1824Mi) and the `db-init` hook (64Mi). vps-oracle2's 10263Mi allocatable already holds the full quota plus ~640Mi of DaemonSets. There is no unreserved room for lanes, and the owner's rule is that `FailedCreate` / `Pending` are not acceptable.

- **At most 2 lane pods at once** (768Mi / 40m), inside the blue-green headroom. Quota unchanged.
- **Mutually exclusive with page 12's 5-replica green**, enforced by process in three places: page 12's preconditions ("no lane pods"), page 18's preconditions ("green at 0"), and `demo-reset`'s routing baseline check, which fails on any Pod carrying `lab.jerome/lane`.
- The 2-lane cap is written in the runbook and the quota's derivation comment (`k8s/namespace.yaml`, README), not in an admission rule.

### 4. Runbook, evidence, tests

**Page `docs/demo/18-pr-lane.md`**, fixed structure:

- **Flow**: open a PR on the fork whose visible change is a response header `X-Visits-Build: lane`, added by a commit on the fork branch `demo/pr-lane` (kept for reuse: the PR is closed, not merged) → wait for CI → add label `lane:visits-service` → CI builds, scans, signs → ArgoCD shows `lab-visits-service-pr-<N>` → the same URL with and without `x-pr-lane: <N>`, side by side → close the PR → the lane disappears.
- **Evidence** (★ = infrastructure layer):
  - ★ Kyverno: the lane pod passed `restrict-image-registry-lab-lanes` — the Pod annotation `kyverno.io/verify-images` (`{"<image>":"pass"}`), confirmed on hello's pods 2026-09-29.
  - ★ Negative: server-side dry-runs in `lab-environment` of an unsigned GHCR image and of an `ops-lab/*` image are both refused.
  - ★ waypoint access log: header requests go upstream to `visits-service-pr-<N>`, the rest to `visits-service`.
  - ★ ArgoCD: the Application's creation and deletion times against the label and close events.
  - app: a Jaeger trace with baggage `x-pr-lane` on gateway, customers and visits spans.
- **Talking points**: lanes deliberately do not inherit retries and outlier detection (a test lane is not production traffic); the HTTPRoute-before-VirtualService ordering and why an unconditional HTTPRoute would swallow the host (phase I); head SHA vs merge SHA; why `verifyImages` alone does not stop a local image; the lane label's looser signer rule and its namespace confinement.
- **Reset**: close the PR or remove the label.

Demo order: 18 goes after the routing scenarios (09–13) and before resilience; it must not overlap 12.

**Tests**:

- `tests/test-demo-helpers.sh`: stub test that the routing baseline check fails when a lane pod exists.
- For every `lanes/<service>/`: `kustomize build` succeeds and no rendered Pod template carries `app: <service>` — the regression test for the baseline Service selecting a lane pod. Wired into the CI job `lab-demo-helpers`.
- The fork workflow is verified end to end with a real test PR.

### 5. Interfaces with sub-project 4 (Argo Rollouts)

Constraints 4's spec must honour; nothing here implements 4.

**Lane × Rollout**

- Lanes stay plain Deployments even if 4 turns vets or visits into a `Rollout` — a lane is a test path, not a release.
- 4 must use Rollouts' **Istio VirtualService** traffic router, **not** the Gateway API plugin. Lane HTTPRoutes are evaluated before VirtualService rules, so Rollouts rewriting VS weights only moves header-less traffic. Rollouts writing HTTPRoutes would compete with lane HTTPRoutes for rule order on the same host.
- Rollouts' stable/canary Service selectors must keep `app: <service>`; lane pods carry `app: <service>-lane` and can never be selected.
- The L4 `<service>-direct` policies and `lab-business-images-from-ghcr` select on `app`; Rollout-managed pods keep `app: <service>` and stay covered.

**Capacity**

- A Rollout's canary pod takes that service's surge slot (384Mi of the 1824Mi surge budget) — one canary or surge pod at a time per release, so the quota is unchanged.
- The Rollouts controller runs in its own `argo-rollouts` namespace, outside the lab quota and outside the Kyverno mutate that pins `lab-environment` to oracle2, so it schedules on vps_oracle. 4's spec measures its memory and checks vps_oracle's headroom.
- Lane demos, page 12's blue-green and a Rollout release share oracle2's headroom **in time, not in space**. `demo-reset`'s check covers lane leftovers now and must cover "no Rollout mid-release" once 4 exists.

**Kyverno**

- `verifyImages` matches Pods, so pods a Rollout creates through its ReplicaSets are verified with no rule change.
- **Unverified, for 4 to measure**: whether Kyverno's autogen covers `Rollout`. If not, an unsigned image surfaces as a ReplicaSet `FailedCreate` rather than a rejected `Rollout` apply — later and quieter. Fix, if needed: the `pod-policies.kyverno.io/autogen-controllers` annotation.
- `require-vuln-scan-clean` looks up Trivy reports by `ownerReferences[0].name` (the ReplicaSet). Rollouts' ReplicaSets are named `<rollout>-<hash>` like a Deployment's; expected to work, 4 verifies.

**Service choice**: whichever of vets / visits 4 picks, it can still have lanes. A Rollout demo and a lane demo on the same service must not run at once, or their evidence mixes; page 18's preconditions say so.

## Implementation order

Every push touching `k3s/` is approved by the owner first.

1. Spike, routing part (§2), hand-applied and removed.
2. Fork: `lab-images.yml` + the baggage config; confirm signed images in GHCR for `main` and `lab-v2`. Then the spike's propagation part.
3. Kyverno rule changes (`lab-business-images-from-ghcr` in `Audit`).
4. Switch the baseline Deployments and the canary to the GHCR images (one rolling release); then `lab-business-images-from-ghcr` to `Enforce`.
5. `lane-direct` policy, `lanes/<service>/` kustomize, the ApplicationSet (generator token checked).
6. Page 18, `demo-reset` / baseline check, tests, page 12's precondition, README and quota comment.
7. One full rehearsal; its saved evidence is the scenario's backup.

## Acceptance criteria

1. All five business Deployments (including `customers-service-canary`) run signed `ghcr.io/jeromefromcn/petclinic-*` images; nothing references `ops-lab/*` for them.
2. In `lab-environment`, an unsigned GHCR image and an `ops-lab/*` image for a business service are both refused by Kyverno.
3. Adding `lane:<service>` creates the lane without manual steps; closing the PR removes it completely.
4. Header requests reach the lane; 100 % of header-less requests reach the baseline (access-log count over the demo window).
5. The lane header propagates across gateway → customers → visits (Jaeger).
6. Pages 09–13 and `demo-reset` still pass unchanged.
7. Two lanes at once produce no `FailedCreate` or `Pending`.

## Out of scope

- Sub-project 4 itself (§5 only fixes its interfaces).
- Automatic `lane:*` labelling from the PR diff.
- Lanes with their own database or data isolation — lanes share the baseline's postgres and redis.
- `mcp-toolkit`'s image (not a PetClinic service; stays `ops-lab/*`, outside `lab-business-images-from-ghcr`).
- The lab-environment repo's docker-compose flow.

## Implementation results

Implemented and rehearsed 2026-09-29 ([plan](../plans/2026-09-29-lab-pr-lanes.md); rehearsal evidence [`docs/demo/evidence/pr-lane.txt`](../../demo/evidence/pr-lane.txt)).

**Acceptance criteria**

1. **Pass.** api-gateway, customers-service, vets-service, visits-service and `customers-service-canary` run digest-pinned `ghcr.io/jeromefromcn/petclinic-*` images (fork `main` 70caf2d, canary `lab-v2` ce942c9); every running pod's `kyverno.io/verify-images` is `pass`. Nothing references `ops-lab/*` for them.
2. **Pass.** Server-side dry-runs in `lab-environment`: the unsigned `ghcr.io/jeromefromcn/petclinic-unsigned:demo` is refused by `restrict-image-registry` ("no matching signatures"); `ops-lab/visits-service:21d8461c6ce4` is refused by `lab-business-images-from-ghcr`; the signed main-branch digest is admitted.
3. **Pass.** Adding `lane:visits-service` to fork PR #1 produced a Ready lane pod 63 s later (Application `lab-visits-service-pr-1`, Synced/Healthy) with no manual step. Closing the PR removed the Application, pod, Service and HTTPRoute; `demo-reset pr-lane` returned `baseline OK` 44 s after the close.
4. **Pass.** Page 18 window: all 15 header requests (10 direct, 5 via customers-service) went to `visits-service-pr-1`, and none of the header-less or generator requests did; 15 reached the baseline. Customers lane (PR #2): 5/5 header requests on `customers-service-pr-2`, 10/10 header-less on `http/stable`.
5. **Pass, with different evidence than planned.** One Jaeger trace (14 spans) covers api-gateway, customers-service, visits-service and the waypoint's span named after `visits-service-pr-1`. The `tag-fields` baggage tag never appears on any span under Spring Boot 4.0.1 / Micrometer Tracing 1.6.1 (root cause not found), so the evidence uses the waypoint span, not an `x-pr-lane` tag. Propagation itself was measured before lanes existed with a hand-applied spike: 5/5 header requests went gateway → customers → visits-spike, 5/5 header-less to the baseline.
6. **Pass.** Page 10 run end to end on the GHCR canary digests: 179 × 200 / 21 × 500; evidence 3/3 (canary 10 %, 5xx only on the canary, rollback deployed); `baseline OK`. `test-demo-helpers.sh` (`git apply --check` of every patch) passes.
7. **Pass.** With lanes `visits-service-pr-1` and `customers-service-pr-2` Running on vps-oracle2 at the same time: no `FailedCreate` and no `Pending` pods; quota `requests.memory` 6192Mi = 5424Mi + 768Mi, `requests.cpu` 590m.

**Spike (2026-09-29).** Waypoint route order for `visits-service:8082`: [0] the HTTPRoute header match `x-pr-lane: 999` → lane (retries 2, timeout 3s), [1] the VirtualService GET route (retries 2, 3s), [2] the VirtualService catch-all (no retries, 5s). The vets rate limit still applied (6 × 200 / 24 × 429). Lane upstream cluster: `outbound|8082||<svc>-pr-<N>.lab-environment.svc.cluster.local`; baseline: `inbound-vip|8082|http|<svc>…`.

**Deviations from the plan and this spec**

- **Trivy is report-only** (owner decision). The first CI run failed its gate on every image. Fixable CRITICAL CVEs per image: visits 10, customers 9, vets 9, api-gateway 4 (tomcat-embed-core 11.0.15, netty-handler 4.2.9, bcprov-jdk18on 1.81, spring-boot 4.0.1). Measured locally: Boot 4.0.8 + Spring Cloud 2025.1.3 + tomcat 11.0.26 clears all four images (the control on 4.0.1 still shows 10). Consequence: the lab stays outside `require-vuln-scan-clean` and keeps `trivy-operator.skip`. The plan's vuln-gate step and its label removal were dropped.
- **The PR generator token was not regenerated.** Fine-grained PATs can read public repositories, and `lab-lanes` generated PR #1's Application with the existing token. Docs updated instead.
- Lanes get Istio's default retry policy (2 attempts) on their HTTPRoute, not "no retries". Page 18 and the lane HTTPRoute comments say so.
- A cold lane JVM answered its first calls through customers with 504 (the 3 s timeout). Page 18 warms the lane up and leaves a quiet gap before the window.
- Workflow fixes: `actions/checkout` reads a short `sha` input as a branch name, so the plan job resolves it to the full SHA first. The "Locate the jar" step is a glob loop (actionlint SC2010). The push to `lab-v2` that added the workflow did not trigger a run; nothing consumes that build.
- The `lane:<service>` labels had to be created on the fork before the first `gh pr edit --add-label`. Page 18's preconditions now say so.

**Update, later on 2026-09-29: Trivy gate restored.** At the owner's request the report-only deviation was reversed:

- Fork `main` 9dbe3b9: Spring Boot 4.0.1 → 4.0.8, Spring Cloud 2025.1.0 → 2025.1.3, `tomcat.version` pinned to 11.0.26 (Boot 4.0.8 manages 11.0.24, still vulnerable). Full `mvnw clean install` passes. `lab-images.yml` fails on fixable CRITICALs again (`exit-code: 1`); all three CI runs (main, the `lab-v2` push, the v2 dispatch) passed the gate.
- `lab-v2` was rebuilt on the upgraded `main` (force-pushed; the old history is tag `lab-v2-boot-4.0.1`). Canary v2 is now `c44d33230743`, v2-bad `77962eada66c`. `X-App-Version` is the build's own SHA, so pages 09–12 quote the new values. `demo/pr-lane` was rebased too.
- The baseline and canary run the new digests. The four baseline Deployments dropped `trivy-operator.skip`, and Trivy Operator's reports show `critical=0` for all four ReplicaSets. `require-vuln-scan-clean` then gained the four services. Probes: a dry-run pod owned by the clean customers ReplicaSet is admitted; one labelled `app: visits-service` and owned by a ReplicaSet whose report has fixable CRITICALs is refused by `block-critical-fixable-cves`.
- Accepted cost: a CVE published later against a running image blocks that ReplicaSet's next pod until a patched release, as for hello.
