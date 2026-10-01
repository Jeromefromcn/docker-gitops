# 01 — per-request load balancing across the customers-service replicas.
# Counts its own 100 requests, so the background generator is paused from the start until
# demo-reset (or 15 minutes, whichever comes first).
prepare_load_balancing() { pause_generator; }
reset_load_balancing() { resume_generator; }

evidence_load_balancing() {
  local want hosts pods n
  want=$(git_replicas customers-service)
  settle
  hosts=$(loki_by upstream_host '{service="istio-proxy"} | json | __error__="" | authority=~"customers-service.*"' "$WINDOW_START" "$WINDOW_END")
  echo "$hosts" | sed 's/^/      /'
  n=$(echo "$hosts" | grep -c . || true)
  rec_if envoy "waypoint spread customers-service requests over $n pods (want $want)" [ "$n" -eq "$want" ]
  pods=$(prom_vector pod "sum by (pod) (increase(http_server_requests_seconds_count{service=\"customers-service\", uri!~\"/actuator.*\"}[${SETTLED_RANGE}s]))" "$SETTLED_AT")
  echo "$pods" | sed 's/^/      /'
  n=$(echo "$pods" | awk '$1 > 0' | grep -c . || true)
  rec_if app "customers-service pods that served requests: $n (want $want)" [ "$n" -eq "$want" ]
}
