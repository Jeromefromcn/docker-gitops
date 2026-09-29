# lab-environment SDLC Demo Roadmap

Date: 2026-09-25

Status tracker for turning `lab-environment` into a production-shaped environment used for live interview demos of SDLC capabilities. Each sub-project gets its own spec → plan → implementation cycle; this file records the whole arc so any session can pick up where the last one stopped. Update the **Status** column when a sub-project changes state.

## Goal

The owner demonstrates SDLC capabilities (gray/canary release, PR lanes, resilience, zero-trust, ...) live in an interview, by following a written runbook — later rendered as a web page. Every capability must be backed by evidence (logs, Jaeger traces, metrics, admission/audit records) proving it is real platform behaviour, not demo code.

Ground rules agreed on 2026-09-25:

- **Realistic, not pretty.** The lab simulates a production environment. Anything a real production system would have (mesh, resilience policies, authz, several replicas, sealed secrets) is resident. Only things real production would not have (e.g. header-triggered fault injection) are added temporarily during a demo.
- **Evidence from the infrastructure layer.** Each scenario needs at least two independent pieces of evidence, at least one from Envoy / ArgoCD / Kyverno rather than the app's own logs.
- **The demo runs in `lab-environment`** (PetClinic microservices on vps-oracle2), not the `pr-lanes` hello app.
- The RCA agent's eval baseline is re-established on the new environment; comparability with the 2026-07-31 runs is knowingly given up.

## Sub-projects

