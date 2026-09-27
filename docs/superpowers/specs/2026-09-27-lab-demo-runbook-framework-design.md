# Lab Demo Runbook — Framework, Runbook-Only Scenarios, Capacity Alerts (Sub-project 2a)

Date: 2026-09-27

Sub-project 2a of the [lab SDLC demo roadmap](2026-09-25-lab-sdlc-demo-roadmap.md). The roadmap's sub-project 2 was split into three on 2026-09-27 because its scenario catalogue mixes scenarios that only need a runbook with scenarios that need new platform mechanisms:

- **2a (this spec)** — the runbook framework, every scenario whose mechanism sub-project 1 already built, a load-test scenario, and lab capacity alerts.
- **2b** — routing mechanisms: canary (weight and instance ratio), blue-green, header-based gray release, traffic mirroring.
- **2c** — resilience mechanisms: one-misbehaving-pod outlier ejection, fault injection, rate limiting, Toxiproxy, overload protection under load.

Inputs: the sub-project 1 spec's "Implementation results" (acceptance results, measured RCA symptoms, the four traps) and its execution ledger at `.superpowers/sdd/2026-09-25-lab-mesh-production-baseline/progress.md` (gitignored, this machine only).

## Decisions (agreed 2026-09-27)

| Topic | Decision | Why |
|---|---|---|
| Scope | All 15 catalogue scenarios will be live-demoable, delivered across 2a/2b/2c | One spec for all of them is too large; 2a has no dependency on the CPU-requests ceiling that blocks 2b |
| Command style | Main actions (`kubectl`, `git`, `curl`) are written out verbatim in the runbook and pasted by hand; bookkeeping (time windows, evidence queries, reset + verify) is one helper call each | The interviewer sees real platform commands; the two failures recorded in the ledger (misattributed time window, forgotten chaos reset) are exactly the bookkeeping the helpers take over |
| Git changes during a demo | Commit and push to `main`, with a `demo:` subject prefix. No demo branch, no targetRevision switching | Realistic, not pretty: no demo-only exception to the real GitOps flow. ArgoCD `selfHeal` would revert a bare `kubectl` change anyway |
| Capacity alert delivery | Lab Grafana only, no contact point | Keeps the README's isolation principle (chaos drills stay out of the real alert pipeline); the inspector already pages for Pending / FailedCreate / quota. Adding Telegram later is a contact point + notification policy + a SealedSecret for the bot token — the rules do not change |
| kube-state-metrics | One cluster-wide instance in `kube-system`, pinned to vps_oracle, shared by the production Prometheus (via NodePort) and the lab Prometheus (filtered to `lab-environment`) | KSM is a per-cluster singleton by convention. vps_oracle because oracle2's CPU requests are the 2b bottleneck, and a metrics source should not share a failure domain with the chaos node it reports on |
| Load test | Capacity baseline + bottleneck attribution only, driven by k6 from vps_oracle | Overload protection needs 2c's rate limiting; elastic scaling cannot be shown on a node already near its CPU requests ceiling (both recorded in the roadmap) |

## Design

### 1. Layout

```
docs/demo/
  README.md                       index: demo order, conventions, scenario table
  00-preflight.md                 before any demo: lab healthy, git pull, chaos toggles false, Jaeger window
  01-load-balancing.md
  02-rolling-update.md
  03-schema-migration.md
  04-zero-trust.md
  05-app-vs-mesh-resilience.md
  06-secret-rotation.md
  07-gitops-selfheal-rollback.md
  08-load-test.md
  evidence/                       rehearsal evidence output per scenario (backup if the live cluster misbehaves)
k3s/apps/lab-environment/demo/
  demo-window                     start|stop <scenario> — writes UTC start/end to a state file
  demo-evidence                   runs <scenario>'s evidence queries over its recorded window
  demo-reset                      resets <scenario> and verifies the baseline; non-zero if not recovered
  scenarios/<scenario>.sh         per-scenario evidence and reset functions
  load/k6-steps.js                stepped-load k6 script for scenario 08
  tests/                          helper tests
```

`docs/demo/` is current-state documentation, not history: it must change whenever the lab changes. `.claude/rules/docs-layout.md` gets a line saying so, so the runbook is not mistaken for a point-in-time snapshot like the rest of `docs/`. The helpers live next to the lab's manifests (beside `tests/test-db-init.sh`) because they are tools that operate the lab.

Every scenario file uses the same fixed structure so it can later be rendered as a web page: **purpose → preconditions → commands → expected result → evidence → talking points → reset**.

### 2. Helpers

