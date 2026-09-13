# K3s Phase E — Supply Chain Security Hardening Design

Date: 2026-08-15

Corresponds to phase E of the [K3s cloud-native experiment platform roadmap](2026-08-05-k3s-cloud-native-platform-roadmap.md): Trivy admission gate, Cosign signature verification, Sealed Secrets, Kyverno. Deliverable: images/deployments gated by policy.

Precondition: Phase B (GitOps) and Phase D (remaining service migrations) are complete and verified. Cluster current state (measured 2026-08-15): 13 Applications all `Synced`/`Healthy` (argocd, phase-a-foundation, placeholder-hello, homepage, trilium, evidence-os-website, vikunja, apprise, dify, llm, headlamp, lab-environment, root); node 4C/24G, CPU usage 13%, memory actual usage 78% (18.7Gi), requests only 41% (10Gi) — memory headroom by "actual usage" is about 5.3Gi.

Specific to-dos handed off from Phase D (see its "Handoff to phase E" section):
- Sealed Secrets takes over D's out-of-band manual Secrets (`workloads/vikunja`, `dify/dify-secrets`, `llm/open-webui`, `llm/sillytavern`)
- Kyverno/PSS baseline handles the known conflict: trilium has no `runAsUser`

## Scope

**To be done in this phase:**
- Install the Sealed Secrets controller, take over the 4 out-of-band Secrets left by phase D, and establish the convention that all Secrets go into git (encrypted) from now on
- Install Kyverno (admission-controller only), implement three policies:
  1. Cosign imageVerify — verify only self-built images (`ghcr.io/jeromefromcn/*`)
  2. restricted-equivalent security baseline — match only the two self-built Deployments (`placeholder-hello`, `vikunja-notify-relay`)
  3. Trivy CVE gate — all workloads across the whole cluster; block CRITICAL with a fix available
- Install Trivy Operator (Job-only mode) to provide `VulnerabilityReport` for policy #3 above
- Use Kubernetes built-in Pod Security Admission (PSA) to label the namespaces managed by this repo (`argocd`, `workloads`, `dify`, `llm`, `headlamp`, plus the newly created `kyverno`, `trivy-system`, `sealed-secrets`) with the `baseline` label
- Fix the securityContext of the two self-built workloads so they pass the restricted-equivalent policy:
  - `vikunja-notify-relay`: add `securityContext` (the image is already `USER nobody`, just not declared)
  - `placeholder-hello`: switch to the `nginxinc/nginx-unprivileged` base image (the current `nginx:alpine` has no `USER` and actually runs as root), change containerPort to 8080
- Run the three Kyverno policies in `Audit` mode for a period first, and only switch to `Enforce` after confirming no false positives

**Not done in this phase (left to later phases or explicitly excluded):**
- Signing/re-signing third-party images (image promotion) — evaluated as disproportionate to the current scale, see the design discussion
- `lab-environment` (a project not managed by this repo) gets no PSA label; the scope only covers namespaces managed by this repo
- The restricted level is not enforced on third-party-image workloads (trilium, vikunja, apprise, dify, the llm suite) — these stay on baseline, so the trilium `runAsUser` conflict mentioned in the phase D handoff needs no handling
- Sealed Secrets does not handle 3x-ui (stays in compose, outside the k3s scope)
- Trivy Server cache mode (a resident pod holding the vulnerability DB) — use Job-only mode first, saving a ~512Mi resident pod; revisit only if scan frequency makes the cost worthwhile

## Current-state constraints

Continuing the roadmap and phases A-D: single machine 4C/24G, memory runs out earlier than CPU (CPU 13% vs memory measured 78%). The `workloads` namespace is mixed — self-built images (`placeholder-hello`, `vikunja-notify-relay`) share one namespace with third-party images (`trilium`, `vikunja`, `apprise`, `homepage`, `evidence-os-website`), so any policy "targeting only self-built images" must match by workload/image reference, not by a namespace-level mechanism (PSA is namespace-level — this is the direct reason for choosing "PSA does baseline only, restricted is delegated to Kyverno per-workload").

