# 18 — PR lane: a pull request running next to production

## Purpose
Open a pull request on the fork and show it running in the lab next to the
baseline, reached only by requests that ask for it — across every hop —
built, scanned and signed by CI, admitted only because its signature
checks out, and gone when the PR closes.

## Preconditions
Preflight passed; 12 reset (the green is at 0 — a lane uses the same
memory headroom, so the two never run together); no Rollout of
visits-service in progress. The fork's `demo/pr-lane` branch is based on
the current fork `main` (`git -C ../spring-petclinic-microservices log --oneline main..demo/pr-lane` shows exactly one commit; rebase it if `main` moved). The fork has the `lane:<service>` labels (created 2026-09-29; `gh label list -R Jeromefromcn/spring-petclinic-microservices | grep lane:`).

## Commands
```bash
F=Jeromefromcn/spring-petclinic-microservices
LANE_PR=$(gh pr create -R $F --head demo/pr-lane --base main --title "demo: PR lane" --body "Lab PR lane demo (docker-gitops docs/demo/18). Closed, never merged." | grep -oP '/pull/\K[0-9]+'); export LANE_PR; echo "PR $LANE_PR"
end=$((SECONDS + 900)); until gh pr checks $LANE_PR -R $F 2>/dev/null | grep -qP '^build-scan-sign \(visits-service\)\s+pass'; do [ $SECONDS -lt $end ] || { echo "CI WAIT TIMED OUT - stop here"; break; }; sleep 15; done
gh pr edit $LANE_PR -R $F --add-label lane:visits-service
end=$((SECONDS + 600)); until [ "$(kubectl -n lab-environment get pods -l lab.jerome/lane=pr-$LANE_PR -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = True ]; do [ $SECONDS -lt $end ] || { echo "LANE WAIT TIMED OUT - stop here"; break; }; sleep 5; done
argocd app get lab-visits-service-pr-$LANE_PR --core | grep -E '^(Name|Sync Status|Health Status)'
U=http://10.0.0.95:30097
# Ready is not yet warm: a fresh JVM's first calls can exceed the lane's 3 s
# timeout (504). Warm up until 10 header requests in a row come from the lane.
end=$((SECONDS + 180)); ok=0; until [ $ok -ge 10 ]; do [ $SECONDS -lt $end ] || { echo "LANE WARM-UP TIMED OUT - stop here"; break; }; if curl -s -m 5 -o /dev/null -D- -H "x-pr-lane: $LANE_PR" "$U/api/visit/pets/visits?petId=1" | grep -qi '^x-visits-build'; then ok=$((ok + 1)); else ok=0; fi; sleep 0.5; done
sleep 20   # quiet gap: keeps the warm-up out of the window's log lines
demo-window start pr-lane
for i in $(seq 1 10); do curl -s -D- -o /dev/null -H "x-pr-lane: $LANE_PR" "$U/api/visit/pets/visits?petId=1" | tr -d '\r' | awk 'NR==1{c=$2} tolower($1)=="x-visits-build:"{b=$2} END{print c, (b ? "lane" : "baseline")}'; done | sort | uniq -c
for i in $(seq 1 10); do curl -s -D- -o /dev/null "$U/api/visit/pets/visits?petId=1" | tr -d '\r' | awk 'NR==1{c=$2} tolower($1)=="x-visits-build:"{b=$2} END{print c, (b ? "lane" : "baseline")}'; done | sort | uniq -c
for i in $(seq 1 5); do curl -s -o /dev/null -w '%{http_code}\n' -H "x-pr-lane: $LANE_PR" "$U/api/customer/owners/1/visits"; done | sort | uniq -c
sleep 10   # Envoy flushes its access log in batches: let the window's last lines land inside it
demo-window stop pr-lane
demo-evidence pr-lane
gh pr close $LANE_PR -R $F
```

## Expected result
`10 200 lane`, then `10 200 baseline`, then `5 200`. The evidence shows
exactly 15 requests on `visits-service-pr-<N>` — the 10 direct ones and the
5 that reached visits through customers-service — and none of the
generator's traffic.

## Evidence
- **Envoy (waypoint access log):** 15 requests upstream to the lane, every
  other visits request to the baseline.
- **Kyverno:** the lane pod's `kyverno.io/verify-images` annotation shows
  its PR image `pass`; a server-side dry-run of a local `ops-lab/*` image is
  refused by `lab-business-images-from-ghcr`.
- **App (Jaeger):** a trace holding customers-service's spans and the
  waypoint's span named after `visits-service-pr-<N>` — the header crossed
  a hop the client never saw, and the waypoint picked the lane there.

## Talking points
- **Only the changed service runs in the lane.** Every other hop is the
  baseline; the lane is chosen again at every hop by the header. That is
  why the apps propagate it (Micrometer baggage `remote-fields`) —
  api-gateway forwards request headers anyway, but customers' call to
  visits is a new request.
- **Routing order is the whole trick.** On the waypoint an HTTPRoute's rules
  are evaluated before the VirtualService's: a header-only rule takes just
  the lane's requests. An unconditional one would swallow the host — hit on
  hello in phase I.
- **A lane is a test path, not production.** Lane traffic gets Istio's
  default retries (2), not the VirtualService's tuned policy or its outlier
  detection, and the lane runs one pod on the baseline's data.
- **Signed or nothing.** The pod ran because Kyverno verified the image was
  signed by the fork's CI for this PR (`refs/pull/<N>/merge`); a local build
  is refused outright — `verifyImages` alone would have let it through,
  since it only checks images that match its pattern.
- **Scanned, not gated.** CI's Trivy step reports CRITICAL CVEs but does not
  fail the build: the lab's Spring Boot 4.0.1 dependencies carry fixable
  ones, accepted for the demo. Bumping to Boot 4.0.8 + Spring Cloud 2025.1.3
  + tomcat 11.0.26 clears them — the gate could be switched back on.
- **Head SHA, not merge SHA.** The image is tagged with the PR's head commit;
  the signature's subject is the merge ref GitHub builds PRs on.
- **Capacity is shared in time.** Lanes use the headroom page 12's green
  needs: two lane pods at most, never both at once — the reset refuses a
  leftover lane.

## Reset
`gh pr close` (last command) makes the generator drop the PR; ArgoCD deletes
the Application and its resources. `demo-reset pr-lane` waits for the lane
pod to go and verifies the baseline.
