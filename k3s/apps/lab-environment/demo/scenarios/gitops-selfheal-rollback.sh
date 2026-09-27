# 07 — selfHeal undoes a manual change; git revert is the rollback.
evidence_gitops_selfheal_rollback() {
  local range=$(( WINDOW_END - WINDOW_START )) want minavail heal rev ok revert deployed live gitrev
  want=$(git_replicas customers-service)
  # Not ScalingReplicaSet events: the API server folds repeats into one
  # "(combined from similar events)" object, losing the scale-down message.
  # KSM keeps the dip — readiness takes ~70 s, so a 15 s scrape cannot miss it.
  minavail=$(prom "min_over_time(kube_deployment_status_replicas_available{namespace=\"$NS\", deployment=\"customers-service\"}[${range}s])" "$WINDOW_END")
  rec_if kubernetes "available customers-service replicas dipped to $minavail during the window (manual scale to 1)" [ "$minavail" = 1 ]
  # selfHeal is a sync limited to the drifted resource, at whatever revision
  # is current (not necessarily 02's — another commit may have landed).
  # ArgoCD's history does not record it; the controller log does. A full
  # sync (the revert) lists no resources, so it cannot match.
  heal=$(kubectl -n argocd logs statefulset/argocd-application-controller --since-time="$(iso "$WINDOW_START")" \
    | grep 'Initialized new operation' \
    | grep -m1 'SyncOperationResource{Group:apps,Kind:Deployment,Name:customers-service,' || true)
  rev=$(grep -oP 'Revision:\K[0-9a-f]+' <<< "$heal" || true)
  rec_if argocd "selfHeal synced only Deployment/customers-service (at ${rev:0:7}) at $(grep -oP 'time="\K[^"]+' <<< "$heal" || echo never)" [ -n "$heal" ]
  revert=$(git -C "$REPO_ROOT" log -1 --grep='^Revert "demo: rolling-restart customers-service"$' --format=%H)
  deployed=$(argocd app get lab-environment --core -o json \
    | jq -r --arg s "$(iso "$WINDOW_START")" '[.status.history[] | select(.deployedAt >= $s) | .revision] | join(" ")')
  ok=0; [ -n "$revert" ] && [[ " $deployed " == *" $revert "* ]] && ok=1
  rec_if argocd "ArgoCD deployed the revert ${revert:0:7} inside the window" [ $ok = 1 ]
  live=$(kubectl -n "$NS" get deploy customers-service -o jsonpath='{.spec.template.metadata.annotations.lab\.jerome/rollout-rev} {.status.readyReplicas}')
  gitrev=$(grep -oP 'lab.jerome/rollout-rev: "\K[0-9]+' "$LAB_K8S/customers-service.yaml")
  rec_if kubernetes "live rollout-rev/ready '$live' equals git's '$gitrev $want' after the revert" [ "$live" = "$gitrev $want" ]
}

reset_gitops_selfheal_rollback() {
  kubectl -n "$NS" rollout status deploy/customers-service --timeout=6m
}
