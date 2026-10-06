# 18 — PR lane: a pull request running next to production

## Purpose
Open a pull request on the fork and watch it run in the lab next to the
baseline, reached only by requests that ask for it, across every hop. It
is built, scanned and signed by CI, admitted only because its signature
checks out, and gone when the PR closes.

## Preconditions
Preflight passed; 12 reset (the green is at 0: a lane uses the same memory
headroom, so the two never run together); no Rollout of visits-service in
progress. The fork has the `lane:<service>` labels
(`gh label list -R Jeromefromcn/spring-petclinic-microservices | grep lane:`).

The fork's `demo/pr-lane` branch must be one commit on top of the fork's
current `main`:
```bash
# In the fork checkout: expect exactly one commit
git -C ../spring-petclinic-microservices fetch origin
git -C ../spring-petclinic-microservices log --oneline origin/main..origin/demo/pr-lane
```
If `main` has moved past the branch's base, rebase `demo/pr-lane` onto it
and force-push it before the demo (last done 2026-10-06).

## Before you start: open the views
1. **ArgoCD — the application list**, search `lab-`:
   <https://argocd.jerome.cloudns.asia/applications?search=lab->
   The `lab-lanes` ApplicationSet creates one Application per labelled PR
   and service. None exists yet.
2. **Grafana — Explore**, data source **Loki**, last 5 minutes, **Query
   type Instant**. visits-service requests at the waypoint, by where it
   sent them:
   ```logql
   sum by (upstream_cluster) (count_over_time({service="istio-proxy"} | json | authority=~"visits-service.*" [2m]))
   ```
   One row: `inbound-vip|8082|http|visits-service…`, the baseline.
3. **Jaeger**: <https://jaeger.lab.jerome.cloudns.asia>, service
   `customers-service`, operation `http get /owners/{ownerId}/visits`.

## Steps

### 1. Open the pull request
```bash
# The fork the PR is opened on
F=Jeromefromcn/spring-petclinic-microservices

# Open the PR from demo/pr-lane; note its number
gh pr create -R $F --head demo/pr-lane --base main --title "demo: PR lane" --body "Lab PR lane demo (docker-gitops docs/demo/18). Closed, never merged."

# The PR number from the URL above
N=<number>
```
Open the PR's **Checks** tab on GitHub. `build-scan-sign (visits-service)`
builds the image, scans it with Trivy (a fixable CRITICAL CVE fails the
build), and signs it keylessly with the PR's identity. ~2 minutes.

```bash
# Or wait for it in the terminal
gh pr checks $N -R $F --watch
```

### 2. Ask for a lane
```bash
# Label the PR to ask for a visits-service lane
gh pr edit $N -R $F --add-label lane:visits-service
```
Within 30 s, `lab-visits-service-pr-<N>` appears in the ArgoCD list.
Open it: one Deployment and its Service, syncing. The pod is Ready after
~90 s.

The pod ran because Kyverno verified its image signature:
```bash
# Kyverno's verdict, recorded on the pod: expect the PR's image tag and "pass"
kubectl -n lab-environment get pods -l lab.jerome/lane=pr-$N -o jsonpath='{.items[0].metadata.annotations.kyverno\.io/verify-images}'; echo
```

### 3. Anything else is refused
The same admission check, asked about two images that must not run:
```bash
# A local build: refused by lab-business-images-from-ghcr
kubectl -n lab-environment run probe-local --image=ops-lab/visits-service:21d8461c6ce4 --labels=app=visits-service --dry-run=server

# An image CI pushed but never signed: refused by restrict-image-registry
kubectl -n lab-environment run probe-unsigned --image=ghcr.io/jeromefromcn/petclinic-unsigned@sha256:b5b9d0eacd284190ca95f06c3f04cd9ddcc9020eb763d510a95c12b84ecaf21c --dry-run=server
```
The first is refused with `a local ops-lab/* build is refused`. The second
is refused with `no matching signatures found`. `--dry-run=server` runs
the real admission webhooks and then creates nothing.

### 4. Only requests that ask reach the lane
```bash
# Lab ingress (lab-ingress-istio NodePort on vps_oracle)
U=http://10.0.0.95:30097

# A fresh JVM's first calls can exceed the lane's 3 s timeout: warm up
# until 10 header requests in a row come from the lane
n=0; until [ $n -ge 10 ]; do b=$(curl -s -m 5 -o /dev/null -w '%header{x-visits-build}' -H "x-pr-lane: $N" "$U/api/visit/pets/visits?petId=1"); [ -n "$b" ] && n=$((n+1)) || n=0; sleep 0.5; done; echo "lane warm"

# 10 requests with x-pr-lane; the lane build marks its responses with x-visits-build
for i in $(seq 1 10); do curl -s -o /dev/null -w '%{http_code} [%header{x-visits-build}]\n' -H "x-pr-lane: $N" "$U/api/visit/pets/visits?petId=1"; done | sort | uniq -c

# 10 requests without the header; expect the baseline (no mark)
for i in $(seq 1 10); do curl -s -o /dev/null -w '%{http_code} [%header{x-visits-build}]\n' "$U/api/visit/pets/visits?petId=1"; done | sort | uniq -c

# 5 marked requests via customers-service: the header has to cross a hop to reach visits
for i in $(seq 1 5); do curl -s -o /dev/null -w '%{http_code}\n' -H "x-pr-lane: $N" "$U/api/customer/owners/1/visits"; done | sort | uniq -c
```
`10 200 [lane]`, `10 200 []`, `5 200`.

Run the Loki query again. A second row:
`outbound|8082||visits-service-pr-<N>…`, with exactly the marked requests:
10 warm-up + 10 direct + 5 through customers = 25 in the rehearsal. The
generator's traffic is all in the baseline row.

### 5. The header crossed a hop
In Jaeger, **Find Traces**, and open one of the 5 requests through
customers-service. The trace holds customers-service's spans, and below
them a waypoint span named `visits-service-pr-<N>…:8082/*`. The client
never talked to visits. customers-service propagated the header on its own
call, and the waypoint picked the lane there.

### 6. Close the PR
```bash
# Close the PR; the lane is torn down
gh pr close $N -R $F
```
Within a minute, `lab-visits-service-pr-<N>` disappears from the ArgoCD
list and its pod terminates (46 s in the rehearsal). Nothing in git
changed: the lane existed because a labelled PR was open.

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
- **Scanned before signed.** CI's Trivy step fails the build on a fixable
  CRITICAL CVE, so nothing known-vulnerable gets a signature. Getting there
  took a Spring Boot 4.0.1 -> 4.0.8 upgrade plus a tomcat pin (Boot's managed
  11.0.24 still had them) - the gate found real CVEs on its first run.
- **Pushing to a labelled PR takes the lane down.** The generator picks up
  the new head SHA within 30 s, the lane Deployment (Recreate) drops its
  pod, and the new one is refused (`FailedCreate`) until CI has signed that
  SHA - minutes later, then ReplicaSet backoff. To update a lane: remove
  the `lane:` label, push, wait for `build-scan-sign`, label again.
- **Head SHA, not merge SHA.** The image is tagged with the PR's head commit;
  the signature's subject is the merge ref GitHub builds PRs on.
- **Capacity is shared in time.** Lanes use the headroom page 12's green
  needs: at most two lane pods, and never while page 12's green runs.

## Reset
Step 6 is the reset. Before the next page, check no lane is left:
```bash
# Expect no output
kubectl -n lab-environment get deploy,pods -l lab.jerome/lane
```