## Architecture

```
                              ┌─ PSA label(K8s built-in, free)
                              │   namespace: argocd/workloads/dify/llm/headlamp/kyverno/trivy-system/sealed-secrets → baseline
                              │
git push(policy YAML / values.yaml change)
        │
        ▼
ArgoCD(existing)
  root Application
    ├─ sealed-secrets(new, Helm, its own `sealed-secrets` ns)──▶ controller pod
    ├─ trivy-operator(new, Helm, its own `trivy-system` ns, Job-only values)──▶ operator pod + triggered scan Job → VulnerabilityReport CRD
    └─ kyverno(new, Helm, its own `kyverno` ns, admission-controller only)
          └─ policies/(new, Kyverno ClusterPolicy manifests, validationFailureAction: Audit)
                ├─ restrict-image-registry.yaml   (Cosign verify, match: ghcr.io/jeromefromcn/*)
                ├─ require-vuln-scan-clean.yaml    (check VulnerabilityReport, match: all workloads)
                └─ restricted-self-built.yaml      (restricted baseline, match: placeholder-hello / vikunja-notify-relay)
        │
        ▼
(when deploying any new Pod)
  admission webhook runs the three policies in order → Audit mode only logs, doesn't block → after the observation period switch to Enforce
```

Sealed Secrets is an independent subsystem, not dependent on Kyverno/Trivy, and can be done and verified first.

## Components and configuration

| Item | Decision | Rationale |
|---|---|---|
| Namespaces for the three new components | each its own ns: `kyverno`, `trivy-system`, `sealed-secrets` (all matching the corresponding Helm chart defaults) | follows the existing independent-ns convention of `headlamp`; all three are cluster-level components, not riding inside `workloads` or other business namespaces, so the PSA/resource-quota scope is easy to circumscribe |
| Kyverno install scope | install only `admission-controller` (1 replica), disable `background-controller`/`reports-controller`/`cleanup-controller` | these three correspond to "background re-check of existing resources", "PolicyReport visualization", "TTL resource cleanup" respectively, all unneeded this phase; disabling saves 3-6 pods, consistent with the roadmap's "optional resource-saving component builds" principle |
| Trivy Operator mode | Job-only, don't enable the resident `trivy-server` cache pod | saves a ~512Mi resident pod; at the scale of 13 images, the cost of re-downloading the vulnerability DB is acceptable; revisit when the scale grows |
| Cosign verification scope | match only `ghcr.io/jeromefromcn/*` (`imageReferences`/`skipImageReferences`) | third-party images never passed through this signing pipeline, so indiscriminate verification would simply block existing services; scoping by image reference pattern is standard practice in the Kyverno/Sigstore policy-controller official docs, not a stopgap |
| restricted baseline scope | match only the two Deployments `placeholder-hello`, `vikunja-notify-relay` (per-workload, not per-namespace) | the `workloads` namespace mixes self-built and third-party images; PSA's namespace-level label can't "pick just two workloads in a namespace"; use Kyverno per-workload policy instead, scoped the same way as Cosign verification |
| Trivy CVE gate scope | all workloads across the whole cluster, regardless of self-built/third-party | deliberately not narrowed — third-party images are where the true unknown risk lies; self-built images are already gated once by Trivy in CI, so this is double insurance, not duplicate effort |
| PSA baseline scope | `argocd`, `workloads`, `dify`, `llm`, `headlamp`, `kyverno`, `trivy-system`, `sealed-secrets` (namespaces managed by this repo, including the three new ones this phase) | `lab-environment` is not managed by this repo, so its security settings are untouched; `kube-system` and other system namespaces inherently need privilege and get no label |
| Policy rollout cadence | run `validationFailureAction: Audit` first to observe, switch to `Enforce` after confirming no false positives | standard policy-as-code rollout cadence; the Trivy CVE gate has the widest scope and highest risk, especially needing this observation period to catalog the existing CVE state of third-party images (dify/postgres/trilium etc.), avoiding a hard freeze of whole deployment batches at the moment of switching to Enforce |
| Admission behavior when Trivy scan results aren't ready | fail-closed (block if no `VulnerabilityReport` is found) | Trivy Operator scans brand-new images asynchronously (triggered Job), so at admission time the report may not exist yet. Fail-closed is safer; the cost is a brand-new image's first deploy waits for the Operator scan before sync succeeds; ArgoCD auto-retries anyway, no manual intervention, just a few extra minutes on first deploy |
| Sealed Secrets private key backup | the TLS private key produced by the controller (`sealed-secrets-key` Secret) must be separately exported, encrypted, and stored off-cluster | a single-node cluster has no multi-replica etcd safety net; the private key is the only decryption credential, and losing it means every SealedSecret is permanently undecryptable; this is an ops procedure that never existed before, added this phase |
| Migrating the existing 4 out-of-band Secrets | encrypt each existing value with `kubeseal`, write the `SealedSecret` manifests into the repo, replacing the manually created Secrets | takes over the phase D handoff list `workloads/vikunja`, `dify/dify-secrets`, `llm/open-webui`, `llm/sillytavern`; new services' Secrets all go this route afterward |
| `vikunja-notify-relay` securityContext | Deployment adds `runAsNonRoot: true` + `allowPrivilegeEscalation: false` + drop `ALL` capabilities + `seccompProfile: RuntimeDefault` | the image already uses `USER nobody`, just not declared in the manifest; restricted checks the declaration itself, not the actual runtime identity |
| `placeholder-hello` base image | switch to `nginxinc/nginx-unprivileged`, containerPort from 80 to 8080 | the current `nginx:1.31.3-alpine3.24` has no `USER` instruction and actually runs as root, and can't pass restricted; this Service has no NodePort/external exposure, just CI practice use, low-risk change |

