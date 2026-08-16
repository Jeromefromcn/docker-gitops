# Kyverno Policies

`ClusterPolicy` manifests for phase E's admission control:

- `restrict-image-registry.yaml` — Cosign keyless signature verification,
  scoped to `ghcr.io/jeromefromcn/*` only.
- `require-vuln-scan-clean.yaml` — Trivy CVE gate via Trivy Operator's
  `VulnerabilityReport` CRDs, scoped to all workloads.
- `restricted-self-built.yaml` — Kubernetes `restricted` Pod Security
  profile, scoped to the `placeholder-hello` and `vikunja-notify-relay`
  Deployments by pod label.

All three start with `validationFailureAction: Audit`.
