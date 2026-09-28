# 09 — canary by instance ratio: with no subset pin the waypoint balances
# over every customers-service pod, so the canary gets 1 of 6.
evidence_canary_instance_ratio() {
  local ips hosts total canary share all c
  settle
  ips=" $(kubectl -n "$NS" get pods -l app=customers-service,track=canary -o jsonpath='{.items[*].status.podIP}') "
  hosts=$(loki_by upstream_host "$CUST_SEL" "$WINDOW_START" "$WINDOW_END")
  total=$(echo "$hosts" | awk '{ s += $1 } END { print s + 0 }')
  canary=$(echo "$hosts" | awk -v ips="$ips" '{ n = split($2, a, "/"); split(a[n], b, ":"); if (index(ips, " " b[1] " ")) s += $1 } END { print s + 0 }')
  share=$(pct "$canary" "$total")
  rec_if envoy "waypoint sent $canary of $total customers-service requests to the canary pod: ${share}% (want 8-30; 1 pod of 6)" in_band "$share" 8 30
  all=$(prom_delta 'http_server_requests_seconds_count{service="customers-service", uri!~"/actuator.*"}')
  c=$(prom_delta 'http_server_requests_seconds_count{pod=~"customers-service-canary-.*", uri!~"/actuator.*"}')
  share=$(pct "$c" "$all")
  rec_if app "canary pod's own count: $c of $all requests, ${share}% (want 8-30)" in_band "$share" 8 30
}

reset_canary_instance_ratio() {
  wait_canary_gone 3m
}