## Repo layout

Continue the `vps_oracle/k3s/` conventions from phases A-D; Kyverno/Trivy Operator/Sealed Secrets are cluster-level components, same tier as `cilium/` and `argocd/`, not placed under `apps/`:

```
vps_oracle/k3s/
  kyverno/
    values.yaml                       # Helm values: admission-controller only
    policies/
      restrict-image-registry.yaml    # Cosign imageVerify, match ghcr.io/jeromefromcn/*
      require-vuln-scan-clean.yaml    # check VulnerabilityReport, match all workloads
      restricted-self-built.yaml      # restricted baseline, match placeholder-hello / vikunja-notify-relay
  trivy-operator/
    values.yaml                       # Job-only mode
  sealed-secrets/
    values.yaml
    secrets/
      vikunja.sealed.yaml             # kubeseal-encrypted output, safe to commit to git
      dify-secrets.sealed.yaml
      open-webui.sealed.yaml
      sillytavern.sealed.yaml
  manifests/
    pod-security-labels.yaml          # new: PSA baseline label for argocd/workloads/dify/llm/headlamp/kyverno/trivy-system/sealed-secrets(via kubectl label or merged into existing namespace manifests)
  argocd/apps/
    kyverno.yaml                      # child Application: chart + values + policies/
    trivy-operator.yaml
    sealed-secrets.yaml
  apps/
    vikunja/k8s/relay-deployment.yaml # modified: add securityContext
    placeholder-hello/
      Dockerfile                      # modified: base image switched to nginx-unprivileged
      k8s/deployment.yaml             # modified: containerPort 80 → 8080
      k8s/service.yaml                # modified: targetPort changed to 8080 too
```

The three new Applications follow `argocd.yaml`'s three-source pattern (`chart` + values ref + `policies/`/`secrets/` manifests path), not the single-source `apps/<name>/k8s/` pattern common for single services.

## Verification checklist (phase E pass criteria)

**Sealed Secrets:**
1. `kubectl -n argocd get application sealed-secrets` → `Synced` + `Healthy`
2. The 4 existing Secrets (`workloads/vikunja`, `dify/dify-secrets`, `llm/open-webui`, `llm/sillytavern`) are now produced by their `SealedSecret`s; `kubectl get secret <name> -o yaml` contents match pre-migration (values unchanged, only the source changed)
3. Delete one of the Secrets and confirm the controller auto-recreates it from the `SealedSecret` (proving it truly took over, not just stored an encrypted copy without wiring it up)
4. The private key has been exported and backed up off-cluster, the backup file exists and is encrypted

