# Kyverno's CVE gate denied DELETE, pinning a vulnerable pod in place and stalling the rollout to its patched image

- Date: 2026-11-05
- Environment: k3s, Kyverno v1.18.2 (`require-vuln-scan-clean`, `validationFailureAction: Enforce`), Trivy Operator; `pr-lanes/hello-frontend` (single replica, `strategy: Recreate`)
- Symptom: the inspector flagged a fixable CRITICAL in the running `hello-frontend` image. After the patched image shipped, ArgoCD showed `Synced / Progressing` and the old pod kept running, with `FailedDelete` events on its ReplicaSet.
- Fix: scoped the policy rule to `operations: [CREATE]` (commit `91c6867`). The image itself was fixed by restoring its build context (`06e540a`, `7dc6f02`).

---

## 1. Conclusion first

**The admission gate was matching every Pod operation, DELETE included, not only CREATE.** `require-vuln-scan-clean` had no `operations` scope. On a DELETE, Kyverno evaluates the rule against the object being removed, so the old pod still looked up its own VulnerabilityReport, still saw the CRITICAL, and was denied. The gate meant to keep vulnerable pods out was keeping one in. `Recreate` waits for the old pod to be gone before it creates the new one, so the rollout stalled on the old pod and never reached the patched image.

The trigger came first. `hello-frontend` still ran the retired `placeholder-hello` image, whose build context commit `64e42c9` had deleted. It could not be patched, a trap `k3s/README.md` had already predicted. When CVE-2026-111497 (brotli-libs) landed, the only way out was to rebuild the image, and deploying that rebuild ran into the DELETE denial.

## 2. Evidence chain

The inspector finding, and the report behind it:

```
⚠️ ReplicaSet pr-lanes/hello-frontend-57c7bc45c4
   1 fixable CRITICAL in jeromefromcn/placeholder-hello (CVE-2026-111497) ... require-vuln-scan-clean will refuse its next pod
```
```
pr-lanes replicaset-hello-frontend-57c7bc45c4-hello-frontend 2026-11-02T14:02:15Z {'criticalCount': 1, 'highCount': 4, ...}
  CVE-2026-111497 brotli-libs 1.2.0-r1 -> 1.2.1-r0 brotli: Out-of-Bounds Write in Google Brotli Decoder
```

Even the newest upstream base still shipped the vulnerable package, so a base bump alone would not have fixed it:

```
$ docker run --rm --pull always nginxinc/nginx-unprivileged:1.31-alpine sh -c 'cat /etc/alpine-release; nginx -v; apk info -v | grep brotli'
3.24.2
nginx version: nginx/1.31.7
brotli-libs-1.2.0-r1
```

After `7dc6f02` (the digest bump) synced, the old ReplicaSet was scaled to 0 but its pod would not go:

```
$ kubectl -n argocd get application hello -o jsonpath='{.status.sync.revision} {.status.sync.status} {.status.health.status}'
7dc6f021df2fb739b2b2172c6e09ae4285cd3c54 Synced Progressing
$ kubectl -n pr-lanes get events --sort-by=.lastTimestamp | tail -2
21s  Normal   ScalingReplicaSet  deployment/hello-frontend              Scaled down replica set hello-frontend-57c7bc45c4 from 1 to 0
9s   Warning  FailedDelete       replicaset/hello-frontend-57c7bc45c4   Error deleting: admission webhook "validate.kyverno.svc-fail" denied the request: ...
```

Full message:

```
resource Pod/pr-lanes/hello-frontend-57c7bc45c4-6s84h was blocked due to the following policies

require-vuln-scan-clean:
  block-critical-fixable-cves: Image has CRITICAL vulnerabilities with an available
    fix (Trivy VulnerabilityReport hello-frontend-57c7bc45c4-6s84h). ...
```

The policy's `match` had `kinds: [Pod]` and a label selector, but no `operations`.

## 3. Root cause

A Kyverno `validate` rule with no `match.resources.operations` applies to CREATE, UPDATE **and DELETE**. On DELETE, Kyverno evaluates the rule against the object being removed (there is no new object), so the rule's `context.apiCall` still resolves `ownerReferences[0].name`, still finds that ReplicaSet's VulnerabilityReport, and the `deny` condition still holds.

The policy blocks exactly the pods it is meant to get rid of: any gated pod whose image picks up a fixable CRITICAL after admission can no longer be deleted by a person, a rollout or the ReplicaSet controller. Under `Recreate` that is a hard stall. Under `RollingUpdate` the new pod would have come up and the old one would have lingered undeletable.

It went unnoticed because pods are almost always removed while their report is clean. The only time a gated pod is deleted while dirty is precisely the remediation rollout, and this was the first one.

## 4. Fix

- `k3s/kyverno/policies/require-vuln-scan-clean.yaml`: add `operations: [CREATE]` under the rule's `match.any[0].resources`. Admission of new pods is the whole point; deletion must never be gated, and UPDATE of an existing pod (labels/annotations) doesn't change the image risk. Validated with `kubectl apply --dry-run=server` before committing.
- Image side, separate from the policy bug: restored `Dockerfile`/`index.html` from `64e42c9^` into `k3s/apps/hello/frontend/`, added `.github/workflows/hello-frontend.yml` (build → Trivy → Cosign, mirroring `hello-backend.yml`), and had the Dockerfile run `apk upgrade` on top of `nginx-unprivileged:1.31.7-alpine3.24`, because upstream had not yet picked up the brotli fix. New image `ghcr.io/jeromefromcn/hello-frontend@sha256:095e60df…`.

## 5. Verification

```
$ kubectl get clusterpolicy require-vuln-scan-clean -o jsonpath='{.spec.rules[0].match.any[0].resources.operations}'
["CREATE"]
$ kubectl -n pr-lanes rollout status deploy/hello-frontend --timeout=240s
deployment "hello-frontend" successfully rolled out
$ kubectl -n pr-lanes get vulnerabilityreports -l trivy-operator.resource.name=hello-frontend-54fc5d578 -o jsonpath='{.items[0].report.summary}'
{"criticalCount":0,"highCount":0,"lowCount":0,"mediumCount":0,"noneCount":0,"unknownCount":0}
```

The page was served in-cluster from `hello-backend` → `http://hello-frontend.pr-lanes.svc.cluster.local/`.

## 6. Leftovers / lessons

- **A `deny` rule that reads external, time-varying state (`context.apiCall`) needs an explicit `operations: [CREATE]`.** Without one it also guards deletion. Rules that only judge the pod spec (`pattern`, `podSecurity`, `verifyImages`) can't flip from pass to fail after admission, so they don't have this failure mode. Surveyed 2026-11-05: `require-vuln-scan-clean` was the only `deny` rule under `k3s/kyverno/policies/`.
- **Deleting a build context strands the image.** `64e42c9` deleted `placeholder-hello`'s build context while `hello-frontend` kept running its image. `k3s/README.md` flagged the trap months earlier, but nothing forced the fix until a CVE did. When retiring an app, check whether another workload still runs its image.
- **Upstream tags lag Alpine fixes.** The latest `nginx-unprivileged` still carried the vulnerable package, so `apk upgrade` in the Dockerfile is what keeps a rebuild useful as remediation.
- No new inspector check needed: `k3s-gated-fixable-cves.sh` raised the CVE ahead of time, and with the policy fixed the stall can't recur.
