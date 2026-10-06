# The lab baseline check behind demo-baseline. Sourced, not run.
# shellcheck disable=SC2034  # variables here are consumed by the sourcing script
# Runs on vps_oracle: its kubectl context plus the lab NodePorts.
set -euo pipefail

DEMO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LAB_K8S=$DEMO_DIR/../k8s
NODE=${LAB_NODE_IP:-10.0.0.95}
CONSUL=http://$NODE:30092
NS=lab-environment
BUSINESS="api-gateway customers-service vets-service visits-service"
CANARY=customers-service-canary

die() { echo "demo: $*" >&2; exit 2; }
git_replicas() { grep -m1 -E '^\s+replicas:' "$LAB_K8S/$1.yaml" | awk '{print $2}'; }
git_image() { grep -m1 -oP 'image: \K\S+' "$LAB_K8S/$1.yaml"; }

# Every routing demo returns here: slot empty and on git's image, no PR lane
# pod, every VirtualService route pinned to stable - no weights, mirror or
# header rule.
routing_baseline() {
  local bad=0 got want pods off
  got=$(kubectl -n "$NS" get deploy "$CANARY" -o jsonpath='{.spec.replicas}')
  [ "$got" = 0 ] || { echo "$CANARY spec.replicas '$got', want 0"; bad=1; }
  pods=$(kubectl -n "$NS" get pods -l app=customers-service,track=canary -o name)
  [ -z "$pods" ] || { echo "canary pods still present: $(tr "\n" " " <<< "$pods")"; bad=1; }
  # PR lanes (page 18) live in the headroom page 12's green needs: none may
  # be left behind. Closing the PR or dropping its lane: label removes it.
  # Deployments too: one stuck in FailedCreate has no pod yet, but gets one
  # as soon as its image is signed - possibly in the middle of page 12.
  pods=$(kubectl -n "$NS" get deploy,pods -l lab.jerome/lane -o name)
  [ -z "$pods" ] || { echo "lane objects still present: $(tr "\n" " " <<< "$pods")"; bad=1; }
  got=$(kubectl -n "$NS" get deploy "$CANARY" -o jsonpath='{.spec.template.spec.containers[0].image}')
  want=$(git_image "$CANARY")
  [ "$got" = "$want" ] || { echo "$CANARY image '$got', git wants $want"; bad=1; }
  if ! off=$(kubectl -n "$NS" get virtualservice customers-service -o json | jq -r '
      [.spec.http[] | [ (if .mirror or .mirrors then "mirror" else empty end),
                        (if (.route | length) != 1 then "weights" else empty end),
                        (if (.route | length) == 1 and .route[0].destination.subset != "stable"
                           then "subset \(.route[0].destination.subset // "none")" else empty end),
                        (if any(.match[]?; .headers) then "header match" else empty end),
                        (if .fault then "fault" else empty end) ]
                      | select(length > 0) | join("+")] | join(", ")'); then
    echo "customers-service VirtualService not read"; bad=1
  elif [ -n "$off" ]; then
    echo "customers-service VirtualService routes off the stable pin: $off"; bad=1
  fi
  return $bad
}

# 17 routes visits' postgres/redis through toxiproxy and lets postgres/redis
# admit toxiproxy's identity - both must be gone after the page's revert.
toxiproxy_baseline() {
  local bad=0 envs n
  envs=$(kubectl -n "$NS" get deploy visits-service -o jsonpath='{.spec.template.spec.containers[0].env[*].name}')
  case " $envs " in *" DATA_DB_HOST "*|*" DATA_REDIS_HOST "*)
    echo "visits-service still points at toxiproxy (env: $envs)"; bad=1 ;; esac
  if ! n=$(kubectl -n "$NS" get authorizationpolicy postgres-clients redis-clients -o json \
      | jq '[.items[].spec.rules[].from[].source.principals[]? | select(endswith("/sa/toxiproxy"))] | length'); then
    echo "postgres/redis authorization policies not read"; bad=1
  elif [ "$n" != 0 ]; then
    echo "postgres/redis still admit sa/toxiproxy"; bad=1
  fi
  return $bad
}

baseline_check() {
  local bad=0 on d got want st lines total non200
  # Called as an if-condition, so set -e is off here: every read checks its
  # own exit status, or an unreachable Consul would read as "no toggles on".
  if ! on=$(curl -sf "$CONSUL/v1/kv/chaos/?recurse" | jq -r '.[] | select((.Value // "" | @base64d) != "false") | .Key'); then
    echo "Consul unreachable — chaos toggles not read"; bad=1
  elif [ -n "$on" ]; then
    echo "chaos toggles still on: $on"; bad=1
  fi
  for d in $BUSINESS; do
    want=$(git_replicas "$d")
    got=$(kubectl -n "$NS" get deploy "$d" -o jsonpath='{.status.readyReplicas} {.spec.replicas}')
    [ "$got" = "$want $want" ] || { echo "$d ready/spec '$got', git wants $want"; bad=1; }
  done
  st=$(argocd app get lab-environment --core -o json | jq -r '.status.sync.status + "/" + .status.health.status')
  [ "$st" = "Synced/Healthy" ] || { echo "lab-environment is $st"; bad=1; }
  lines=$(kubectl -n "$NS" logs deploy/traffic-generator --since=30s)
  total=$(echo "$lines" | grep -c . || true)
  non200=$(echo "$lines" | awk 'NF && $2 != "200"' | grep -c . || true)
  { [ "$total" -gt 0 ] && [ "$non200" -eq 0 ]; } || { echo "generator last 30s: $total requests, $non200 non-200"; bad=1; }
  routing_baseline || bad=1
  toxiproxy_baseline || bad=1
  kubectl -n "$NS" get trafficextension vets-service-ratelimit -o name 2>/dev/null | grep -q . \
    || { echo "vets-service-ratelimit TrafficExtension missing"; bad=1; }
  return $bad
}

# Retries until the baseline holds or DEMO_BASELINE_TIMEOUT seconds pass: a
# reset that was just pushed needs a sync and a rollout to land.
wait_baseline() {
  local deadline=$(( $(date +%s) + ${DEMO_BASELINE_TIMEOUT:-180} )) out
  while :; do
    if out=$(baseline_check 2>&1); then echo "baseline OK"; return 0; fi
    if [ "$(date +%s)" -ge "$deadline" ]; then sed 's/^/  /' <<< "$out"; echo "baseline NOT restored"; return 1; fi
    sleep 10
  done
}
