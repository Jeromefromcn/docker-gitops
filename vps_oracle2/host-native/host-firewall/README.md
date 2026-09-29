# host-firewall — hand-written host firewall rules for vps-oracle2

Same convention as [`vps_oracle/host-native/host-firewall/`](../../../vps_oracle/host-native/host-firewall/README.md) — read its README for why (incident 2026-08-16: `netfilter-persistent` replaying an `iptables-save` snapshot resurrected dead Docker rules). Docker / k3s / Cilium / tailscale rebuild their own chains at daemon start; only hand-written rules are persisted, in `host-firewall.sh`, applied at boot by `host-firewall.service`.

Until 2026-09-29 this host ran `netfilter-persistent` with the untouched OCI image `rules.v4`. It was switched to this script when the first hand-written rule was needed; `netfilter-persistent` is now **disabled** and `/etc/iptables/rules.v4` stays on disk only as a frozen backup of the image default. The live rules before the switch were saved to `/root/iptables-before-host-firewall-20260929.v4`.

## RED LINE

Never run on this host: `iptables-save > /etc/iptables/rules.v4`, `netfilter-persistent save`, `service iptables save`.

## Rule inventory

| Rules | Origin |
|---|---|
| INPUT allow-list (22) + default-REJECT + base (lo/icmp/established); FORWARD default-REJECT | OCI image default |
| `InstanceServices` chain + OUTPUT jump | OCI image default (metadata/iSCSI/NTP) |
| `10.42.0.0/16 → 10250` | 2026-09-29: the lab Prometheus scrapes this node's kubelet `/metrics/cadvisor` directly, so it needs only `nodes/metrics` instead of `nodes/proxy` (which kubelet also accepts for websocket exec). Without it pods get `No route to host` (the REJECT's `icmp-host-prohibited`) |

Everything arriving on `tailscale0` is admitted earlier by tailscaled's own `ts-input` chain, which is why nothing tailscale-facing is listed here.

## Install / change

The repo has no clone on this host, so push the files from vps_oracle:

```bash
scp host-firewall.sh host-firewall.service vps-oracle2:/tmp/
ssh vps-oracle2 'sudo install -m 0755 /tmp/host-firewall.sh /usr/local/sbin/host-firewall.sh &&
  sudo install -m 0644 /tmp/host-firewall.service /etc/systemd/system/host-firewall.service &&
  sudo systemctl daemon-reload && sudo systemctl enable host-firewall.service &&
  sudo /usr/local/sbin/host-firewall.sh'
```

The script is idempotent: `INPUT`/`FORWARD` rules are appended only if missing with the default-REJECT moved back to the end, and the `InstanceServices` chain is flushed and rebuilt.

## Verify

```bash
ssh vps-oracle2 'systemctl is-enabled host-firewall netfilter-persistent'   # enabled / disabled
ssh vps-oracle2 'sudo iptables -S INPUT | grep -cE "dport (22|10250)"'     # expect 2
kubectl -n lab-environment exec deploy/prometheus -- wget -q -T5 -O /dev/null --no-check-certificate https://100.100.140.33:10250/healthz
# expect "401 Unauthorized" (reachable, no token sent), not "Connection reset by peer"
```
