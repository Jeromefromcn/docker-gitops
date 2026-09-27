# 01 — per-request load balancing across the customers-service replicas.
evidence_load_balancing() {
  local want hosts pods n t range
  want=$(git_replicas customers-service)
  # Prometheus scrapes every 15 s and promtail ships with a lag: read both
  # 20 s past the window's end, over at least 60 s so increase() has samples.
  t=$(( WINDOW_END + 20 ))
  while [ "$(date +%s)" -lt "$t" ]; do sleep 2; done
  range=$(( t - WINDOW_START )); [ "$range" -ge 60 ] || range=60
  hosts=$(loki_by upstream_host '{service="istio-proxy"} | json | __error__="" | authority=~"customers-service.*"' "$WINDOW_START" "$WINDOW_END")
  echo "$hosts" | sed 's/^/      /'
  n=$(echo "$hosts" | grep -c . || true)
  rec_if envoy "waypoint spread customers-service requests over $n pods (want $want)" [ "$n" -eq "$want" ]
  pods=$(prom_vector pod "sum by (pod) (increase(http_server_requests_seconds_count{service=\"customers-service\", uri!~\"/actuator.*\"}[${range}s]))" "$t")
  echo "$pods" | sed 's/^/      /'
  n=$(echo "$pods" | awk '$1 > 0' | grep -c . || true)
  rec_if app "customers-service pods that served requests: $n (want $want)" [ "$n" -eq "$want" ]
}
