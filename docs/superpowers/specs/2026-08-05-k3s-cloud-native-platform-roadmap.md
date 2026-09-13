# K3s Cloud-Native Lab Platform — Roadmap

Date: 2026-08-05

## Background

`vps_oracle` currently manages roughly ten independent stacks with docker compose (see [container-topology.md](../../container-topology/v1.md)). The goal is to replicate, on the same machine (4C/24G, Oracle Cloud VPS), a complete cloud-native software development & operations lab platform using K3s, covering the industry-standard component stack — CNI, service mesh, GitOps CI/CD, supply chain security, multi-environment PR lanes — for technical parity with SRE roles and learning.

This is a multi-month project spanning several independent subsystems, split into multiple phases, each going through the full spec → plan → implement → validate cycle on its own. This document is the cross-phase overview roadmap, not the detailed design for any single phase — the detailed design docs for each phase will link back here.

## Goals

- **Infrastructure must be robust**, not a toy-level PoC
- **Concepts/features align with industry standards** (CNI, mesh, GitOps, supply chain security all covered), but **components may be the resource-saving variants** (e.g. a lightweight Ingress controller, single-replica control plane) to fit the 4C/24G resource budget
- **Smooth migration**: existing services' external domains and ports stay unchanged
- Whether each compose environment survives is **decided per service**, not all must migrate

## Current-State Constraints

From [container-topology.md](../../container-topology/v1.md) and a live `free -h` measurement (2026-08-05):

- Memory: 23Gi total, 11Gi used, ~6.4Gi available; CPU 4 cores. Existing load (llm, dify, etc.) already consumes a fair share of headroom
- `npm` (Nginx Proxy Manager) is the only container publishing host 80/443; the rest are reverse-proxied via the `proxy` network + Docker DNS and do not publish ports directly
- `3x-ui` is the exception: 39876 (VLESS+Reality) is raw TCP, clients connect directly and cannot go through an HTTP reverse proxy — this port must not break during migration. This service has had a real outage (see [2026-07-24-3x-ui-vless-unreachable.md](../../incidents/2026-07-24-3x-ui-vless-unreachable.md)): shallow health checks (only testing the port) cannot detect internal xray-core anomalies, and the default `ulimit -n 1024` can be exhausted under long-connection scenarios. When migrating to k8s, probe design must continue to "check process liveness" rather than only test the port, and host-level config like `ulimits.nofile` needs its k8s counterpart (e.g. `securityContext` or initContainer)
- Two projects not managed by this repo also run on the same machine (`lab-environment`, `programming-learning-platform`), directly occupying host ports 8080/9090/3001/3100, colliding with common default ports in the k8s ecosystem (Grafana, Prometheus, etc.). **On conflict, the k8s side wins**: k8s components keep their conventional default ports, and these two non-k8s-managed containers yield their ports instead (change the host ports published in their compose/config), rather than the reverse where k8s components accommodate them

## Phase Roadmap

