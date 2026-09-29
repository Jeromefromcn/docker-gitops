# 15 — header-triggered fault injection: only marked requests are delayed or
# aborted, and an abort is a local reply that never reaches a pod.
N_DELAY=10 N_ABORT=10   # the page sends exactly these

evidence_fault_injection() {
  local di ab up5 gtotal gbad
  settle
  di=$(loki_count "$CUST_SEL | response_flags=~\".*DI.*\"" "$WINDOW_START" "$WINDOW_END")
  ab=$(loki_count "$CUST_SEL | response_flags=~\".*FI.*\"" "$WINDOW_START" "$WINDOW_END")
  rec_if envoy "waypoint delayed $di (want $N_DELAY) and aborted $ab (want $N_ABORT) requests - exactly the marked ones" \
    [ "$di" -eq "$N_DELAY" -a "$ab" -eq "$N_ABORT" ]
  up5=$(prom_delta 'envoy_cluster_upstream_rq{job="envoy-stats", cluster_name=~".*customers-service.*", response_code_class="5xx"}')
  rec_if envoy "5xx answered by customers-service pods in the window: $up5 (want 0 - the $N_ABORT aborts were local replies)" [ "$up5" -eq 0 ]
  gtotal=$(loki_count '{service="traffic-generator"}' "$WINDOW_START" "$WINDOW_END")
  gbad=$(loki_count '{service="traffic-generator"} !~ " 200 "' "$WINDOW_START" "$WINDOW_END")
  rec_if app "generator: $gbad non-200 of $gtotal (want 0 of > 0)" [ "$gbad" -eq 0 -a "$gtotal" -gt 0 ]
}
