# host-firewall — hand-written host firewall rules (single source of truth)

## Why this exists

Incident 2026-08-16: `api-server` (programming-learning-platform) crash-looped
with DB connect timeouts after a host reboot. Root cause: `/etc/iptables/rules.v4`
had been "persisted" via full `iptables-save` snapshots (2026-07-26 and
2026-08-05/06) taken **while Docker containers were running**. Those snapshots
froze Docker's per-network runtime rules (per-IP `! -i br-<id> -j DROP`).
`netfilter-persistent` replayed the snapshot at every boot; when a recreated
compose network reused subnet `172.18.0.0/16`, the resurrected rules for dead
bridges blackholed all container-to-container traffic.

Docker / k3s / Cilium rebuild their own chains at daemon start. Only
hand-written rules need persistence — they live in `host-firewall.sh`,
version-controlled here, applied idempotently at boot by
`host-firewall.service`. `netfilter-persistent` is **disabled**;
`/etc/iptables/rules.v4` remains on disk only as a frozen static backup.

## RED LINE

Never run on this host:
- `iptables-save > /etc/iptables/rules.v4`
- `netfilter-persistent save`
- `service iptables save`

To add/change a rule: edit `host-firewall.sh` here, commit, then
`sudo /usr/local/sbin/host-firewall.sh` (or reboot). Rules-as-code, reviewable
in git — a stray kernel dump would be obvious in the diff.

## Install (once)

```bash
sudo cp host-firewall.sh /usr/local/sbin/ && sudo chmod +x /usr/local/sbin/host-firewall.sh
sudo cp host-firewall.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now host-firewall.service
```

## Rule inventory

| Rules | Origin |
|---|---|
| INPUT allow-list (22/80/443) + default-REJECT + base (lo/icmp/established) | OCI image default; 443 added 2026-07-26 NPM migration |
| `10.42.0.0/16 → 6443/4244/10250` | 2026-08-05/06 Cilium pod-CIDR fix (k3s/README.md has the full diagnosis) |
| `InstanceServices` chain + OUTPUT jump | OCI image default (metadata/iSCSI/NTP) |
| `DOCKER-USER -i enp0s6 dports 3001,9090,8080 DROP` | hardening: Grafana/Prometheus/Nginx not reachable from the internet |

## Verify

```bash
systemctl status host-firewall.service
sudo iptables -S INPUT | grep -cE 'dport (22|80|443|6443|4244|10250)'   # expect 6
sudo iptables -S DOCKER-USER                                            # the enp0s6 drop
```
