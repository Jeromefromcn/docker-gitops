# 16 — rate limiting at the waypoint: a burst to /api/vet/vets is cut to the
# resident limit; vets-service itself only sees what was admitted.
SENT=60   # the page sends exactly these

evidence_rate_limit() {
  local per total own gtotal gbad
  settle
  per=$(loki_by pod_name '{service="istio-proxy", response_code="429"} | json | __error__="" | authority=~"vets-service.*"' "$WINDOW_START" "$WINDOW_END")
  echo "$per" | awk '{ printf "      %s %s\n", $2, $1 }'
  total=$(echo "$per" | awk '{ s += $1 } END { print s + 0 }')
  rec_if envoy "429 from the waypoint's Lua limiter: $total of the $SENT sent (want > 0), per replica above" [ "$total" -gt 0 ]
  own=$(prom_delta 'http_server_requests_seconds_count{service="vets-service", uri!~"/actuator.*"}')
  gtotal=$(loki_count '{service="traffic-generator"}' "$WINDOW_START" "$WINDOW_END")
  gbad=$(loki_count '{service="traffic-generator"} !~ " 200 "' "$WINDOW_START" "$WINDOW_END")
  rec_if app "vets-service counted $own requests itself (want < $SENT - the limited ones never arrived); generator $gbad non-200 of $gtotal (want 0)" \
    [ "$own" -lt "$SENT" -a "$gbad" -eq 0 -a "$gtotal" -gt 0 ]
}
