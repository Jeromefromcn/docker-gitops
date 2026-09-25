#!/usr/bin/env bash
# checks/k3s-capacity-pressure.sh
#
# Reports capacity pressure in the lab namespace — the three ways a workload
# stops being able to run there: a ResourceQuota used at or above a
# percentage of its hard limit, a ReplicaSet whose pods were refused at
# admission (FailedCreate), and a pod stuck Pending past a threshold.
#
# alert tier: nothing here is safe to auto-clean. A Pending pod or a refused
# ReplicaSet is a symptom whose cause needs a human — the last time this fired
# for real (2026-09-25) the cause was a leaked-connection exhaustion that
# filled the quota, and deleting the symptom would have hidden it.
#
# Scope is deliberately the lab namespace only (INSPECTOR_LAB_NAMESPACE).
# Cluster-wide Pending pods would report namespaces that legitimately sit
# Pending — PR lanes waiting for capacity — and a check that cries wolf
# twice a day gets ignored. Widen it only with a namespace allow-list.
#
# Why this exists: the 2026-09-25 incident was invisible until pods began
# CrashLoopBackOff, ~10 minutes after the sync had already stalled. Every
# signal below was present the whole time.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

KUBECONFIG_FILE="${INSPECTOR_KUBECONFIG:-$INSPECTOR_STATE_DIR/kubeconfig}"
NS="${INSPECTOR_LAB_NAMESPACE:-lab-environment}"
QUOTA_PCT="${INSPECTOR_QUOTA_USED_PCT:-90}"
PENDING_MIN="${INSPECTOR_PENDING_MINUTES:-5}"
FAILEDCREATE_MIN="${INSPECTOR_FAILEDCREATE_MINUTES:-2}"
CHECK="check:k3s-capacity-pressure.sh"

if [ ! -f "$KUBECONFIG_FILE" ]; then
  emit_result "alert" "flagged" "$CHECK" \
    "inspector kubeconfig missing at $KUBECONFIG_FILE — run k3s/setup-kubeconfig.sh once (see README)"
  exit 0
fi

kc() { kubectl --kubeconfig "$KUBECONFIG_FILE" "$@"; }

# Kubernetes quantities -> an integer in the resource's base unit (millicores
# for cpu, bytes for memory, a plain count otherwise). Only the suffixes that
# actually appear in quota hard/used are handled; a form that slips through
# yields 0, which fails safe by not flagging.
quantity_units() {
  local q="$1" kind="$2"
  case "$kind" in
    cpu)
      case "$q" in
        *n) echo $(( ${q%n} / 1000000 )) ;;
        *u) echo $(( ${q%u} / 1000 )) ;;
        *m) echo "${q%m}" ;;
        *)  echo $(( ${q%.*} * 1000 )) ;;
      esac ;;
    *)
      case "$q" in
        *Ki) echo $(( ${q%Ki} * 1024 )) ;;
        *Mi) echo $(( ${q%Mi} * 1024 * 1024 )) ;;
        *Gi) echo $(( ${q%Gi} * 1024 * 1024 * 1024 )) ;;
        *Ti) echo $(( ${q%Ti} * 1024 * 1024 * 1024 * 1024 )) ;;
        *K)  echo $(( ${q%K} * 1000 )) ;;
        *M)  echo $(( ${q%M} * 1000 * 1000 )) ;;
        *G)  echo $(( ${q%G} * 1000 * 1000 * 1000 )) ;;
        *)   echo $(( ${q%.*} )) ;;
      esac ;;
  esac
}

# 0 when the timestamp is absent or unparseable — an unknown age must not
# produce a flag, so a degraded object stays quiet rather than noisy.
age_minutes() {
  local ts="$1" then
  case "$ts" in ""|null) echo 0; return ;; esac
  then="$(date -u -d "$ts" +%s 2>/dev/null)" || { echo 0; return; }
  echo $(( ( $(date -u +%s) - then ) / 60 ))
}

kind_for() {  # quota resource key -> base unit
  case "$1" in
    *cpu)    echo cpu ;;
    *memory) echo memory ;;
    *)       echo count ;;
  esac
}

