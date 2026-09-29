# 10 — Canary by weight: catch a bad build, roll back

## Purpose
Send exactly 10 % of traffic to one v2 pod — a share no replica count
gives — with a build that has a real bug. Show that the platform, not the
app, pins every error on the canary, that 90 % of users never see it, and
that rolling back is one `git revert`.

## Preconditions
Preflight passed; 09 reset. The v2-bad build (`77962eada66c`) fails on
owners with two pets (3, 6 and 10): its "simplified" `primaryPetName`
throws — and its unit tests passed, because none had two pets.

## Commands
```bash
git pull --ff-only
git apply k3s/apps/lab-environment/demo/patches/canary-weight.patch
git --no-pager diff
git commit -m "demo: canary customers-service v2-bad at 10%" -- k3s/apps/lab-environment/k8s
git push || echo "PUSH FAILED - stop here"
argocd app get lab-environment --core --refresh >/dev/null
end=$((SECONDS + 300)); until argocd app get lab-environment --core -o json | jq -e --arg r "$(git rev-parse HEAD)" '.status.operationState.syncResult.revision == $r and .status.operationState.phase == "Succeeded"' >/dev/null; do [ $SECONDS -lt $end ] || { echo "SYNC WAIT TIMED OUT - stop here"; break; }; sleep 5; done
kubectl -n lab-environment rollout status deploy/customers-service-canary --timeout=6m
demo-window start canary-weight
for i in $(seq 1 200); do curl -s -o /dev/null -w '%{http_code}\n' http://10.0.0.95:30097/api/customer/owners/3; sleep 0.3; done | sort | uniq -c
demo-window stop canary-weight
git revert --no-edit HEAD
git push || echo "PUSH FAILED - stop here"
argocd app get lab-environment --core --refresh >/dev/null
end=$((SECONDS + 300)); until argocd app get lab-environment --core -o json | jq -e --arg r "$(git rev-parse HEAD)" '.status.operationState.syncResult.revision == $r and .status.operationState.phase == "Succeeded"' >/dev/null; do [ $SECONDS -lt $end ] || { echo "SYNC WAIT TIMED OUT - stop here"; break; }; sleep 5; done
demo-evidence canary-weight
```

## Expected result
About 180 `200` and 20 `500`. The evidence shows the canary at ~10 % of
customers-service requests, every 5xx on the canary subset and none on
stable, the rollback commit deployed, and the same split in the pods' own
500 counts.

## Evidence
- **Envoy (waypoint access log):** requests and 5xx per subset
  (`upstream_cluster`).
- **ArgoCD:** the revert's SHA in the application's deploy history.
- **App (Spring metrics):** 500s counted by the canary pod versus the five
  stable pods.

## Talking points
- The weight is independent of replicas: one pod takes 10 %, and 1 % would
  need no more pods.
- **500 is deliberately not in `retryOn`.** Retrying it would send the
  retry through the same 90/10 split — nine times in ten to stable — and
  the canary's bug would disappear from the user-facing numbers. Not
  retrying 500 is what makes a canary observable.
- Outlier detection will not save you here: with one canary pod,
  `maxEjectionPercent: 50` of one host floors to 0 ejectable hosts. Envoy
  ejects at least one host regardless only when `always_eject_one_host` is
  enabled, and it is off here. The decision to roll back is a human's (or, later,
  Argo Rollouts' analysis — sub-project 4).
- The generator's `/api/customer/owners` list also serialises owners 3, 6
  and 10, so ~10 % of its list calls fail too — the blast radius is the
  weight, not the endpoint.
- The bug passed CI: v2-good's tests covered owners with zero and one pet,
  and the "simplification" kept them green. Production-shaped traffic is
  what a canary adds that unit tests cannot.

## Reset
The page's revert is the rollback. `demo-reset canary-weight` waits for the
canary pod to go and verifies the baseline.
