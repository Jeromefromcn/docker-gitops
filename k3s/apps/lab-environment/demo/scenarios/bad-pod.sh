# 14 — one bad pod: outlier detection ejects it, and the retry policy sends
# its failed attempts to another pod, so no user sees the 503s.
evidence_bad_pod() {
  local ej retried failed bad own
  settle
  ej=$(prom "max_over_time(max(envoy_cluster_outlier_detection_ejections_active{job=\"envoy-stats\", cluster_name=~\".*http/stable.*customers-service.*\"})[${SETTLED_RANGE}s:15s])" "$SETTLED_AT")
  rec_if envoy "customers-service hosts ejected at once, peak: $ej (want >= 1)" \
    awk "BEGIN { exit !(\"$ej\" != \"none\" && $ej + 0 >= 1) }"
  retried=$(loki_count "$CUST_SEL | attempts > 1" "$WINDOW_START" "$WINDOW_END")
  failed=$(loki_count "$CUST_SEL | response_code != \"200\"" "$WINDOW_START" "$WINDOW_END")
  rec_if envoy "requests retried onto another pod: $retried (want > 0); customers requests that still failed: $failed (want 0)" \
    [ "$retried" -gt 0 -a "$failed" -eq 0 ]
  bad=$(cat "$STATE_DIR/bad-pod.name")
  own=$(prom_delta "http_server_requests_seconds_count{pod=\"$bad\", status=\"503\"}")
  rec_if app "the bad pod ($bad) answered $own requests with 503 itself (want >= 5)" [ "$own" -ge 5 ]
}

reset_bad_pod() {
  curl -sf -X PUT -d false "$CONSUL/v1/kv/chaos/customers-service/fail-instance" >/dev/null
  sleep 10   # the fork's ChaosToggleWatcher polls every 5 s
}
