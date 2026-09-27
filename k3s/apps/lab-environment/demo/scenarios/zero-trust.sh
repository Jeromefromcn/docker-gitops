# 04 — mTLS, identity-based authorization, actuator lockdown.
evidence_zero_trust() {
  local n denied rej lines l src
  settle
  n=$(loki_count '{service="istio-proxy"} | json | __error__="" | response_code="403"' "$WINDOW_START" "$WINDOW_END")
  rec_if envoy "403s logged at ingress/waypoint: $n (want >= 2: wrong caller, actuator)" [ "$n" -ge 2 ]
  denied=$(prom "sum(increase(envoy_http_rbac{authz_enforce_result=\"denied\"}[${SETTLED_RANGE}s]))" "$SETTLED_AT")
  rec_if envoy "Envoy RBAC enforce denials: $denied (want > 0)" awk "BEGIN { exit !(\"$denied\" != \"none\" && $denied + 0 > 0) }"
  # Curl's exit code cannot tell these apart (the client-side ztunnel may
  # accept the TCP connect before the server side rejects it); the log can.
  lines=$(kubectl -n istio-system logs -l app=ztunnel --tail=-1 --since-time="$(iso "$WINDOW_START")" | grep 'policy rejection' || true)
  while read -r l; do
    [ -n "$l" ] || continue
    src=$(grep -oP 'src\.workload="?\K[^ "]+' <<< "$l" || grep -oP 'src\.addr=\K[^ ]+' <<< "$l")
    echo "      $src -> $(grep -oP 'dst\.service="\K[^"]+' <<< "$l")"
  done <<< "$lines"
  rej=$(echo "$lines" | grep -c . || true)
  rec_if ztunnel "ztunnel L4 policy rejections: $rej (want >= 3: plaintext from outside, pod-IP bypass, postgres)" [ "$rej" -ge 3 ]
}

reset_zero_trust() {
  kubectl -n default delete pod mtls-probe --ignore-not-found
}
