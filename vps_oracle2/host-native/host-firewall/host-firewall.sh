#!/usr/bin/env bash
# host-firewall.sh — the single source of truth for hand-written host firewall
# rules on vps-oracle2. Applied idempotently at boot by host-firewall.service;
# safe to re-run any time.
#
# Same shape as vps_oracle/host-native/host-firewall/ (read its README for the
# 2026-08-16 incident behind it): Docker / k3s / Cilium / tailscale rebuild
# their own chains at daemon start, so only hand-written rules are persisted,
# and they live HERE, never as an `iptables-save` dump.
#
# RED LINE: never run `iptables-save > /etc/iptables/rules.v4` or
# `netfilter-persistent save` on this host. netfilter-persistent is disabled
# (2026-09-29); /etc/iptables/rules.v4 is kept only as a frozen static backup
# of the OCI image default it used to load.
#
# Rule inventory:
#   - OCI image default: INPUT allow-list (22) + default-REJECT, FORWARD
#     default-REJECT, InstanceServices chain (metadata/iSCSI/NTP)
#   - pod CIDR → kubelet 10250 (2026-09-29): the lab Prometheus scrapes this
#     node's kubelet /metrics/cadvisor directly, so its ClusterRole needs only
#     `nodes/metrics` instead of `nodes/proxy`. Same rule vps_oracle has had
#     since 2026-08-05 (k3s/README.md "host firewall blocked pod traffic").
# Tailscale's own ts-input/ts-forward chains admit everything arriving on
# tailscale0; they are tailscaled's, not listed here.
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
ipt INPUT -s 10.42.0.0/16 -p tcp -m tcp --dport 10250 -j ACCEPT    # kubelet metrics (pods, 2026-09-29)
iptables -A INPUT -j REJECT --reject-with icmp-host-prohibited

# --- FORWARD default-REJECT (OCI image default), also kept LAST ------------
while iptables -C FORWARD -j REJECT --reject-with icmp-host-prohibited 2>/dev/null; do
  iptables -D FORWARD -j REJECT --reject-with icmp-host-prohibited
done
iptables -A FORWARD -j REJECT --reject-with icmp-host-prohibited

# --- OCI InstanceServices (image default: instance metadata, iSCSI, NTP) ---
# This chain is ours alone, so it is rebuilt from scratch: the image's copies
# carry `-m comment` and would never match an `iptables -C` check.
iptables -N InstanceServices 2>/dev/null || true
iptables -F InstanceServices
ipt OUTPUT -d 169.254.0.0/16 -j InstanceServices
iptables -A InstanceServices -d 169.254.0.2/32  -p tcp -m owner --uid-owner 0 -m tcp --dport 3260 -j ACCEPT
iptables -A InstanceServices -d 169.254.2.0/24  -p tcp -m owner --uid-owner 0 -m tcp --dport 3260 -j ACCEPT
iptables -A InstanceServices -d 169.254.4.0/24  -p tcp -m owner --uid-owner 0 -m tcp --dport 3260 -j ACCEPT
iptables -A InstanceServices -d 169.254.5.0/24  -p tcp -m owner --uid-owner 0 -m tcp --dport 3260 -j ACCEPT
iptables -A InstanceServices -d 169.254.0.2/32  -p tcp -m tcp --dport 80 -j ACCEPT
iptables -A InstanceServices -d 169.254.169.254/32 -p udp -m udp --dport 53 -j ACCEPT
iptables -A InstanceServices -d 169.254.169.254/32 -p tcp -m tcp --dport 53 -j ACCEPT
iptables -A InstanceServices -d 169.254.0.3/32  -p tcp -m owner --uid-owner 0 -m tcp --dport 80 -j ACCEPT
iptables -A InstanceServices -d 169.254.0.4/32  -p tcp -m tcp --dport 80 -j ACCEPT
iptables -A InstanceServices -d 169.254.169.254/32 -p tcp -m tcp --dport 80 -j ACCEPT
iptables -A InstanceServices -d 169.254.169.254/32 -p udp -m udp --dport 67 -j ACCEPT
iptables -A InstanceServices -d 169.254.169.254/32 -p udp -m udp --dport 69 -j ACCEPT
iptables -A InstanceServices -d 169.254.169.254/32 -p udp -m udp --dport 123 -j ACCEPT
iptables -A InstanceServices -d 169.254.0.0/16  -p tcp -m tcp -j REJECT --reject-with tcp-reset
iptables -A InstanceServices -d 169.254.0.0/16  -p udp -m udp -j REJECT --reject-with icmp-port-unreachable

echo "host-firewall: rules applied (idempotent)"
