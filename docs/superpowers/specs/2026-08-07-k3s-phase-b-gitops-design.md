# K3s Phase B — GitOps Bootstrap Design

Date: 2026-08-07

Corresponds to phase B of the [K3s Cloud-Native Lab Platform Roadmap](2026-08-05-k3s-cloud-native-platform-roadmap.md): ArgoCD (app-of-apps) + GitHub Actions CI skeleton (build→Trivy→Cosign). Deliverable: from here on all deployments go through GitOps, no manual `kubectl apply`.

Prerequisite: [Phase A Cluster Foundation Design](2026-08-05-k3s-phase-a-cluster-foundation-design.md) is complete and validated (see its validation checklist). Current cluster state: the `workloads` namespace is empty, Cilium/Hubble/local-path-provisioner are all `Running`, and `kubectl get ciliumnode` shows the pod CIDR `10.42.0.0/16` is locked in.

## Scope

**What this phase does:**
- Install ArgoCD with Helm, single replica, disabling the components not needed
- Build the app-of-apps structure: one root Application managing three child Applications — ArgoCD itself, phase A's `namespace/resourcequota/limitrange` (currently applied via manual `kubectl apply`; brought under GitOps management this phase), and a new `placeholder-hello` placeholder service
- Add `placeholder-hello`: a minimal container with no real purpose, dedicated to giving CI something to practice on (e.g. an nginx returning fixed text), committed into the repo together with its Dockerfile
- GitHub Actions workflow: detect `placeholder-hello` source changes → build (x64 runner + QEMU emulating arm64) → Trivy scan (CRITICAL blocks) → Cosign keyless signing → push to GHCR
- Verify "no manual kubectl apply" actually holds: manually break a resource managed by ArgoCD, confirm self-heal restores it automatically
- Publish the ArgoCD UI to the public internet via NPM, with the `self-only` access list (same as existing services)

**What this phase does not do (left to later phases):**
- Real service migration (homepage, trilium, etc.) — phase C
- Full automation from image push to deployment (Argo CD Image Updater or similar) — deployment this phase is still "CI signs image → manually change the tag in YAML → commit → ArgoCD sync", the full flow going through git commit, meeting the "no manual kubectl apply" goal, but not auto-changing the tag on image push. This is deliberate scope reduction, not an omission
- Trivy admission gate (cluster-side blocking of invalid image deployment), Sealed Secrets, Kyverno — phase E
- ApplicationSet PR-generator lanes — phase F; the ApplicationSet controller installed this phase is just a Helm chart default component, installed now but not used
- homepage dashboard card — ArgoCD can deploy anything to the cluster, so following the 3x-ui precedent it is classified as a security-sensitive service and gets no card

## Current-State Constraints (continuing the roadmap and phase A)

Single 4C/24G machine; live `free -h` measurement shows 13Gi available now (buff/cache reclaimable); the docker-gitops repo itself is a **private** GitHub repo and is exactly what will serve as ArgoCD's GitOps source repo — no separate repo needed; the host is aarch64 (Ampere Altra), but GitHub-hosted runners default to x86_64, requiring QEMU cross-arch builds; GHCR (`ghcr.io`) is already an existing convention (homepage, llm, 3x-ui all pull images from there).

## Architecture

```
Developer git push (main)
        │
        ▼
GitHub Actions (ubuntu-latest, x64 + QEMU)
  1. buildx build --platform linux/arm64
  2. Trivy image scan (CRITICAL → fail the job)
  3. push → ghcr.io/jeromefromcn/placeholder-hello:<tag>
  4. cosign sign --yes (keyless, GitHub OIDC → Fulcio cert → Rekor transparency log)
        │
        │ (manual step: change the image tag in apps/placeholder-hello/k8s/deployment.yaml, git commit + push)
        ▼
ArgoCD (in-cluster, argocd namespace)
  root Application (app-of-apps)
    ├─ argocd (self-managed Helm Application)
    ├─ phase-a-foundation (namespace + resourcequota + limitrange)
    └─ placeholder-hello (Deployment + Service, deployed into the workloads namespace)
  ── selfHeal: true, prune: true, any manual change is reverted to the git state automatically
        │
        ▼
ArgoCD Server (NodePort)
        │
        ▼
NPM (access list: self-only)──▶ argocd.jerome.cloudns.asia
```