- Run from vps_oracle, using its `kubectl` context and the lab NodePorts (Prometheus 30093, Grafana 30094, Jaeger 30095, Consul 30092). Loki has no NodePort; it is queried through Grafana's datasource proxy (`/api/datasources/proxy/uid/loki/...`) rather than by adding a new exposure.
- `demo-window start <s>` / `stop <s>` record UTC timestamps; every evidence query is bounded by that window. This is the roadmap's "each scenario records its own start/end" requirement made mechanical.
- `demo-evidence <s>` prints each piece of evidence labelled with its layer (Envoy / ztunnel / ArgoCD / Kyverno / sealed-secrets / cAdvisor / app). It **exits non-zero unless it found at least two independent pieces with at least one from the infrastructure layer** — the runbook cannot claim evidence that is not actually there.
- Jaeger lookups poll until the span count is stable (the ledger measured ~20 s for a trace to fill in; the first read is routinely partial).
- `demo-reset <s>` performs the reset and verifies it in the same command (ledger line 77: a reset left to "a later step" was forgotten). Baseline = all four Consul `chaos/` keys false, replica counts as in git, generator all-200 over 30 s, ArgoCD `Synced/Healthy`.
- The runbook also lists the key commands each helper runs internally, so they can be explained on request.

### 3. Scenarios

