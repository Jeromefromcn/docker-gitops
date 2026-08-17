# Kyverno Policies

`ClusterPolicy` manifests for phase E's admission control:

- `restrict-image-registry.yaml` — Cosign keyless signature verification,
  scoped to `ghcr.io/jeromefromcn/*` only.
- `require-vuln-scan-clean.yaml` — Trivy CVE gate via Trivy Operator's
  `VulnerabilityReport` CRDs, narrowed 2026-08-18 to self-built images only
  (same `app in (...)` scope as `restricted-self-built.yaml` below).
- `restricted-self-built.yaml` — Kubernetes `restricted` Pod Security
  profile, scoped to the `placeholder-hello` Deployment by pod label
  (`vikunja-notify-relay` dropped 2026-08-18 — migrated back to compose,
  no longer runs on k3s).

All three are `validationFailureAction: Enforce` (flipped from `Audit` on
2026-08-18 — see `vps_oracle/k3s/README.md`'s Kyverno section for the
cutover details).