**Kyverno + Trivy:**
5. `kubectl -n argocd get application kyverno,trivy-operator` → both `Synced` + `Healthy`
6. `kubectl get vulnerabilityreports -A` has data covering the images of all existing workloads
7. Run the three policies first in `Audit`: in the violation records shown by `kubectl get events` or policy reports, confirm one by one that "the scope design matches expectations" — especially the Trivy CVE gate over third-party images (dify/postgres/trilium etc.); if there are CRITICAL-with-fix items, handle them first (upgrade or record an exception) before switching to Enforce
8. After the `placeholder-hello`, `vikunja-notify-relay` securityContext fixes, manually trigger a sync and confirm both remain `Running` (didn't fall over from the base image/port change)
9. After switching to `Enforce`: deliberately apply a violating manifest (e.g. pointing at an unsigned `ghcr.io/jeromefromcn/*` image, or an image with a known CRITICAL CVE), confirm admission blocks it with a readable error message
10. After switching to `Enforce`, re-check all existing Applications still `Synced` + `Healthy` (proving no false positives on any existing service)

**PSA:**
11. `kubectl get ns argocd workloads dify llm headlamp kyverno trivy-system sealed-secrets -o jsonpath='{.items[*].metadata.labels}'` confirms `pod-security.kubernetes.io/enforce=baseline` is on all of them
12. Re-check all pods under these 8 namespaces remain `Running` (baseline shouldn't block any existing service; if something unexpected happens, investigate)

## Known limitations / failure modes

- **PSA baseline gives third-party images no non-root protection**: third-party workloads like trilium stay on baseline and may still run as root — this is a deliberate scope reduction (see "Not done this phase"), not an omission; tightening later requires probing each third-party image's actual runtime UID individually
- **Trivy Job-only mode re-downloads the vulnerability DB**: every triggered scan re-pulls the vulnerability database, so scan latency is higher than the trivy-server cache mode; acceptable at the scale of 13 images
- **Sealed Secrets private key is a single point of failure**: the cluster itself has no HA; the key backup is the only rescue path, and if the backup procedure isn't done properly, this phase's work is effectively for nothing
- **The Audit → Enforce switch is a human judgment, not automation**: a human must review the violation records during the Audit period and decide what to handle and what to exempt before switching to Enforce; there's intentionally no automated "auto-switch after N days" mechanism (supply chain policy shouldn't self-tighten unattended)
- **After Trivy CVE gate Enforce, existing services hit by a newly disclosed CVE have new deployments blocked, but running pods are unaffected**: admission only governs "creation"; it won't kill running pods just because background scans find a new CVE. Only the next time that workload triggers a redeployment (tag change, scale, etc.) is it blocked — this is an inherent limitation of the admission mechanism, not a design gap
- **After switching `placeholder-hello` to `nginx-unprivileged`, its CI workflow needs no change**: the Dockerfile base-image change and containerPort→8080 don't affect the build/scan/sign logic in `.github/workflows/placeholder-hello.yml`, so no touch needed

## Handoff to phase F

Phase F (ApplicationSet PR Generator lanes) depends on what this phase leaves behind: Kyverno's per-workload scope-matching syntax (the `restricted-self-built.yaml` selector pattern, copyable for lane environments) and the Sealed Secrets `SealedSecret` convention (PR lanes' replicated namespaces also need Secrets, using the same kubeseal flow, without repeating phase D's out-of-band Secret mistake).

This phase is also phase G (service mesh)'s precondition: the three Kyverno policies currently use `ValidatingAdmissionPolicy`/`ClusterPolicy` match logic (image reference / workload name), and if G's Istio Ambient wants to selectively enable specific namespaces, it can borrow the same "per-workload rather than per-namespace" scoping approach.