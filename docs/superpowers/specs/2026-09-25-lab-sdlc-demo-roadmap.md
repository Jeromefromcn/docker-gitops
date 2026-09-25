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
| 2 | Demo scenarios + `docs/demo/` runbook | Turn the capabilities into step-by-step demo scenarios (see catalogue below) | 1 (acceptance results) | Ready for spec |
| 3 | PR lanes for the lab | Fork CI → GHCR → Cosign; ApplicationSet lanes; lane header propagation; Kyverno signature verification for lab images | 1; ideally 2 so lanes get a runbook scenario | Not started |
| 4 | Automated progressive delivery (optional) | Argo Rollouts with Istio traffic routing: stepped weights + Prometheus analysis + automatic rollback | 1, 2 | Proposed, not agreed |
| — | Runbook as a web page | Render `docs/demo/` as a page to present from | 2 | Not started |

### Sub-project 2 — notes for its spec

- **Sub-project 1 finished 2026-09-26; the lab is live and this can start.** Start from the sub-project 1 spec's "Implementation results" — the seven acceptance results, the measured RCA symptoms, and **four traps that change how scenarios must be written**: (1) the 1 s `perTryTimeout` truncates every timeout-shaped symptom, so injected delay size is invisible in latency; (2) nothing is retried (502/504/UT are all outside `retryOn`); (3) the same downstream slowness yields 200 on one path and 504 on another depending on where the timeout sits; (4) the hop that *reports* a timeout is not always the faulty one.
- **Execution ledger** (rulings, findings, and the things deliberately left undone) lives at `.superpowers/sdd/2026-09-25-lab-mesh-production-baseline/progress.md` in the main checkout. It is gitignored, so it exists only on this machine — it is the detailed process record behind the spec's summary, and worth reading before re-deriving anything. Its `Item B`/`Item C`/`Item D` entries are open threads: **C** (retries compound across the two internal hops — up to 9 attempts at the deepest service; latent until a dependency returns 503) and **D** (`vets-service`/`api-gateway` lack the `MALLOC_ARENA_MAX` and 768Mi limit the other two carry; measured tightest of the four at 322Mi/512Mi and 289Mi/512Mi).
- **`docs/demo/` does not exist yet** — creating it is this sub-project's deliverable, not a leftover from sub-project 1.
- Scenario runs must record **their own start/end timestamps**. The first attempt to attribute a window of failures read a 6-minute aggregate of the generator's log and blamed the wrong scenario entirely; per-scenario Loki time windows are what settled it.
- Runbook location: `docs/demo/`. Every scenario uses the same fixed structure so it can be rendered as a web page: **purpose → preconditions → commands → expected result → evidence (query / screenshot) → talking points → reset**.
- Order matters when demoing: outlier ejection lasts 30 s and a rate-limit window 60 s — routing scenarios first, then resilience, then authz, rate limiting last.
- Add lab capacity alerts in the lab Grafana: pods stuck `Pending` (quota or node requests exhausted), high CPU throttling, container restarts / OOMKills. Sub-project 1 sizes the quota to **requests only, 2 CPU / 8Gi** — derived from the release peak (steady state + surge + the PreSync hook), not chosen loosely; limits stay uncapped and overcommit is accepted, so these alerts are how a capacity problem surfaces.
  - Two concrete limits sub-project 2 must design around, both measured: the quota deadlocked a release on 2026-09-25 because it could not admit a simultaneous rollout plus the hook (fixed by the 8Gi derivation), and **CPU requests — not the quota — are the next ceiling**: a release peak reaches ~1825m of the node's 2000m, so a blue-green demo whose green Deployment is 3×50m lands at 1975m and anything further goes `Pending`. Levers are the 50m JVM CPU requests (the whole node actually uses ~374m) or a bigger instance.
  - Also still asymmetric and unexamined: `vets-service` and `api-gateway` lack the `MALLOC_ARENA_MAX: "2"` and 768Mi limit that `customers-service` and `visits-service` carry. Measured 2026-09-26 they are the tightest of the four (322Mi/512Mi and 289Mi/512Mi, ~190–223Mi headroom) yet have the *lowest* RSS, so the arena cap is not demonstrably what fixed the earlier OOMs. Not changed — a vets OOMKill would fire the `Lab API Down` probe, which is exactly what these alerts should catch.
- Keep recorded backups (screenshots / terminal recordings) of every scenario in case the live cluster misbehaves during an interview.
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

Only proposed. Argo Rollouts is the lightweight choice (native Istio VirtualService traffic routing, Prometheus analysis templates). It replaces sub-project 2's hand-driven canary with automatic promotion/rollback, so decide after sub-project 2 whether the manual version is enough for the interview story.

## Out of scope of every sub-project

- **RCA eval re-baseline**: updating `lab-environment/scenarios/scenarios.yaml` symptoms and re-running `run-eval.sh` belongs to the lab-environment repo; sub-project 1 only records the observed new symptoms.
- **Accepted known gaps** (see the sub-project 1 spec): single node, single-instance data stores, Redis without AUTH, ops UIs PERMISSIVE via NodePort, schema managed by idempotent SQL rather than versioned migrations.
