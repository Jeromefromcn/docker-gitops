# 18 — PR lane: a fork PR labelled lane:visits-service runs next to the
# baseline; only requests with x-pr-lane: <N> reach it, across every hop.
# The page exports LANE_PR (the PR number) before running demo-evidence.
SENT_DIRECT=10   # the page sends these to /api/visit/... with the header
SENT_HOP=5       # and these to /api/customer/owners/1/visits (via customers)

evidence_pr_lane() {
  local n=${LANE_PR:?export LANE_PR=<the PR number>} per lane base pod ann tid svcs out ok pat
  # The lane's host inside upstream_cluster: "|" before it and "." after it
  # hold for both Envoy cluster shapes (outbound|8082||<host> for the lane,
  # inbound-vip|8082|http|<host> for the baseline).
  pat="[|]visits-service-pr-${n}[.]"
  settle
  per=$(loki_by upstream_cluster '{service="istio-proxy"} | json | __error__="" | authority=~"visits-service.*"' "$WINDOW_START" "$WINDOW_END")
  lane=$(echo "$per" | awk -v p="$pat" '$2 ~ p { s += $1 } END { print s + 0 }')
  base=$(echo "$per" | awk -v p="$pat" '$2 !~ p { s += $1 } END { print s + 0 }')
  rec_if envoy "waypoint sent $lane requests to visits-service-pr-$n (want exactly $((SENT_DIRECT + SENT_HOP)): every header request, nothing else) and $base to the baseline (want >= $SENT_DIRECT)" \
    [ "$lane" -eq $((SENT_DIRECT + SENT_HOP)) -a "$base" -ge "$SENT_DIRECT" ]
  pod=$(kubectl -n "$NS" get pods -l "lab.jerome/lane=pr-$n" -o name | head -1)
  ann=$(kubectl -n "$NS" get "${pod:-pod/none}" -o jsonpath='{.metadata.annotations.kyverno\.io/verify-images}' 2>/dev/null || true)
  rec_if kyverno "lane pod ${pod#pod/} signature: ${ann:-none} (want ghcr.io/jeromefromcn/petclinic-visits-service:<sha> pass)" \
    grep -q 'petclinic-visits-service:[0-9a-f]\{40\}":"pass"' <<< "$ann"
  out=$(kubectl apply --dry-run=server -f - 2>&1 <<EOF || true
apiVersion: v1
kind: Pod
metadata: {name: probe-local, namespace: $NS, labels: {app: visits-service}}
spec:
  containers:
    - {name: c, image: "ops-lab/visits-service:21d8461c6ce4", resources: {requests: {cpu: 10m, memory: 16Mi}}}
EOF
)
  rec_if kyverno "a local ops-lab/* image is refused: $(grep -o 'lab-business-images-from-ghcr' <<< "$out" | head -1)" \
    grep -q 'lab-business-images-from-ghcr' <<< "$out"
  # The waypoint names its span after the upstream host, so a trace holding
  # a waypoint span "visits-service-pr-<N>...:8082/*" next to customers'
  # spans shows the lane chosen at the customers -> visits hop. (Micrometer's
  # baggage tag-fields leaves no x-pr-lane tag on this Boot version.)
  tid=$(curl -sf -G "$JAEGER/api/traces" --data-urlencode service=waypoint.lab-environment \
          --data-urlencode "operation=visits-service-pr-$n.lab-environment.svc.cluster.local:8082/*" \
          --data-urlencode "start=${WINDOW_START}000000" --data-urlencode "end=${SETTLED_AT}000000" --data-urlencode limit=20 \
        | jq -r '[.data[] | select([.processes[].serviceName] | index("customers-service"))][0].traceID // empty')
  svcs=$([ -n "$tid" ] && jaeger_spans "$tid" || echo "no trace")
  ok=0; grep -q 'customers-service' <<< "$svcs" && grep -q 'visits-service' <<< "$svcs" && ok=1
  rec_if app "a trace through the lane's waypoint route spans customers -> visits: $svcs" [ $ok = 1 ]
}

# The page closes the PR first; this waits for ArgoCD to remove the lane.
reset_pr_lane() {
  local end=$((SECONDS + 300))
  until [ -z "$(kubectl -n "$NS" get pods -l lab.jerome/lane -o name)" ]; do
    [ $SECONDS -lt $end ] || { echo "lane pods still present after 5 min - was the PR closed or its label removed?"; return 1; }
    sleep 5
  done
}
