# Lab demo runbook

Rendered at **https://jeromefromcn.github.io/docker-gitops/** (built from this
directory by [`demo-site/`](https://github.com/Jeromefromcn/docker-gitops/tree/main/demo-site)).

Live demonstrations of SDLC capabilities on `lab-environment` (PetClinic
microservices on vps-oracle2). Each scenario is real platform behaviour,
shown as it happens in the platform's own tools — ArgoCD, Grafana, Loki,
Jaeger, ztunnel's log, Kubernetes — not in the app's own logs alone, and
not in a summary a script collected.

This directory describes **current state**: when the lab changes, the pages
change with it.

## How a page works
Every scenario page has the same shape:

1. **Purpose** and **Preconditions**.
2. **Before you start: open the views.** The exact ArgoCD app, Grafana
   dashboard (with a link that sets its time range and refresh), Loki or
   Prometheus query in Explore, or Jaeger search to have open *before*
   anything happens, and what it shows at rest.
3. **Steps.** Each step is a native action — `git` (edit, commit, push),
   ArgoCD's **Refresh** button, `kubectl`, `curl`, `gh`, a Consul KV
   toggle — followed by where to look and what appears there.
4. **Talking points** and **Reset**.

Rules every page keeps:

- **No helper collects the evidence.** The audience watches the change land
  in the tool that records it. Numbers quoted on a page come from a real
  rehearsal and are dated.
- **Manifest edits are made by hand.** A page names the file, the field and
  the new value (or gives the YAML block to add), then `git diff` shows the
  change before it is committed. There are no prepared patches.
- **Git changes go to `main` for real**, with a `demo:` subject prefix —
  there is no demo branch. ArgoCD's `selfHeal` would revert a bare
  `kubectl` change anyway, which scenario 07 demonstrates. Click
  **Refresh** in ArgoCD after a push; without it ArgoCD finds the commit on
  its next poll, up to ~3 minutes later.
- **Nothing in a pasted block can hang the demo:** every wait loop has a
  `SECONDS` deadline, and pods are watched with `watch -n 2 kubectl …`
  in a second pane, never `kubectl get -w`.
- **No secret on a command line.** Passwords travel through stdin or a
  `/dev/fd` path.

`tests/test-demo-baseline.sh` in `k3s/apps/lab-environment/` checks these
rules on every page (CI job `lab-demo-baseline`).

## The one helper
`k3s/apps/lab-environment/demo/demo-baseline` checks the lab is at its
known-good baseline: no chaos toggle on, replicas as git declares, ArgoCD
synced, generator traffic all 200, no canary, PR lane or toxiproxy wiring
left behind, the rate limiter present. It waits up to 3 minutes for that to
hold. Preflight runs it; run it again between scenarios whenever a page's
reset is in doubt. It is the only script: a scenario that ends off the
baseline would break the next one in front of the audience.

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

Every page was rehearsed live in this form on 2026-10-06.
