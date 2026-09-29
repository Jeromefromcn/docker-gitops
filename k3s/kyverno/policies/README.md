# Kyverno Policies

`ClusterPolicy` manifests for phase E's admission control:

- `restrict-image-registry.yaml` — Cosign keyless signature verification,
  scoped to `ghcr.io/jeromefromcn/*` only. Accepts this repo's workflows on
  `main` and the lab fork's `lab-images.yml` on `main` / `lab-v2`.
- `restrict-image-registry-lab-lanes.yaml` — the same check for lab PR lane
  pods (`lab-environment`, label `lab.jerome/lane`), which also accepts the
  fork's `refs/pull/<N>/merge` builds and tag references
  (`verifyDigest: false`).
- `lab-business-images-from-ghcr.yaml` — validate: the lab's four business
  services and their `-lane` pods must run `ghcr.io/jeromefromcn/*` images.
  `verifyImages` never looks at a non-matching reference, so without this a
  local `ops-lab/*` build would be admitted unverified.
- `require-vuln-scan-clean.yaml` — Trivy CVE gate via Trivy Operator's
  `VulnerabilityReport` CRDs, narrowed 2026-08-18 to self-built images only
  (same `app in (...)` scope as `restricted-self-built.yaml` below), plus
  the lab's four business services since 2026-09-29 (their images moved to
  Spring Boot 4.0.8 and CI gates on the same CVEs).
- `restricted-self-built.yaml` — Kubernetes `restricted` Pod Security
  profile, scoped to the `placeholder-hello` Deployment by pod label
  (`vikunja-notify-relay` dropped 2026-08-18 — migrated back to compose,
  no longer runs on k3s).

- `lab-environment-on-oracle2.yaml` — **mutate**, not validate: injects
  `nodeSelector: dedicated=lab` plus the matching toleration into every
  `lab-environment` Pod, pinning the lab to the tainted vps-oracle2 agent
  node. Mutates Pods rather than Deployments so ArgoCD never sees drift.

The phase E validate policies are `validationFailureAction: Enforce` (flipped from `Audit` on
2026-08-18 — see `k3s/README.md`'s Kyverno section for the
cutover details). `lab-business-images-from-ghcr` has been `Enforce` since the lab's
baseline moved to GHCR (2026-09-29).
