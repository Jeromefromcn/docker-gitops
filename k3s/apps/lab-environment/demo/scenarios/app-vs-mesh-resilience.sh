# 05 — the same Redis timeout seen through Envoy's timeouts and the
# gateway's Resilience4j circuit breaker.
evidence_app_vs_mesh_resilience() {
  local ut cust vis ok cb trace
  settle
  ut=$(loki_by upstream_cluster '{service="istio-proxy"} | json | __error__="" | response_flags="UT"' "$WINDOW_START" "$WINDOW_END")
  echo "$ut" | sed 's/^/      /'
  cust=$(echo "$ut" | grep -c 'customers-service' || true)
  vis=$(echo "$ut" | grep -c 'visits-service' || true)
  ok=0; [ "$cust" -ge 1 ] && [ "$vis" -ge 1 ] && ok=1
  rec_if envoy "UT logged against both customers-service and visits-service (the reporting hop is not only the faulty one)" [ $ok = 1 ]
  cb=$(prom "sum(increase(resilience4j_circuitbreaker_calls_seconds_count{service=\"api-gateway\", kind!=\"successful\"}[${SETTLED_RANGE}s]))" "$SETTLED_AT")
  rec_if app "api-gateway circuit-breaker non-successful calls: $cb (want > 0)" awk "BEGIN { exit !(\"$cb\" != \"none\" && $cb + 0 > 0) }"
  trace=$(curl -sf -G "$JAEGER/api/traces" --data-urlencode service=api-gateway \
    --data-urlencode "start=${WINDOW_START}000000" --data-urlencode "end=${WINDOW_END}000000" \
    --data-urlencode minDuration=900ms --data-urlencode limit=1 | jq -r '.data[0].traceID // empty')
  rec_if app "slow api-gateway trace in Jaeger: ${trace:-none}" [ -n "$trace" ]
  if [ -n "$trace" ]; then note "$(jaeger_spans "$trace")"; fi
}

reset_app_vs_mesh_resilience() {
  local i slow=0 r
  curl -sf -X PUT -d false "$CONSUL/v1/kv/chaos/visits-service/redis-timeout" >/dev/null
  sleep 10   # the fork's ChaosToggleWatcher polls every 5 s
  for i in $(seq 1 10); do
    r=$(curl -s -o /dev/null -w '%{http_code} %{time_total}' "$INGRESS/api/customer/owners/6/visits")
    case $r in "200 0."*) ;; *) slow=$((slow + 1)) ;; esac
  done
  [ $slow -eq 0 ] || { echo "visits path still degraded after reset: $slow/10 slow or failed"; return 1; }
}
