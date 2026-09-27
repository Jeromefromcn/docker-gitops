# Lab Demo — Routing Scenarios (Sub-project 2b)

Date: 2026-09-28

Sub-project 2b of the [lab SDLC demo roadmap](2026-09-25-lab-sdlc-demo-roadmap.md): canary by instance ratio, canary by weight, header/cookie gray release, traffic mirroring and blue-green on `lab-environment`, as runbook scenarios 09–13 built on [2a's framework](2026-09-27-lab-demo-runbook-framework-design.md) (fixed page structure, `demo-window` / `demo-evidence` / `demo-reset`, `demo:` commits pushed to `main`, ≥ 2 pieces of evidence with ≥ 1 from the infrastructure layer).

## Decisions (agreed 2026-09-28)

| Topic | Decision | Why |
|---|---|---|
| What "v2" is | A real commit on a branch of the petclinic fork, built by `build.sh` into SHA-tagged images: **v2-good** and **v2-bad** | Realistic, not pretty: a canary of the same code is hollow under questioning. Two builds let the demo show both a clean rollout and a caught regression |
| v2-bad's regression | HTTP 500 on a deterministic subset of owners, from a realistically shaped bug | A 500 is visible directly in Envoy's `response_code`. A latency regression would be blurred by the 1 s `perTryTimeout` (sub-project 1 trap 1) |
| Service | `customers-service` only | ×5 replicas make the instance-ratio canary natural (5 + 1); header routing reaches it on the `/api/customer/**` path |
| Lifecycle | A resident "next version" slot: `customers-service-canary` at `replicas: 0`, DestinationRule subsets and a VirtualService pinned to `stable`, all in git permanently | Each scenario is then a few-line diff — "a release is a number in git". The slot-at-zero shape is common in production |
| Blue-green capacity | Green at **5 replicas**, equal to blue. Paid for by decommissioning dify on vps-oracle2 (the owner no longer uses it) and raising the lab memory quota to 9.5Gi | Textbook blue-green: green can take 100 % with the same capacity. The 3-replica alternative fitted in 8.75Gi but needed explaining |

## Design

### 1. Resident resources (`k3s/apps/lab-environment/k8s/`)

| Resource | Change |
|---|---|
| `customers-service` Deployment (stable / blue) | Pod template gains `track: stable` and a `version` label. **The selector stays `app: customers-service`** — selectors are immutable, and the overlap with the canary is harmless: each ReplicaSet's selector carries `pod-template-hash` and pods belong to their owner by `ownerReference`. Adding the labels rolls the Deployment once (maxSurge 1 + preStop; zero errors expected, see acceptance 4) |
| **New** `customers-service-canary` Deployment | `replicas: 0` at rest, image = v2-good's SHA tag, labels `app: customers-service`, `track: canary`, `version: v2`. ServiceAccount, env, probes, resources and preStop identical to stable, so the identity-based AuthorizationPolicies and postgres' L4 policy cover it with no policy change |
| `customers-service` DestinationRule | Adds `subsets: stable` (`track: stable`) and `canary` (`track: canary`); the existing `outlierDetection` and `connectionPool` stay at the top level and apply to both |
| `customers-service` VirtualService | Both existing routes (GET with retries, everything else without) get `subset: stable` on their destination. Timeouts and retries unchanged. This pin is the routing baseline every scenario returns to |
| Access log (`k3s/istio/istiod-values.yaml`, provider `lab-json-accesslog`) | Adds `app_version: "%RESP(X-APP-VERSION)%"`. `upstream_cluster` is already logged and carries the subset name (`outbound\|8081\|canary\|customers-service…`). Only the lab uses this provider, so pr-lanes is unaffected. The request header used by scenario 11 is deliberately **not** logged — its evidence works by counting instead |
| PodDisruptionBudget | Unchanged. `minAvailable: 3` selects by `app`, so canary pods count toward it — safer during blue-green, not riskier |

**Fork (`spring-petclinic-microservices`)**, on a branch, two commits → two SHA tags imported with `push-to-k3s.sh`:

- **v2-good**: customers-service responses carry an `X-App-Version` header whose value is injected at build time (not a literal in code), plus a small, harmless visible change.
- **v2-bad**: v2-good plus a realistically shaped bug — e.g. a new computed field that throws on a particular data shape — making `GET /owners/{id}` return 500 for a deterministic subset of owners. Which owners, and therefore the expected error fraction, is fixed when the bug is written and recorded in the scenario pages.

Main stays on the fork's current SHA; the stable Deployment's image does not change in 2b.

### 2. Scenarios

Numbered 09–13 and run after 07, before 04 (roadmap: routing before resilience). Run order: **09 → 10 → 11 → 13 → 12**. The story it tells:

1. 09: without a mesh, the canary share is tied to the replica count.
2. 10: the mesh decouples the share from the replica count and bounds a bad version's blast radius to its weight.
3. 11: only chosen users see the new version.
4. 13: a bug is found without sacrificing any users.
5. 12: blue-green goes last because it starts five JVMs, the heaviest step.

Every page: `demo:` commit → `git push &&` wait for ArgoCD to sync that SHA **with a deadline** (the correct form of 2a's deferred minor A2, used from the start here) → a fixed number of `curl`s with `-D-` to show `X-App-Version` → `demo-window stop` → `demo-evidence`. The undo is a verbatim `git revert` of the scenario's `demo:` commits on the page — visible to the interviewer, as in 02/07 — and `demo-reset` then verifies the baseline.

| # | Scenario | Diff (canary slot + VS) | Image | Evidence (★ = infrastructure layer) |
|---|---|---|---|---|
| 09 | Canary by instance ratio | canary `replicas: 1`; VS routes drop the `subset` pin | v2-good | ★ waypoint access log grouped by `upstream_cluster` subset: canary share in [8 %, 30 %] (expected 1/6); `X-App-Version` counts from the page's curls in the same band |
| 10 | Canary by weight; catch a bad version; roll back | canary `replicas: 1`; VS weights stable 90 / canary 10; after the 5xx are visible, `git revert` | **v2-bad** | ★ every 5xx in the window has the canary subset, stable 5xx = 0, canary share in [3 %, 20 %]; ★ ArgoCD synced to the revert's SHA; the page's curls go to an affected owner id, so their non-200 share lands in the same [3 %, 20 %] band (the generator's own errors are reported, not required: at ~1 rps × 10 % × the affected fraction it may see none in a few minutes) |
| 11 | Header / cookie gray release (A/B) | VS gains a first rule: header `x-canary: "true"` or cookie `canary=1` → subset canary | v2-good | ★ canary-subset requests in the window equal exactly the N header/cookie curls the page sent (the generator sends neither, so it cannot pollute the count); everything else stable; the two groups' `X-App-Version` side by side. Note: the same header on `/api/gateway/owners/{id}` still lands on stable |
| 13 | Traffic mirroring | stable serves as usual; the GET route gains `mirror: {subset: canary}`, `mirrorPercentage: 100` | **v2-bad** | ★ requests whose `authority` ends in `-shadow` exist and include 500s (the page's curls go to an affected owner id, so the shadow is guaranteed to hit the bug); user-facing side (generator + page curls) all 200 in the window; canary pod's Spring `http_server_requests_seconds_count{status="500"}` increased |
| 12 | Blue-green switch | ① canary `replicas: 5`, wait for 5/5 Ready ② VS stable 0 / canary 100 ③ instant rollback: revert ② ④ revert ① | v2-good | ★ access-log subsets: 100 % stable before ②'s sync, 100 % canary after it (a few seconds of transition tolerated), 100 % stable after ③; ★ ArgoCD synced each of the three SHAs; generator zero errors over the whole window. Canary P99 in the first 60 s after ② recorded as a note (cold JVMs) |

Talking points specific to 2b (in addition to pitfalls actually hit during implementation):

- **10**: 500 is deliberately outside `retryOn`. If it were retried, the retry could land on stable and **hide** the canary's bug — a second reason for sub-project 1's decision, beyond not multiplying damage. With one canary pod, `maxEjectionPercent: 50` floors to 0: outlier detection will not eject the only canary host.
- **13**: only GETs are mirrored because canary and stable share one database — mirroring a POST writes twice. Mirroring is fire-and-forget (responses discarded) and gives the canary 100 % of the read load.
- **11**: the header survives only where the gateway proxies the request (`/api/customer/**`). The aggregation path (`/api/gateway/owners/{id}`) makes a new request and drops it — the reason sub-project 3's lanes need application-level header propagation.
- **12**: the cost is double capacity (dify was decommissioned for it). Green's JVMs are cold, so P99 rises for the first tens of seconds after the switch. Both versions share one schema, so v2 cannot carry an incompatible schema change — blue-green does not solve data migration.
- Every push runs the `db-init` PreSync hook; the quota derivation (Capacity, below) includes it.

### 3. Helpers and evidence

No new helper commands. `lib.sh` gains, and five `scenarios/*.sh` files use:

- **Routing baseline** in `baseline_check`, read from the live objects, not only from ArgoCD's Synced status: canary `spec.replicas` = 0; every VS route targets only `subset: stable` — no weights, no `mirror`, no header/cookie match; canary image = git's v2-good tag. A scenario whose revert was forgotten therefore fails `demo-reset`.
- **Zero-replica handling**: `readyReplicas` is absent at 0, and today's `"$got" = "$want $want"` comparison would misread it. An empty value is treated as 0.
- **Subset extraction**: `loki_by upstream_cluster` results reduced to their third `|`-separated field.
- Shares are judged against the bands in §2's table (binomial tolerance for N ≈ 120 page requests plus the generator's ~1 rps).

Evidence functions follow 2a's `rec_if <layer> …` pattern and 2a's `settle()` window extension.

## Capacity

Measured 2026-09-28 on vps-oracle2: dify's nine containers use ~1.40Gi RSS; the other containers (sillytavern, glances, portainer-agent, node-exporter) ~0.39Gi. Node capacity 11927Mi; DaemonSet requests 512Mi; lab steady-state requests 5424Mi.

1. **Decommission dify (prerequisite, its own commits).** `docker compose down` on `vps_oracle2/compose/dify` **without `-v`** — the volumes stay on disk; deleting them is a separate decision for the owner. Then remove its ~15 references across the repo (NPM host, homepage card, the shared postgres/redis pools on vps_oracle, inspector checks, READMEs), one stack or component per commit. Whether to drop dify's postgres/redis pools on vps_oracle is listed and confirmed with the owner before doing it.
2. **Lower vps-oracle2's `system-reserved`.** After dify is down, re-measure the OS plus the remaining docker stacks and set `system-reserved` memory to that measurement plus a margin (expected ~2Gi → ~1Gi); `kube-reserved` unchanged. Allocatable rises from ~9.4Gi to ~10.4Gi. Applying it restarts k3s-agent (pods are not recreated, kubelet reconnects) — confirmed with the owner before running.
3. **Raise the lab quota `requests.memory` 8Gi → 9.5Gi**, derivation written into `namespace.yaml`: steady 5424 + green 5 × 384 = 1920 + one full release's surge 1824 + hook 64 = **9232Mi → 9.5Gi (9728Mi)**. With DaemonSets, 9728 + 512 = 10240Mi must be ≤ the allocatable from step 2 — that inequality is step 2's acceptance check; if it fails, step 2 is revisited, not the green size.
4. **CPU unchanged.** Green adds 5 × 20m, taking the lab peak from 770m to 870m, under the 1200m quota.

Real RAM during blue-green: ~7069 − 1400 + 5 × 330 ≈ **7.3G of 11.9G**, with 4G swap unused. The principle stays: the quota bounds requests only, limits remain overcommitted, and "never `Pending` / `FailedCreate`" is what the inequality in step 3 guarantees.

## Testing

- **Helpers** — `tests/test-demo-helpers.sh` with stubbed Loki / kubectl output: the routing baseline fails on a leftover weight, `mirror` or header match and on canary replicas ≠ 0, and passes when canary `readyReplicas` is absent at 0; the share bands' edges; 12's before/after-switch judgement.
- **Fork** — v2-good and v2-bad each get a unit test for their change (header present; the bug reproduces on the chosen owners and not on others), in the fork's own test suite.
- **Mechanism checks before writing pages** (measured, not assumed): header and cookie reach the waypoint on `/api/customer/**`; the mirrored request's authority carries `-shadow` in this Istio version; the `X-App-Version` response header passes back through api-gateway to the client; `upstream_cluster` shows the subset on the waypoint.

## Acceptance criteria

1. A full rehearsal of 09–13 in the order 09 → 10 → 11 → 13 → 12; every `demo-evidence` passes. Output saved to `docs/demo/evidence/`.
2. Afterwards `demo-reset` reports `baseline OK`, including the routing baseline; `main` carries the `demo:` commits paired with their reverts.
3. No `Pending` or `FailedCreate` during the whole rehearsal (checked against the Lab Pod Pending / Quota Near Limit alerts and kube events); quota usage during blue-green recorded.
4. The one-time rollout that adds `track: stable` has zero generator errors.
5. Updated: lab README (the slot, subsets, quota derivation), `docs/demo/README.md` order table, roadmap status (2b done; memory-ceiling note rewritten), `k3s/install/agent-vps-oracle2/` reservation comment, dify's removal from every README that lists it.

## Out of scope

- Automated promotion and analysis (sub-project 4, Argo Rollouts).
- Canary of api-gateway, vets or visits.
- HPA (roadmap's elastic-scaling row).
- 2a's deferred minors, except that the new pages use the correct sync-wait form from the start; the old pages are not changed here.
- Deleting dify's data volumes.