| # | Sub-project | Scope | Depends on | Status |
|---|---|---|---|---|
| 1 | Production baseline | Istio ambient + waypoint + ingress gateway; customers ×5 / api-gateway ×3 with rolling updates; K8s-native discovery (Consul = config center only); DB password in SealedSecret (rotated); idempotent `db-init` PreSync Job; STRICT mTLS + least-privilege authz; resident timeouts/retries/outlier detection; evidence chain (OTel traces across app + Envoy, JSON access logs with trace_id, Loki↔Jaeger links, "Lab Mesh Overview" dashboard, traffic generator) | — | **Done 2026-09-26** — all 7 acceptance criteria pass; results and the new RCA symptoms are in the spec's "Implementation results". [Spec](2026-09-25-lab-mesh-production-baseline-design.md), [plan](../plans/2026-09-25-lab-mesh-production-baseline.md) |
| 2a | Runbook framework + runbook-only scenarios + capacity alerts | `docs/demo/` structure and helpers (`demo-window` / `demo-evidence` / `demo-reset`); scenarios whose mechanism 1 already built, plus a k6 load-test capacity baseline; shared cluster-wide kube-state-metrics; lab capacity alerts | 1 (acceptance results) | **Done 2026-09-27** — [spec](2026-09-27-lab-demo-runbook-framework-design.md) (implementation results at the end), [plan](../plans/2026-09-27-lab-demo-runbook-framework.md), runbook [`docs/demo/`](../../demo/README.md) |
| 2b | Routing scenarios | Canary by weight and by instance ratio, blue-green, header-based gray release / A/B, traffic mirroring — each needs a new Deployment or routing rules | 2a; CPU-requests ceiling lifted 2026-09-28 (see below) — memory is the next one, size it in 2b's spec | **Done 2026-09-28** — all 5 acceptance criteria pass; [spec](2026-09-28-lab-routing-scenarios-design.md) (implementation results at the end), [plan](../plans/2026-09-28-lab-routing-scenarios.md), runbook pages [09](../../demo/09-canary-instance-ratio.md)–[13](../../demo/13-mirror.md). Memory resolved by decommissioning dify and a 9.25Gi quota |
| 2c | Resilience scenarios | One-misbehaving-pod outlier ejection, header-triggered fault injection, rate limiting on the lab waypoint, Toxiproxy in front of postgres/redis, overload protection under load (extends 2a's k6 script — its measured knee is ~30 req/s, bottleneck vets-service's 5-connection pool); ledger items C and D; 2a's open finding: `UF,URX` from the waypoint to new, Ready pods during concurrent rollouts | 2a | **Done 2026-09-29** — all 7 acceptance criteria pass; [spec](2026-09-28-lab-resilience-scenarios-design.md) (implementation results at the end), [plan](../plans/2026-09-28-lab-resilience-scenarios.md), runbook pages [14](../../demo/14-bad-pod.md)–[17](../../demo/17-toxiproxy.md) and a rewritten [08](../../demo/08-load-test.md). Ledger C measured (3 attempts, no compounding), ledger D closed (332Mi of 512Mi), 2a's `UF,URX` and 2b's two resilience findings closed as accepted with measured windows |
| 3 | PR lanes for the lab | Fork CI → GHCR → Cosign; ApplicationSet lanes; lane header propagation; Kyverno signature verification for lab images | 1; ideally 2 so lanes get a runbook scenario | **Done 2026-09-29** — all 7 acceptance criteria pass; [spec](2026-09-29-lab-pr-lanes-design.md) (implementation results at the end), [plan](../plans/2026-09-29-lab-pr-lanes.md), runbook page [18](../../demo/18-pr-lane.md). Trivy gate on (fork on Spring Boot 4.0.8) |
| 4 | Automated progressive delivery (optional) | Argo Rollouts with Istio traffic routing: stepped weights + Prometheus analysis + automatic rollback — on a service other than `customers-service`, so the manual (2b) and automated versions can be demoed side by side | 1, 2 | Proposed, not agreed; placement decided 2026-09-29 (see notes below) |
| — | Runbook as a web page | Render `docs/demo/` as a page to present from | 2a (grows with 2b/2c) | **Built 2026-09-29, not yet live** — [spec](2026-09-29-lab-demo-runbook-site-design.md) (implementation results at the end), [plan](../plans/2026-09-29-lab-demo-runbook-site.md), `demo-site/` + `.github/workflows/demo-runbook.yml`; CI build green. Blocked on one manual step: enable Pages (Settings → Pages → Source: GitHub Actions — the CLI token lacks the permission), then run the workflow once (`gh workflow run demo-runbook.yml`) |
| — | Production monitoring consumes kube-state-metrics | An `npm-nodeport-relay` instance for the NodePort 2a reserves (the compose Prometheus is a Docker-bridge container), a scrape job in the vps_oracle Prometheus, a k3s container dashboard, production alert rules | 2a (KSM deployed) | **Done 2026-09-29** — `nodeport-relay@30115`, compose Prometheus job `kube_state_metrics` (metric keep list, ~860 series of ~6.4k), "k3s Workloads" dashboard (object state and requests headroom only — no usage, which would need cAdvisor) and alert group `k3s_workloads` (KSM down, container not starting, Pending, missing replicas; excludes `lab-environment` and PR lanes; OOM/eviction/NotReady stay with the inspector). Filters verified with a promtool rule test on synthetic series |
| — | 2a polish | The final review's 11 deferred minors, grouped by when to do them: group A before the next real demo (07's Ctrl-C, sync-wait timeouts, the 06 interruption note); group B with 2c; group C when next touching the file. See [2a spec → Deferred minors](2026-09-27-lab-demo-runbook-framework-design.md#deferred-minors-from-the-final-review) | 2a | **Done 2026-09-29.** Group B with 2c (KSM Down alert, Quota summary wording, 08's cAdvisor piece and midnight-safe minute table); groups A and C together afterwards — every runbook wait loop now has a deadline (also the route waits in 11 and 15, found on the way) and a test enforces it, 07 polls instead of `-w`, 03/04/`demo-window` fixes with stub tests, stub tests for 01/03/04/05/06's evidence, scenario scripts shellcheck-clean at warning level |
| — | Least-privilege cAdvisor scrape | The lab Prometheus reads cAdvisor through the API server's node proxy, so its ClusterRole holds `nodes/proxy get` — a verb kubelet also accepts for websocket `exec`. Move to scraping each kubelet's `:10250/metrics/cadvisor` directly with only `nodes/metrics get`; needs the lab pods → node `:10250` path opened first (probed 2026-09-27: connection reset) | 2a | **Done 2026-09-29** — the reset was oracle2's OCI default-REJECT (`INPUT` allowed only 22). oracle2 now runs a versioned `vps_oracle2/host-native/host-firewall/` like vps_oracle (netfilter-persistent disabled) with pod CIDR → `10250`; the job scrapes only the `dedicated=lab` node's kubelet directly, and the ClusterRole holds `nodes/metrics` instead of `nodes/proxy` |
| — | Elastic scaling demo (HPA) | Load-driven scale-out of the business services | CPU requests no longer block it (2026-09-28); the 9.25Gi memory quota's headroom is reserved for 2b's 5-replica blue-green green (1920Mi), so HPA needs its own sizing, and 08 says the first lever is vets' DB pool, not CPU | Not started |

### Sub-project 2 — notes for its spec

Split on 2026-09-27 into **2a / 2b / 2c** (table above). The notes below were written for the undivided sub-project and still apply to all three; 2a's spec records which parts it takes. The scenario catalogue's "New in sub-project 2" column maps to 2b (canary, blue-green, header routing, mirroring) and 2c (bad pod, fault injection, rate limiting, Toxiproxy); every "runbook only" row is 2a.

- **Load testing** (added 2026-09-27): 2a covers the capacity baseline and bottleneck attribution (k6 from vps_oracle, never from oracle2). Overload protection — rate limiting and outlier ejection shielding `/api/vet/vets` under load — belongs to 2c and extends the same k6 script. Elastic scaling (HPA) is blocked on capacity (row above).

- **Sub-project 1 finished 2026-09-26; the lab is live and this can start.** Start from the sub-project 1 spec's "Implementation results" — the seven acceptance results, the measured RCA symptoms, and **four traps that change how scenarios must be written**: (1) the 1 s `perTryTimeout` truncates every timeout-shaped symptom, so injected delay size is invisible in latency; (2) nothing is retried (502/504/UT are all outside `retryOn`); (3) the same downstream slowness yields 200 on one path and 504 on another depending on where the timeout sits; (4) the hop that *reports* a timeout is not always the faulty one.
- **Execution ledger** (rulings, findings, and the things deliberately left undone) lives at `.superpowers/sdd/2026-09-25-lab-mesh-production-baseline/progress.md` in the main checkout. It is gitignored, so it exists only on this machine — it is the detailed process record behind the spec's summary, and worth reading before re-deriving anything. Its `Item B`/`Item C`/`Item D` entries are open threads: **C** (retries compound across the two internal hops — up to 9 attempts at the deepest service; latent until a dependency returns 503) and **D** (`vets-service`/`api-gateway` lack the `MALLOC_ARENA_MAX` and 768Mi limit the other two carry; measured tightest of the four at 322Mi/512Mi and 289Mi/512Mi).
- **`docs/demo/` does not exist yet** — creating it is this sub-project's deliverable, not a leftover from sub-project 1.
- Scenario runs must record **their own start/end timestamps**. The first attempt to attribute a window of failures read a 6-minute aggregate of the generator's log and blamed the wrong scenario entirely; per-scenario Loki time windows are what settled it.
- Runbook location: `docs/demo/`. Every scenario uses the same fixed structure so it can be rendered as a web page: **purpose → preconditions → commands → expected result → evidence (query / screenshot) → talking points → reset**.
- Order matters when demoing: outlier ejection lasts 30 s and a rate-limit window 60 s — routing scenarios first, then resilience, then authz, rate limiting last.
- Add lab capacity alerts in the lab Grafana: pods stuck `Pending` (quota or node requests exhausted), high CPU throttling, container restarts / OOMKills. Sub-project 1 sizes the quota to **requests only, 2 CPU / 8Gi** — derived from the release peak (steady state + surge + the PreSync hook), not chosen loosely; limits stay uncapped and overcommit is accepted, so these alerts are how a capacity problem surfaces.
  - Two concrete limits sub-project 2 must design around, both measured: the quota deadlocked a release on 2026-09-25 because it could not admit a simultaneous rollout plus the hook (fixed by the 8Gi derivation), and **CPU requests — not the quota — are the next ceiling**: a release peak reaches ~1825m of the node's 2000m, so a blue-green demo whose green Deployment is 3×50m lands at 1975m and anything further goes `Pending`. Levers are the 50m JVM CPU requests (the whole node actually uses ~374m) or a bigger instance. **Lifted 2026-09-28** without a bigger instance: CPU requests lowered to measured steady-state usage (JVMs 20m, Envoys 50m, infra 10-20m; limits and memory requests unchanged), lab quota `requests.cpu` 2 → 1200m (peak 770m), vps-oracle2 kubelet `system-reserved`/`kube-reserved` so allocatable (1700m / ~9.4Gi) excludes the docker stacks there; node CPU requests 1525m → 800m. Principle, from the user: the node is a trial ground — overcommit, slow starts and latency spikes are accepted; `Pending`, `FailedCreate` and quota deadlocks are not. **Memory resolved in 2b (2026-09-28):** dify decommissioned, oracle2's reservations re-measured (system-reserved 1280Mi, kube-reserved 384Mi → allocatable 10263Mi), lab quota 9.25Gi — sized for a 5-replica green plus a full release (peak 9232Mi). After the resize, 08 was re-run once (2026-09-28): 0.02 % failed (was 0.85 %), knee still ~30 req/s, waypoint ≤ 80m and ingress ≤ 36m unthrottled at ~68 req/s — but it started ~1 min after all ten JVMs had cold-started, so its 1.63-core node peak (was 1.29) includes JIT warm-up and is not a clean baseline; 08's page keeps the 2a numbers. Re-run on warm JVMs if a clean post-resize baseline is needed (fires the `Lab API Down` Telegram alert).
  - Also still asymmetric and unexamined: `vets-service` and `api-gateway` lack the `MALLOC_ARENA_MAX: "2"` and 768Mi limit that `customers-service` and `visits-service` carry. Measured 2026-09-26 they are the tightest of the four (322Mi/512Mi and 289Mi/512Mi, ~190–223Mi headroom) yet have the *lowest* RSS, so the arena cap is not demonstrably what fixed the earlier OOMs. Not changed — a vets OOMKill would fire the `Lab API Down` probe, which is exactly what these alerts should catch.
- Keep a backup of every scenario in case the live cluster misbehaves during an interview. Decided 2026-09-27 (2a): the backup is the rehearsal's saved evidence output — no screenshots or terminal recordings.
- Talking points should include the pitfalls actually hit (e.g. from `docs/incidents/` and the pr-lanes phase I–L docs: fault-injection delay not truncated by timeout, abort being a local reply that never trips outlier detection, RBAC-before-Lua filter order), not only the happy path.

Scenario catalogue (mechanism built in sub-project 1 unless marked):

| Scenario | Mechanism | New in sub-project 2 |
|---|---|---|
| Load balancing across 5 instances | waypoint Envoy | runbook only |
| Zero-downtime rolling update | RollingUpdate + PDB + readiness | runbook only |
| Schema migration as PreSync hook | `db-init` Job | runbook only |
| mTLS / identity-based authz / actuator lockdown | PeerAuthentication + AuthorizationPolicy | runbook only |
| Timeout, retry, outlier ejection of one bad instance | VirtualService + DestinationRule | a way to make exactly one pod misbehave |
| Canary by weight; canary by instance ratio | VirtualService weights; extra Deployment | canary Deployment + VS/DR subsets |
| Blue-green switch | VirtualService 100/0 → 0/100 | green Deployment |
| Header-based gray release / A/B | VirtualService header/cookie match | routing rules |
| Traffic mirroring | VirtualService `mirror` | mirror target |
| Rate limiting | TrafficExtension + Lua (proven in pr-lanes phase L) | policy for the lab waypoint |
| Fault injection | VirtualService `fault`, header-triggered, temporary | demo-only rules |
| Chaos at app / dependency level | Consul `chaos/` toggles; Toxiproxy | wire Toxiproxy in front of postgres/redis if used |
| App-level vs mesh-level resilience | gateway Resilience4j circuit breaker + fallback vs Envoy | runbook only |
| Secret rotation | SealedSecret + `ALTER USER` | runbook only |
| GitOps self-heal and rollback | ArgoCD `selfHeal` / `git revert` of a SHA tag | runbook only |

### Sub-project 3 — notes for its spec

- Lab images are built locally today (`ops-lab/*`, imported into vps-oracle2's containerd). Lanes need CI in the fork repo pushing to GHCR, then the same build → Trivy → Cosign shape as `.github/workflows/hello-backend.yml`.
- Build arm64 on GitHub's native arm64 runners: QEMU emulation crashes in the Spring Boot layertools extract step (recorded in `lab-environment/scripts/build.sh`).
- Lanes span several hops (gateway → customers → visits): the lane header must be propagated by the apps — Micrometer baggage (`management.tracing.baggage.remote-fields`) is the candidate.
- Once lab images are in GHCR and signed, extend Kyverno's `restrict-image-registry` / `require-vuln-scan-clean` to lab workloads.
- Reuse the pr-lanes ApplicationSet pattern (`k3s/argocd/apps/pr-lanes-appset.yaml`) and its known pitfalls (plain-string `kustomize.images`, PR head SHA not merge SHA, VirtualService vs HTTPRoute on the same host).

### Sub-project 4 — notes

Only proposed. Argo Rollouts is the lightweight choice (native Istio VirtualService traffic routing, Prometheus analysis templates).

**Decided 2026-09-29: Rollouts goes on a different service than `customers-service`, and it complements 2b's manual releases rather than replacing them.** The demo must be able to show both the manual and the automated version and compare them side by side ("this is each step by hand; this is the same mechanism automated, with analysis and rollback").

Why not `customers-service`:

- All of 2b's scenarios (pages 09–13) are built on it: the separate `customers-service-canary` Deployment, the stable/canary subsets, and weights / header rules / mirror edited by hand in git.
- A Rollout on it would take over that VirtualService's weights and rewrite them on every release, fighting any weight committed by hand; its own canary ReplicaSet would make `customers-service-canary` redundant. Pages 09–13 would have to be rewritten and the manual version would be gone.
- Rollouts' own manual mode (`pause: {}` + `kubectl argo rollouts promote`) is still Rollouts' mechanism, not 2b's "edit the VirtualService in git" — it does not stand in for the manual demo.

For its spec (not yet verified):

- Hard requirement: `customers-service` and pages 09–13 stay unchanged.
- Candidate service: `vets-service` already carries 16's rate limit and 08's load-test bottleneck, so a release on top would muddle evidence attribution; `visits-service` is touched by 17's Toxiproxy, but only temporarily. Settle it in the spec.
- The chosen service needs its own VirtualService/DestinationRule for Rollouts to manage, `routing_baseline` (and so `demo-reset`) extended to check it, and ArgoCD `ignoreDifferences` for the weights Rollouts writes at runtime — otherwise selfHeal treats them as drift and reverts them.
- The Rollouts controller needs room in oracle2's CPU/memory budget and the lab quota.

## Out of scope of every sub-project

- **RCA eval re-baseline**: updating `lab-environment/scenarios/scenarios.yaml` symptoms and re-running `run-eval.sh` belongs to the lab-environment repo; sub-project 1 only records the observed new symptoms.
- **Accepted known gaps** (see the sub-project 1 spec): single node, single-instance data stores, Redis without AUTH, ops UIs PERMISSIVE via NodePort, schema managed by idempotent SQL rather than versioned migrations.