Demo order (dependencies: 07 reverts 02's commit; 06 is the riskiest mutation; 08 deliberately overloads the node, so nothing runs after it):

| # | Scenario | Main action (verbatim in runbook) | Evidence (★ = infrastructure layer) |
|---|---|---|---|
| 01 | Load balancing across 5 instances | 100 requests through the ingress | ★ waypoint access log grouped by `upstream_host`; Prometheus per-pod RPS |
| 02 | Zero-downtime rolling update | bump `lab.jerome/rollout-rev` → `demo:` commit → push → `kubectl rollout status` | ★ ArgoCD sync revision; ★ Envoy non-2xx in window = 0; generator all-200 in window |
| 03 | Schema migration as PreSync hook | no new commit — shows 02's own sync: `db-init` ran before the rollout, row counts unchanged (idempotent) | ★ ArgoCD operation hook-phase order; `db-init` Job log; psql row counts |
| 07 | GitOps self-heal and rollback | ① `kubectl scale customers-service --replicas=1`, watch ArgoCD restore 5 ② `git revert` 02's commit → push | ★ ArgoCD events and revision history; kube events (`ScalingReplicaSet`) |
| 04 | Zero trust: mTLS / identity authz / actuator lockdown | the five acceptance-4 calls (L7 403, actuator 403, plaintext refused, pod-IP reset, postgres reset) | ★ waypoint access log 403 + RBAC denied stats; ★ ztunnel log denials |
| 05 | App-level vs mesh-level resilience | Consul `chaos/visits-service/redis-timeout=true` → call both paths → reset + verify | ★ Envoy `504 UT` (reporting hop ≠ faulty hop); Jaeger trace; Resilience4j circuit-breaker metrics |
| 06 | Secret rotation | new password → `ALTER USER` → kubeseal → commit → push → roll the three services | ★ ArgoCD sync; ★ sealed-secrets controller unseal log; old password rejected over scram; generator error count |
| 08 | Load test: capacity baseline and bottleneck | k6 stepped load from vps_oracle through NodePort 30097 | ★ waypoint P99/RPS per step; ★ cAdvisor node CPU saturation or container throttling; k6 summary, Jaeger slow traces and the `Lab CPU Throttling` state as supporting notes |

Scenario-specific points:

- **03** does not invent a schema change per interview — that would accumulate cruft in the schema. PreSync runs on every sync, so "hook first, idempotent, no data loss" is shown on 02's sync. Talking points: the 2026-09-25 quota deadlock (surge filled the quota, hook refused with `FailedCreate`) and the hook-wave failure (SA/ConfigMap applied after PreSync).
- **05** is where traps 3 and 4 are demonstrated: the same fault gives 200 on `/api/gateway/owners/6` and 504 on `/api/customer/owners/6/visits`, and the 504 is logged against `customers-service:8081` although visits is at fault. Also: the gateway's circuit breaker wraps only the visits call, so a customers outage surfaces as Spring's default 500, not a fallback.
- **06**: the exact order of `ALTER USER` vs Secret update vs rollout, and the resulting error window, are determined during implementation by reading `db-init` and the Hikari pool behaviour and then measuring. The runbook records the measured window, not a guess.
- **08** runs k6 in a throwaway `docker run --rm grafana/k6` on vps_oracle, never on oracle2 (a load generator sharing the 2 cores would invalidate the numbers). Load is stepped with a hard cap. It **will likely fire the production `Lab API Down` alert (Telegram)** — accepted as realistic and stated in the runbook's preconditions. The deliverable is a measured knee (RPS at which P99 departs) and an evidence chain attributing it. CPU is the hypothesis, not a given: with five 1000m-limit JVMs on a 2-core node the node can saturate before any single container is throttled, so the evidence checks node CPU and per-container throttling and fails if neither is saturated — in which case the bottleneck is investigated and the runbook says what it actually is. The `Lab CPU Throttling` alert needs 10 minutes of sustained throttling and a ~6-minute load run will usually leave it pending, so its state is reported, not required.
- Talking points in every scenario include the pitfalls actually hit (sub-project 1 ledger, `docs/incidents/`, pr-lanes phase I–L), not only the happy path. Examples: 02 — the shared Consul instance ID that deleted new pods' registrations; 04 — ztunnel exposes no authz metrics, so L4 denies are shown by effect (curl exit 56 vs 52).

### 4. Shared kube-state-metrics

- New ArgoCD Application `kube-state-metrics` (official Helm chart, same shape as the existing kyverno / sealed-secrets apps), namespace `kube-system`, `nodeSelector` to vps_oracle.
- A NodePort is reserved for the production Prometheus. Wiring the production Prometheus (scrape job, k3s container dashboard, production alert rules) is **out of scope** — a separate follow-up recorded in the roadmap.
- Must pass the existing Kyverno image policies (registry allow-list, vuln-scan gate); verified at implementation.

### 5. Lab Prometheus and Grafana

Prometheus, two new jobs:

- `kube-state-metrics` — `metric_relabel_configs` keeps only `namespace="lab-environment"`.
- `kubelet-cadvisor` — via the API server node proxy; a read-only ClusterRole (`nodes` list/watch, `nodes/proxy` get) bound to the lab's `sa/prometheus`. `metric_relabel_configs` keeps `lab-environment` containers plus each node's root cgroup (`id="/"`), which is what node-level CPU saturation is read from.

The lab README's "no cross-namespace scraping" sentence is rewritten: the isolation that matters is the alert pipeline, and sharing a read-only metrics source does not breach it.

Grafana alert rules (provisioned, no contact point):

| Alert | Condition | Incident it maps to |
|---|---|---|
| Lab Pod Pending | Pending for 3 m (faster than the inspector's 5 m) | 2026-09-25 quota deadlock |
| Lab Quota Near Limit | requests used / hard > 90 % | same |
| Lab CPU Throttling | throttled / periods > 50 % for 10 m (clears JVM startup) | 250m-limit startups taking twice as long |
| Lab Container Restarts | restarts increased within 10 m | — |
| Lab OOMKilled | last terminated reason `OOMKilled` and restarts increased | lab OOMKill incident (133ee45) |

Lab Mesh Overview gets a capacity row: requests used vs quota, throttling ratio per container, restarts.

## Testing

- **Helpers** — behaviour tests against stubbed `kubectl` / `curl` output: `demo-evidence` exits non-zero with fewer than two pieces or no infrastructure-layer piece; `demo-reset` exits non-zero when the baseline is not restored; the window recorded by `demo-window` is the one applied to queries.
- **Alerts** — every rule is fired for real once, with throwaway pods in `lab-environment`: an unsatisfiable request (Pending), a tiny memory limit (OOMKilled + restarts), a CPU spin under a 100m limit (throttling). Confirm firing, delete, confirm resolved.

## Acceptance criteria

1. A full rehearsal of scenarios 01–08 in order; every `demo-evidence` call passes (≥2 pieces, ≥1 infrastructure-layer).
2. After the rehearsal the lab is back at baseline: chaos toggles false, replica counts as in git, generator all-200, ArgoCD `Synced/Healthy`, `main` carries the `demo:` commits and their reverts.
3. All five capacity alerts fired once and resolved on their own.
4. KSM's NodePort answers from the vps_oracle host shell (reachability only, not wired). The production Prometheus runs in a Docker-bridge container, which cannot reach a k3s NodePort without an `npm-nodeport-relay` instance — enabling that instance is part of the production-monitoring follow-up, not 2a.
5. `docs/demo/evidence/` holds the rehearsal's `demo-evidence` output for every scenario.
6. Updated: roadmap status, lab README (isolation wording, KSM dependency), `docs-layout.md` (`docs/demo/` is current state).

## Prerequisites on vps_oracle

`k6` is not installed; it runs from the `grafana/k6` image and needs no install. No terminal or screen recordings are made (decided 2026-09-27): the backup for a misbehaving live cluster is the rehearsal's evidence output.

## Out of scope

- The CPU-requests ceiling (lever for 2b: the 50m JVM requests or a bigger instance).
- Ledger items C (retries compounding across hops) and D (vets/api-gateway memory asymmetry) — 2c territory.
- Every scenario needing a new mechanism (2b, 2c).
- The runbook web page (roadmap's separate row).
- Production monitoring consumption of KSM.