| Phase | Goal | Deliverable | Depends on |
|---|---|---|---|
| A. Cluster foundation | K3s + containerd + Cilium (CNI/NetworkPolicy) + storage + resource budget (ResourceQuota/LimitRange) | An empty but reachable cluster that NPM can route into | — |
| B. GitOps bootstrap | ArgoCD (app-of-apps) + GitHub Actions CI skeleton (build→Trivy→Cosign) | From here on all deployments go through GitOps, no manual `kubectl apply` | A |
| C. Migration template + first batch | Pick 2 low-risk services to work out the compose→k8s template, verify zero change in domain/port: homepage (config-type, stateless) + trilium (with real data, also validating PVC and data migration) | A replicable migration SOP | A, B |
| D. Remaining service migration | Database-type services (vikunja+pg, the dify family), the llm inference stack, 3x-ui's 39876 TCP passthrough | Per-service migration + compose keep/retire decision | C |
| D+. Read-only cluster panel | Install Headlamp (view-only RBAC), running in parallel and complementary with compose-side portainer — portainer manages docker, Headlamp manages k8s | Headlamp reverse-proxied via NPM (dedicated subdomain + `self-only` ACL, mirroring ArgoCD), added to homepage card (Infra Services category, mirroring ArgoCD's current state); resource requests 50m/64Mi, limits 200m/256Mi | D |
| E. Supply chain security hardening | Trivy admission gate, Cosign signature verification, Sealed Secrets, Kyverno | Images/deployments gated by policy | B, D services live |
| F+G. Service-mesh-driven PR lanes | Istio Ambient (istiod + ztunnel + istio-cni + waypoint) + ArgoCD ApplicationSet PR Generator; PR lanes do not do full namespace replication, instead use a shared base environment + waypoint doing L7 routing by header. `placeholder-hello` is refactored into two tiers (`hello-frontend` → `hello-backend`) and moved into a dedicated `pr-lanes` namespace — without a second hop there is no east-west routing to intercept, so this tier split is the precondition for the mechanism to work | PR branches automatically spin up isolated routing lanes (only replicating the single service that was changed, not an independent namespace copy); the same waypoint mechanism is reserved for future canary releases | B, E (needs Kyverno signature policy adjustment) |
| H. Compose decommission evaluation | Decide per service whether keep compose | Final environment convergence decision | D |

## D+ Selection Notes

- **Why Headlamp rather than Kubernetes Dashboard/Rancher/Lens/K9s**: a resident web panel is the only form that matches the "installed interface" semantics — K9s and Lens are local client tools that connect via kubeconfig and are not installed into the cluster; Rancher is a multi-cluster management platform, and the extra etcd/controller overhead is too risky on a 4C/24G budget already half-consumed; official Kubernetes Dashboard is a four-component combo of kong gateway + api + web + metrics-scraper, on the order of the ArgoCD install, whereas Headlamp is a single Deployment, single container (Go backend bundled with React frontend) with far lower resource overhead (common community config: requests 100m CPU/128Mi, limits 500m CPU/256Mi; the official chart sets no limits by default)
- **Permission scope**: read-only visualization first, logging in with a ServiceAccount token bound to only the `view` ClusterRole — writes are blocked by RBAC at the API layer, not merely hidden UI buttons, upholding the roadmap principle of "changes go through GitOps, not the panel"
- **Relationship to portainer**: parallel and complementary, not a replacement — portainer only sees the host's docker containers via the docker socket (including the two projects not managed by this repo); k3s uses containerd, so portainer cannot see pods. Headlamp covers the k8s side that portainer cannot see; the two manage different execution environments
- **External exposure**: mirror ArgoCD's already-validated pattern (NodePort → NPM → dedicated subdomain, `self-only` access list, TLS terminated at NPM), not a new pattern
- **homepage card**: originally planned to be excluded like 3x-ui (cluster-visibility capability classified as security-sensitive), but ArgoCD has actually been put on a card, so that precedent no longer holds; Headlamp follows the current state and gets a card too (Infra Services category)

## Migration Principles (throughout)

1. External domains/ports stay unchanged; NPM remains the outer entry point, and its own migration is deliberately not scheduled into any of phases A~F+G, deferred to phase H for evaluation:
   - NPM is the anchor of the "domain/port unchanged" promise — in A~D each migrated service is "first run it inside k3s, then change the NPM forward rule", so NPM itself must stay put for users to feel nothing; if NPM itself were also changing during migration, it would be moving the anchor and the anchored things at the same time, compounding risk
   - Who takes over host 80/443 is a precondition, dependent on the ingress controller selection that is not yet settled in phase A — order-wise it cannot be decided in advance
   - NPM's "migration" may in substance be "replace NPM with k8s-native ingress + cert-manager" rather than containerizing and moving NPM in; this characterization only has a basis after all of phase D services are migrated and stable
2. Each phase completes its full spec → plan → implement → validate before the next phase's detailed design starts
3. Before migrating each service, verify it works inside the cluster first, then cut traffic; keep the old compose containers until stability is confirmed, then retire them

## Why F+G Were Merged

The original plan had F (ArgoCD ApplicationSet PR Generator + lane quota isolation, namespace-per-PR full replication) and G (Istio Ambient service mesh + progressive delivery) as two separate phases with a known tension between them: the namespace-per-PR isolation model fights the waypoint model that concentrates in a single shared namespace; the original document deferred this trade-off to phase G.

After redesigning, the two phases were merged, because PR lanes switched to "shared base environment + waypoint doing L7 routing by header" (one of the industry's standard approaches for "independent services without a deep dependency graph" — only replicating the single changed service, sharing the rest), rather than full namespace replication — and this approach itself requires Istio Ambient's waypoint to work at all. This means phase F's deliverable directly depends on phase G's core component, so splitting them into two sequential phases is pointless, and the tension disappears (no namespace-per-PR, so no conflict with the waypoint concentration model).

The cost: the merged F+G raises the resource threshold substantially (istiod + ztunnel + istio-cni + waypoint combined, even at minimum sizing, approaches the overhead of the original dify install), and pulls in the service mesh — a heavyweight component originally planned only after the D main services stabilized — ahead of schedule; the scope is narrowed to only `placeholder-hello`, excluding canary releases (canary/progressive delivery stays behind the same waypoint mechanism, expanded later as needed, not part of this deliverable).

## Design Trade-offs Deferred to Phase H

- Host 80/443 can only be bound by one process at a time: currently npm holds them; if a k3s ingress (k3s's default Traefik + built-in lightweight LoadBalancer "Klipper LB") goes in front, that's replacing one process holding the same ports with another, and npm must yield — either retire outright, or rebind to other ports (e.g. 8080/8443) kept only for edge cases not yet migrated to ingress rules. The two cannot both hold 80/443 at once; the cutover must be designed as an interruption-free switch, not a naive "both running at the same time"
- ingress can do npm's core functions, but via different mechanisms, not a graphical point-and-click UI:
  - HTTPS: via `cert-manager` (k8s-native ACME client) automatically requesting/renewing Let's Encrypt certificates and binding them to ingress resources. Functionally equivalent, and avoids npm's known "SSL toggle resets itself" bug (see the README's "connecting services to NPM reverse proxy" section), but requires separately learning the Issuer/Certificate CRDs and HTTP-01 vs DNS-01 challenge concepts
  - Access List (IP allowlist / Basic Auth): via ingress controller annotations or Middleware CRDs, e.g. Traefik's `IPAllowList`/`BasicAuth` Middleware, or nginx-ingress's `nginx.ingress.kubernetes.io/whitelist-source-range` annotations. Functionally equivalent, but configured as YAML, not form toggles
- Every one of npm's existing proxy hosts (SSL settings, access list rules, etc.) needs to be **manually translated item by item** into ingress annotations/CRDs at phase H, not a one-click migration — this is the main source of phase H's actual workload

## Phase Design Docs

(links filled in as phases progress)

- A: [Cluster Foundation Design](2026-08-05-k3s-phase-a-cluster-foundation-design.md)
- B: [GitOps Bootstrap Design](2026-08-07-k3s-phase-b-gitops-design.md)
- C: [Migration Template + First Batch Design](2026-08-09-k3s-phase-c-migration-template-design.md)
- D: [Remaining Service Migration Design](2026-08-12-k3s-phase-d-remaining-migrations-design.md)
- D+: to be created
- E: [Supply Chain Security Design](2026-08-15-k3s-phase-e-supply-chain-security-design.md)
- F+G: [Service-Mesh-Driven PR Lanes Design](2026-08-18-k3s-phase-fg-mesh-pr-lanes-design.md)
- H: to be created

---

## Postscript: the 2026-08-18 direction reversal (added 2026-08-21)

**Everything above is kept as-is; it records the plan as of the 2026-08-05 project kickoff. The actual trajectory diverges from this roadmap starting 2026-08-18 — read this section before reading the rest of this document.**

- **Services that phases C and D migrated into k3s have all been migrated back to compose** (2026-08-18, a user-led evaluation decision, not a technical failure): `homepage`, `trilium`, `dify`, `vikunja` (including `vikunja-notify-relay`), `apprise`, `llm` (`llama-cpp`+`open-webui`). On the same day `evidence-os-website` (k8s-native, no compose predecessor) was also moved into compose. See [Migration Plan One](../plans/2026-08-18-k3s-to-compose-migration.md) and [Migration Plan Two](../plans/2026-08-18-k3s-to-compose-migration-part2.md).
- **Therefore the C/D deliverables in the "Phase Roadmap" table no longer represent the current state**; the 39876 passthrough migration for `3x-ui` was also never carried out. The table's "per-service compose keep/retire decision" principle turns out to have been carried through to its logical end — the decision was to keep everything in compose.
- **The precondition for phase H (compose decommission evaluation) has disappeared**: since the services are all back in compose, "compose decommission" is no longer a topic; the entire "Design Trade-offs Deferred to Phase H" section (NPM yielding 80/443, translating proxy hosts item by item into ingress) becomes indefinitely shelved, not an open to-do.
- **k3s's remaining live load is only three things, none migrated from compose**: `lab-environment` (independent project, still in k3s), `headlamp`, `pr-lanes` (phase F+G's `hello-frontend`/`hello-backend`), plus the infrastructure itself (Cilium, ArgoCD, Istio Ambient, Kyverno, Trivy Operator, Sealed Secrets).
- **The outcomes of A, B, E, F+G are all kept and still running**; only the "move existing compose services into k8s" line was reversed. k3s's positioning now is the cloud-native lab platform itself, not compose's successor.
- The current state is governed by the "k3s" section of the root [README.md](../../../README.md) and [`vps_oracle/k3s/README.md`](../../../vps_oracle/k3s/README.md); for the current topology snapshot see [container-topology/v3.md](../../container-topology/v3.md).