## Components & Configuration

| Item | Decision | Rationale |
|---|---|---|
| Install method | Helm (`argo/argo-cd` chart), following the pattern used to install Cilium in phase A | Version pinning and a clear upgrade path, consistent with the existing convention; check the chart's actual latest stable version at install time and write the pinned version back to `vps_oracle/k3s/README.md` (this design doc was written in 2026-08; concrete version numbers deferred to install time to avoid pinning stale versions) |
| Topology | Single replica (no HA) | Single-node cluster; HA mode's multiple repo-server/application-controller replicas have no real fault-tolerance benefit, just extra resource consumption |
| Dex (SSO) | Disabled | No external identity provider; auth is two layers — ArgoCD's built-in local admin account + NPM access list |
| Notifications controller | Disabled | No alert-channel integration need this phase; skip to save resources, enable when needed |
| ApplicationSet controller | Keep (chart default) | Needed for phase F's PR lanes; low resource overhead, installing it now (unused) is simpler than upgrading the chart later |
| selfHeal / prune | On, applied to the root and all child Applications | The acceptance core of this phase — "all deployments go through GitOps" is hollow without self-heal; manual kubectl changes would not be corrected, making the claim not true |
| ArgoCD Server external protocol | `--insecure` (plaintext HTTP), TLS terminated at NPM | Same pattern as other services in this repo (NPM does TLS termination uniformly, containers stay plaintext internally); no need to sign a separate ArgoCD certificate |
| CI runner | `ubuntu-latest` (x64) + `docker/setup-qemu-action` + `buildx` emulating `linux/arm64` | No host resource consumed, no risk of running arbitrary workflow code on a self-hosted runner; a private repo's x64 runner minutes are within free quota, and the build cost of a single placeholder app is negligible. If native build speed is genuinely needed later, just switch `runs-on` to self-hosted — the rest of the pipeline is unchanged |
| Trivy scan | Scan the CI-built image, CRITICAL severity fails the job | Blocking known critical vulnerabilities at CI is basic supply chain hygiene; not redundant with phase E's cluster-side admission gate — CI blocks images "that go through this pipeline", the cluster blocks images "that get deployed at all" (e.g. manually pushed bypassing CI); the two layers are complementary |
| Cosign signing | Keyless (GitHub OIDC → Sigstore Fulcio/Rekor) | No private key management, no key leakage or rotation concerns; signing and verification both leave publicly auditable Rekor records, matching industry practice for supply chain transparency |
| Image tag update | Manually edit `apps/placeholder-hello/k8s/deployment.yaml` then git commit | Deliberately no CI auto-tag-writeback to the repo (would require an extra repo write token and auto-commit mechanism); manually editing YAML + commit already meets the "deploy via git, not kubectl apply" goal; automation left for later if needed |

## Repo Layout

New content, continuing the `vps_oracle/k3s/` convention from phase A:

```
vps_oracle/k3s/
  argocd/
    values.yaml                    # Helm values (non-secret): Dex/notifications disabled, etc.
    apps/
      root.yaml                     # app-of-apps root Application, pointing at this directory
      argocd.yaml                    # child Application: self-manages the argocd Helm release
      phase-a-foundation.yaml         # child Application: points at ../../manifests/ (phase A's namespace/quota/limitrange)
      placeholder-hello.yaml           # child Application: points at ../../apps/placeholder-hello/k8s/
  apps/
    placeholder-hello/
      Dockerfile                    # minimal nginx placeholder page
      k8s/
        deployment.yaml              # image tag changed manually to trigger deployment
        service.yaml

.github/
  workflows/
    placeholder-hello.yml           # build→Trivy→Cosign, push to GHCR
```

Nothing under `vps_oracle/k3s/argocd/` holds any secret other than ArgoCD admin password / GitHub OIDC-related config — Cosign keyless signing requires no key material in the repo or GitHub secrets; the ArgoCD initial admin password is generated in a Secret inside the cluster by the Helm chart's default behavior, and never enters the repo.

