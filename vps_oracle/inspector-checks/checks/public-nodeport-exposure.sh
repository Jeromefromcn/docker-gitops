#!/usr/bin/env bash
# checks/public-nodeport-exposure.sh
#
# Detects k3s NodePorts on vps_oracle that are reachable from the public
# internet. The OCI security list (vps_oracle/tofu/network.tf) is the ONLY
# layer keeping them private: Cilium runs kube-proxy-replacement, so external
# NodePort traffic is handled in BPF before host-firewall.sh's INPUT
# default-REJECT ever sees it, and NodePort collectors (Jaeger OTLP etc.) have
# no auth of their own. This check is the second layer: a security-list edit
# (in tofu or the console) or an attached NSG that opens the range gets
# reported instead of silently exposing the cluster.
#
# Behavioural, not a config read: it probes the public IP from vps-oracle2 (a
# separate OCI tenancy, so a genuine outside vantage) and classifies each port
# by how the connect ends — timeout means dropped by OCI (good); a connect OR a
# fast refusal means the packet reached the host, i.e. the security list let
# it through. This catches every cause of exposure without needing OCI API
# credentials. A probe of public 443 must succeed first, otherwise the vantage
# itself is broken and "everything timed out" would be a false all-clear.
#
# Tier: alert — the fix is a security-list change, which needs a human.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/local.sh"

NAME="public-nodeport-exposure.sh"
PUBLIC_HOST="${INSPECTOR_PUBLIC_HOST:-jerome.cloudns.asia}"
VANTAGE="${INSPECTOR_EXPOSURE_VANTAGE_SSH_HOST:-vps-oracle2}"
PROBE_TIMEOUT="${INSPECTOR_EXPOSURE_PROBE_TIMEOUT:-4}"
KUBECONFIG_PATH="${INSPECTOR_KUBECONFIG:-$INSPECTOR_STATE_DIR/kubeconfig}"
# Range boundaries plus a spread, so a rule opening any sizeable slice of
# 30000-32767 is caught even when kubectl is unavailable.
SAMPLE_PORTS="${INSPECTOR_EXPOSURE_SAMPLE_PORTS:-30000 30500 31000 31500 32000 32500 32767}"

ip="$(getent hosts "$PUBLIC_HOST" 2>/dev/null | awk 'NR==1 {print $1}')"
if [ -z "$ip" ]; then
  emit_result "alert" "flagged" "check:$NAME" \
    "cannot resolve $PUBLIC_HOST to vps_oracle's public IP — check skipped"
  exit 0
fi

# Every allocated NodePort, so a single-port rule for exactly that service is
# caught too. Supplementary: without it the sample above still runs.
allocated=""
if [ -r "$KUBECONFIG_PATH" ]; then
  allocated="$(timeout 20 kubectl --kubeconfig "$KUBECONFIG_PATH" get svc -A \
    -o jsonpath='{range .items[*]}{range .spec.ports[*]}{.nodePort}{"\n"}{end}{end}' 2>/dev/null)" || allocated=""
fi
mapfile -t ports < <(printf '%s\n' $SAMPLE_PORTS $allocated | grep -E '^[0-9]+$' | sort -un)

# Runs on the vantage host: probe every port in parallel, print "<port> <rc>".
# rc 124 = timeout (dropped), 0 = connected, anything else = refused/rejected.
remote_script='
ip="$1"; shift
for p in "$@"; do
  ( timeout '"$PROBE_TIMEOUT"' bash -c "</dev/tcp/$ip/$p" >/dev/null 2>&1; echo "$p $?" ) &
done
wait'

out="$(timeout $((PROBE_TIMEOUT + 30)) ssh -o BatchMode=yes -o ConnectTimeout=10 \
  "$VANTAGE" bash -s -- "$ip" 443 "${ports[@]}" <<<"$remote_script" 2>/dev/null)" || {
  emit_result "alert" "flagged" "check:$NAME" \
    "cannot run the probe on $VANTAGE over SSH — public NodePort exposure unchecked"
  exit 0
}

https_rc="$(awk '$1 == "443" {print $2}' <<<"$out")"
if [ "$https_rc" != "0" ]; then
  emit_result "alert" "flagged" "check:$NAME" \
    "$VANTAGE cannot reach $ip:443 (rc=${https_rc:-none}) — probe vantage broken, result untrustworthy"
  exit 0
fi

exposed="$(awk '$1 != "443" && $2 ~ /^[0-9]+$/ && $2 != "124" {
  printf "%s%s (%s)", sep, $1, ($2 == "0" ? "open" : "reached host"); sep = ", " }' \
  <<<"$(sort -n <<<"$out")")"
[ -n "$exposed" ] || exit 0

emit_result "alert" "flagged" "public NodePorts on $ip" \
  "exposed from the internet (probed from $VANTAGE): $exposed — the OCI security list / NSG is letting 30000-32767 through; NodePorts have no auth, close it in vps_oracle/tofu/network.tf"