# A failed fetch and a Forbidden fetch are different problems and must not
# report the same sentence: the first says "the cluster is unreachable", the
# second says "the inspector's own RBAC is missing a grant" — and the second
# is what actually happened when this check was first run.
FETCH_JSON=""
FETCH_ERR=""
try_fetch() {
  local raw
  raw="$(kc get "$1" -n "$NS" -o json 2>&1)"
  if printf '%s' "$raw" | jq -e '.items' >/dev/null 2>&1; then
    FETCH_JSON="$raw"
  else
    FETCH_JSON=""
    [ -n "$FETCH_ERR" ] || FETCH_ERR="$(printf '%s' "$raw" | tr '\n' ' ' | cut -c1-160)"
  fi
}

try_fetch resourcequota; quotas_json="$FETCH_JSON"
try_fetch replicasets; rs_json="$FETCH_JSON"
try_fetch pods; pods_json="$FETCH_JSON"

if [ -z "$quotas_json" ] || [ -z "$rs_json" ] || [ -z "$pods_json" ]; then
  case "$FETCH_ERR" in
    *[Ff]orbidden*)
      emit_result "alert" "flagged" "$CHECK" \
        "inspector RBAC does not permit reading a resource this check needs in namespace $NS — grant resourcequotas/replicasets get+list in k3s/rbac.yaml and re-run k3s/setup-kubeconfig.sh ($FETCH_ERR)"
      ;;
    *)
      emit_result "alert" "flagged" "$CHECK" \
        "kubernetes API not reachable via inspector kubeconfig (namespace $NS): ${FETCH_ERR:-no response} — check skipped"
      ;;
  esac
  exit 0
fi

# --- 1. quota headroom -------------------------------------------------------
while IFS=$'\t' read -r qname key hard used; do
  [ -n "$key" ] || continue
  kind="$(kind_for "$key")"
  hard_u="$(quantity_units "$hard" "$kind")"
  used_u="$(quantity_units "$used" "$kind")"
  [ "$hard_u" -gt 0 ] 2>/dev/null || continue
  pct=$(( used_u * 100 / hard_u ))
  if [ "$pct" -ge "$QUOTA_PCT" ]; then
    emit_result "alert" "flagged" "quota $NS/$qname" \
      "$key ${pct}% of hard limit (used $used of $hard, threshold ${QUOTA_PCT}%)"
  fi
done < <(jq -r '.items[]? |
  (.metadata.name) as $n |
  (.status.hard // {}) as $h |
  (.status.used // {}) as $u |
  ($h | keys[]) as $k |
  "\($n)\t\($k)\t\($h[$k])\t\($u[$k] // "0")"' <<<"$quotas_json" 2>/dev/null)

# --- 2. admission-refused ReplicaSets ---------------------------------------
while IFS=$'\t' read -r rsname created msg; do
  [ -n "$rsname" ] || continue
  mins="$(age_minutes "$created")"
  if [ "$mins" -ge "$FAILEDCREATE_MIN" ]; then
    emit_result "alert" "flagged" "replicaset $NS/$rsname" \
      "FailedCreate for ${mins}min — $msg"
  fi
done < <(jq -r '.items[]? |
  select((.status.conditions // []) | any(.type == "ReplicaFailure" and .status == "True")) |
  "\(.metadata.name)\t\(.metadata.creationTimestamp // "")\t\(((.status.conditions // []) | map(select(.type == "ReplicaFailure")) | .[0].message // "no message") | gsub("[\n\t]"; " "))"' <<<"$rs_json" 2>/dev/null)

# --- 3. pods stuck Pending ---------------------------------------------------
while IFS=$'\t' read -r podname created msg; do
  [ -n "$podname" ] || continue
  mins="$(age_minutes "$created")"
  if [ "$mins" -ge "$PENDING_MIN" ]; then
    emit_result "alert" "flagged" "pod $NS/$podname" \
      "Pending for ${mins}min — $msg"
  fi
done < <(jq -r '.items[]? |
  select(.status.phase == "Pending") |
  "\(.metadata.name)\t\(.metadata.creationTimestamp // "")\t\(((.status.conditions // []) | map(select(.type == "PodScheduled")) | .[0].message // "not scheduled yet") | gsub("[\n\t]"; " "))"' <<<"$pods_json" 2>/dev/null)
