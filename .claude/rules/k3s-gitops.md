---
paths:
  - "*/k3s/**"
---

# k3s / ArgoCD change discipline

Applies to everything under `vps_oracle/k3s/`. Operational detail lives in [`vps_oracle/k3s/README.md`](../../vps_oracle/k3s/README.md); this file is only the non-negotiable discipline.

## Git first, always

Every Application runs `prune: true` / `selfHeal: true`. **Never** `kubectl apply` / `patch` / `edit` / `scale` a live resource to try something out — selfHeal reverts it silently within seconds, and you are left with a change that appears applied but isn't.

Correct order: **edit the file → commit → push → let ArgoCD sync (or `argocd app sync <app>`) → verify.**

- Sole exception: the one-time `argocd/apps/root.yaml` bootstrap.
- Read-only diagnostics (`kubectl get` / `describe` / `logs`, `argocd app diff`) are fine at any time.
- For genuine live trial-and-error, disable that Application's `selfHeal` first and re-enable it once the final version is back in git.

## Editing an Application object means syncing `root`

After editing a file under `argocd/apps/` (including adding a new Application), sync **`root`**, not the Application the edit is about — `root` is the layer that applies the Application *objects* themselves. Syncing the Application only re-applies whatever `sources` are already live and silently ignores the edit to its own spec.

## Never test self-heal with `argocd-repo-server`

Scaling it to 0 deadlocks self-heal (the component that computes the fix is the one that's down) and breaks `argocd app sync`/`diff` for everything; recovery needs a manual scale-up. Verify self-heal with a regular workload such as `hello-backend`.

## Namespace PSS constraints

`headlamp` and `pr-lanes` carry `pod-security.kubernetes.io/enforce: baseline`, and the baseline profile **forbids hostPath volumes** — mount files (e.g. tzdata) in those namespaces via ConfigMap + `subPath` instead. See [`vps_oracle/k3s/apps/headlamp/k8s/tzdata-configmap.yaml`](../../vps_oracle/k3s/apps/headlamp/k8s/tzdata-configmap.yaml).

## Node placement

The cluster has two nodes: the server on vps_oracle and a tainted agent, vps-oracle2 (`dedicated=lab:NoSchedule`). Management components stay on the server — never add a toleration for that taint to anything but workloads meant to run on oracle2. Lab placement comes from the Kyverno mutate policy `lab-environment-on-oracle2`, not from the manifests. Storage on the agent uses static `local` PVs, never local-path (its helper pod can't tolerate the taint). Details: the k3s README's "Nodes" section.

## Secrets

Plaintext Secrets never go into git. Use SealedSecrets (`vps_oracle/k3s/sealed-secrets/secrets/`, ciphertext is safe to commit); the flow is in the k3s README's sealed-secrets section.
