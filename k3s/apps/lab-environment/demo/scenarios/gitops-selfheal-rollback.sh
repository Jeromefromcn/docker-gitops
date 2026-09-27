# 07 — selfHeal undoes a manual change; git revert is the rollback.
evidence_gitops_selfheal_rollback() {
  local ev ok revert deployed live gitrev want
  ev=$(kubectl -n "$NS" get events --field-selector involvedObject.name=customers-service,reason=ScalingReplicaSet -o json \
    | jq -r --arg s "$(iso "$WINDOW_START")" '.items[] | select((.lastTimestamp // .eventTime) >= $s) | .message')
  echo "$ev" | sed 's/^/      /'
  want=$(git_replicas customers-service)
  ok=0; echo "$ev" | grep -qE "Scaled down .* from $want to 1\$" && echo "$ev" | grep -qE "Scaled up .* from 1 to $want\$" && ok=1
  rec_if kubernetes "manual scale to 1, then restored to $want by ArgoCD selfHeal" [ $ok = 1 ]
  revert=$(git -C "$REPO_ROOT" log -1 --grep='^Revert "demo: rolling-restart customers-service"$' --format=%H)
  deployed=$(argocd app get lab-environment --core -o json \
    | jq -r --arg s "$(iso "$WINDOW_START")" '[.status.history[] | select(.deployedAt >= $s) | .revision] | join(" ")')
  ok=0; [ -n "$revert" ] && [[ " $deployed " == *" $revert "* ]] && ok=1
  rec_if argocd "ArgoCD deployed the revert ${revert:0:7} inside the window" [ $ok = 1 ]
  live=$(kubectl -n "$NS" get deploy customers-service -o jsonpath='{.spec.template.metadata.annotations.lab\.jerome/rollout-rev}')
  gitrev=$(grep -oP 'lab.jerome/rollout-rev: "\K[0-9]+' "$LAB_K8S/customers-service.yaml")
  rec_if kubernetes "live rollout-rev $live equals git's $gitrev after the revert" [ "$live" = "$gitrev" ]
}

reset_gitops_selfheal_rollback() {
  kubectl -n "$NS" rollout status deploy/customers-service --timeout=6m
}
