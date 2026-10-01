# Lab demo runbook

Rendered at **https://jeromefromcn.github.io/docker-gitops/** (built from this
directory by [`demo-site/`](https://github.com/Jeromefromcn/docker-gitops/tree/main/demo-site)).

Live demonstrations of SDLC capabilities on `lab-environment` (PetClinic
microservices on vps-oracle2). Each scenario is real platform behaviour,
backed by evidence from the infrastructure layer — Envoy, ztunnel, ArgoCD,
sealed-secrets, cAdvisor, Kubernetes — not by the app's own logs alone.

This directory describes **current state**: when the lab changes, the pages
change with it.

## How to run a scenario

Every page has the same sections: purpose → preconditions → commands →
expected result → evidence → talking points → reset. Paste the commands in
order from the repo root on vps_oracle. Main actions (`kubectl`, `git`,
`curl`) are written out in full; the bookkeeping is one helper call each:

| Helper | Does |
|---|---|
| `demo-window start/stop <s>` | Records the scenario's own UTC window — every query is bounded by it. A scenario that counts its own requests (01 so far) first pauses the background traffic generator and waits ~80 s, so the dashboards and the evidence hold only its traffic; `demo-reset` resumes it |
| `demo-evidence <s>` | Runs the scenario's evidence queries; fails unless ≥ 2 pieces pass, ≥ 1 from the infrastructure layer |
| `demo-reset <s>` | Undoes the scenario and verifies the lab baseline in the same command |

Run `demo-evidence` straight after `demo-window stop`: Jaeger keeps only
the last 5000 traces (~1 h at the generator's rate).

Git changes go to `main` for real, with a `demo:` subject prefix — there is
no demo branch. ArgoCD's `selfHeal` would revert a bare `kubectl` change
anyway, which scenario 07 demonstrates.

## Order

| # | Scenario | Why here |
|---|---|---|
| 00 | [Preflight](00-preflight.md) | Before anything |
| 01 | [Load balancing across 5 instances](01-load-balancing.md) | Read-only warm-up |
| 02 | [Zero-downtime rolling update](02-rolling-update.md) | Makes the commit 03 and 07 use |
| 03 | [Schema migration as a PreSync hook](03-schema-migration.md) | Reads 02's sync |
| 07 | [GitOps self-heal and rollback](07-gitops-selfheal-rollback.md) | Reverts 02's commit |
| 09 | [Canary by instance ratio](09-canary-instance-ratio.md) | Routing before resilience; 09-13 each leave the canary slot empty |
| 10 | [Canary by weight: catch a bad build](10-canary-weight.md) | |
| 11 | [Header / cookie gray release](11-header-canary.md) | |
| 13 | [Traffic mirroring](13-mirror.md) | Same bad build as 10, zero user impact |
| 12 | [Blue-green switch](12-blue-green.md) | Five extra JVMs — heaviest routing step |
| 18 | [PR lane: a pull request next to production](18-pr-lane.md) | After 12's reset — lanes use the same headroom as its green |
| 14 | [One bad pod is ejected](14-bad-pod.md) | Resilience after routing; an ejection lasts 30 s |
| 15 | [Header-triggered fault injection](15-fault-injection.md) | |
| 17 | [Network faults through Toxiproxy](17-toxiproxy.md) | Two visits rollouts |
| 04 | [Zero trust: mTLS, identity authz, actuator lockdown](04-zero-trust.md) | |
| 05 | [App-level vs mesh-level resilience](05-app-vs-mesh-resilience.md) | |
| 06 | [Secret rotation](06-secret-rotation.md) | Riskiest mutation |
| 16 | [Rate limiting at the waypoint](16-rate-limit.md) | Rate limiting last; 08 relies on it |
| 08 | [Load test: capacity and overload protection](08-load-test.md) | Overloads the node — always last |

`evidence/` holds the last rehearsal's `demo-evidence` output for every
scenario — the fallback if the live cluster misbehaves mid-interview.
