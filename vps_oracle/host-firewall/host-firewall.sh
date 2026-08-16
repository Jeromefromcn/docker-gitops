#!/usr/bin/env bash
# host-firewall.sh — the single source of truth for hand-written host firewall
# rules on this box. Applied idempotently at boot by host-firewall.service;
# safe to re-run any time.
#
# Why this exists (incident 2026-08-16): /etc/iptables/rules.v4 had been
# "persisted" with full `iptables-save` snapshots taken while Docker was
# running. netfilter-persistent replayed the snapshot at every boot,
# resurrecting Docker's per-IP rules for bridges that no longer existed; when
# a recreated compose network reused subnet 172.18.0.0/16 the ghost rules
# blackholed all container-to-container traffic (api-server crash-looped on
# DB connect timeout). Docker / k3s / Cilium rebuild their own chains at
# daemon start — only hand-written rules need persistence, and they live HERE,
# version-controlled, never as a kernel dump.
#
# RED LINE: never run `iptables-save > /etc/iptables/rules.v4` or
# `netfilter-persistent save` on this host. netfilter-persistent is disabled;
# /etc/iptables/rules.v4 is kept only as a frozen static backup.
#
# Rule inventory (mirrors what was live 2026-08-16):
#   - OCI image default INPUT allow-list + default-REJECT, InstanceServices
#     chain (metadata/iSCSI protections, image default)
#   - 443/80 for the NPM reverse proxy (2026-07-26 migration)
#   - pod CIDR → host ports 6443/4244/10250 (2026-08-05/06 Cilium fix,
#     see k3s/README.md "host firewall blocked pod traffic")
#   - DOCKER-USER drop: external iface → published 3001/9090/8080
#     (Grafana/Prometheus/Nginx must not be reachable from the internet)
set -euo pipefail
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then echo "must run as root" >&2; exit 1; fi

ipt() { # ipt <chain> <spec...> — append unless an identical rule exists
  local chain=$1; shift
  iptables -C "$chain" "$@" 2>/dev/null || iptables -A "$chain" "$@"
}

# --- INPUT allow-list; default-REJECT stays LAST (remove first, re-add last)
while iptables -C INPUT -j REJECT --reject-with icmp-host-prohibited 2>/dev/null; do
  iptables -D INPUT -j REJECT --reject-with icmp-host-prohibited
done
ipt INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
ipt INPUT -p icmp -j ACCEPT
ipt INPUT -i lo -j ACCEPT
ipt INPUT -p tcp -m state --state NEW -m tcp --dport 22 -j ACCEPT  # SSH
ipt INPUT -p tcp -m tcp --dport 443 -j ACCEPT                      # NPM proxy
ipt INPUT -p tcp -m tcp --dport 80 -j ACCEPT                       # NPM cert renew (HTTP-01) + redirect
ipt INPUT -s 10.42.0.0/16 -p tcp -m tcp --dport 6443 -j ACCEPT     # kube-apiserver (pods)
ipt INPUT -s 10.42.0.0/16 -p tcp -m tcp --dport 4244 -j ACCEPT     # cilium hubble-peer (pods)
ipt INPUT -s 10.42.0.0/16 -p tcp -m tcp --dport 10250 -j ACCEPT    # kubelet metrics (pods)
iptables -A INPUT -j REJECT --reject-with icmp-host-prohibited

# --- OCI InstanceServices (image default: instance metadata, iSCSI, NTP) ---
iptables -N InstanceServices 2>/dev/null || true
ipt OUTPUT -d 169.254.0.0/16 -j InstanceServices
ipt InstanceServices -d 169.254.0.2/32  -p tcp -m owner --uid-owner 0 -m tcp --dport 3260 -j ACCEPT
ipt InstanceServices -d 169.254.2.0/24  -p tcp -m owner --uid-owner 0 -m tcp --dport 3260 -j ACCEPT
ipt InstanceServices -d 169.254.4.0/24  -p tcp -m owner --uid-owner 0 -m tcp --dport 3260 -j ACCEPT
ipt InstanceServices -d 169.254.5.0/24  -p tcp -m owner --uid-owner 0 -m tcp --dport 3260 -j ACCEPT
ipt InstanceServices -d 169.254.0.2/32  -p tcp -m tcp --dport 80 -j ACCEPT
ipt InstanceServices -d 169.254.169.254/32 -p udp -m udp --dport 53 -j ACCEPT
ipt InstanceServices -d 169.254.169.254/32 -p tcp -m tcp --dport 53 -j ACCEPT
ipt InstanceServices -d 169.254.0.3/32  -p tcp -m owner --uid-owner 0 -m tcp --dport 80 -j ACCEPT
ipt InstanceServices -d 169.254.0.4/32  -p tcp -m owner --uid-owner 0 -m tcp --dport 80 -j ACCEPT
ipt InstanceServices -d 169.254.169.254/32 -p tcp -m tcp --dport 80 -j ACCEPT
ipt InstanceServices -d 169.254.169.254/32 -p udp -m udp --dport 67 -j ACCEPT
ipt InstanceServices -d 169.254.169.254/32 -p udp -m udp --dport 69 -j ACCEPT
ipt InstanceServices -d 169.254.169.254/32 -p udp -m udp --dport 123 -j ACCEPT
ipt InstanceServices -d 169.254.0.0/16  -p tcp -m tcp -j REJECT --reject-with tcp-reset
ipt InstanceServices -d 169.254.0.0/16  -p udp -m udp -j REJECT --reject-with icmp-port-unreachable

# --- DOCKER-USER hardening (docker never flushes this chain) ----------------
iptables -N DOCKER-USER 2>/dev/null || true
if ! iptables -C DOCKER-USER -i enp0s6 -p tcp -m multiport --dports 3001,9090,8080 -j DROP 2>/dev/null; then
  iptables -I DOCKER-USER 1 -i enp0s6 -p tcp -m multiport --dports 3001,9090,8080 -j DROP
fi

echo "host-firewall: rules applied (idempotent)"