## NPM Bridging

Reuse the phase-A-validated pattern (NodePort → NPM forwarding to host IP:port): the ArgoCD Server Service exposes a fixed NodePort, and NPM gets one proxy host:

| Field | Value |
|---|---|
| Domain Names | `argocd.jerome.cloudns.asia` |
| Scheme | `http` |
| Forward Hostname / IP | the host's private IP (currently `10.0.0.95`, see the DHCP drift note in phase A README) |
| Forward Port | ArgoCD Server's NodePort |
| Access List | `self-only` (same as the other services; ArgoCD is more sensitive, no reason to relax) |
| Websockets Support | On (used by the ArgoCD UI) |

The rest of the SSL tab settings follow the README's "connecting services to NPM reverse proxy" section, including the known gotcha that Force SSL/HTTP2 silently resets after saving and must be re-checked.

## Validation Checklist (phase B pass criteria)

1. `kubectl -n argocd get pods` all `Running`; `kubectl -n argocd get application root -o jsonpath='{.status.sync.status}'` → `Synced`, `.status.health.status` → `Healthy`
2. The three child Applications (argocd / phase-a-foundation / placeholder-hello) all `Synced` + `Healthy`
3. `kubectl get resourcequota,limitrange -n workloads` shows content matching `vps_oracle/k3s/manifests/` in git (proving phase A resources are now under ArgoCD management, not leftover manual apply state)
4. **Self-heal live test**: `kubectl scale deployment placeholder-hello -n workloads --replicas=0`, wait tens of seconds, confirm ArgoCD restores the replica count declared in git — this is the direct evidence that this phase's "no more manual kubectl apply" claim holds; not just whether the sync button can be clicked
5. Push a change under `apps/placeholder-hello/`, confirm all GitHub Actions jobs (build/Trivy/Cosign/push) are green, and a new tag appears on `ghcr.io`
6. `cosign verify` that image (keyless, specifying the GitHub Actions OIDC issuer/identity), confirming signature verification passes and the corresponding record can be looked up in Rekor
7. Manually change the image tag in `k8s/deployment.yaml`, commit + push, confirm ArgoCD auto-syncs and `kubectl -n workloads get pods -l app=placeholder-hello` runs the new image
8. Via NPM, `curl https://argocd.jerome.cloudns.asia` from the external network, confirming it reaches the ArgoCD login page; confirm the access list works (non-allowlisted IPs cannot connect, testable if a second network environment exists)
9. Write the ArgoCD/Cilium-version numbers pinned at install back to `vps_oracle/k3s/README.md`

## Known Limitations / Failure Modes

- QEMU-emulated builds are slower than native; for an extremely small image like `placeholder-hello` the impact is negligible. If phase C/D later runs real services (e.g. the llm inference stack) through the same pipeline, build time may balloon; re-evaluate a self-hosted runner at that point, rather than deciding now
- Image tag update is a manual step, meaning deployment speed is bounded by human reaction time, not real-time; this is deliberate scope reduction (see "what this phase does not do" above), not a defect to fix
- ArgoCD self-heal reverts manual changes within its tens-of-seconds reconcile cycle; during that window the cluster state briefly deviates from git. Acceptable on a single-node lab environment; not a reason to shrink the reconcile interval
- ArgoCD has full deployment permissions over the cluster; the NPM-layer `self-only` access list is currently the only access control; no fine-grained ArgoCD RBAC roles are set up (single-operator, the chart's default admin account suffices). Re-evaluate if multi-person collaboration is needed later

## Handoff to Phase C

Phase C (pick 1~2 low-risk stateless services to work out the migration template) depends on what this phase leaves behind: an ArgoCD that syncs/self-heals correctly, the established app-of-apps pattern under `vps_oracle/k3s/argocd/apps/` (copy the `placeholder-hello.yaml` pattern and point it at real service manifests), and the CI pipeline skeleton (`placeholder-hello.yml` can be copied, changing the build context / image name, and applied to the first actually-migrated service).