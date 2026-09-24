# Deleting ~20 GB with the root filesystem mounted `discard` saturated the boot volume with TRIMs and fired the IO PSI alert

- Date: 2026-09-24
- Environment: vps_oracle (4-core ARM, 23 GB RAM), 200 GB OCI boot volume `sda`, root ext4 mounted `rw,relatime,discard,commit=30,errors=remount-ro` (the Ubuntu cloud-image default in `/etc/fstab`), `fstrim.timer` enabled (weekly, Mon ~00:10)
- Symptom: Grafana `io_pressure_critical` at 22:58 HKT — "IO PSI 'full' above 15% for 2 minutes on vps-oracle"
- Fix: drop `discard` from the root line in `/etc/fstab` + `mount -o remount,nodiscard /`; rely on the already-enabled weekly `fstrim.timer` (applied 2026-09-24, backup at `/etc/fstab.bak-20260924`)

---

## 1. Conclusion first

**The root cause was a bulk file deletion under online discard, not a misbehaving service.** Another Claude session cleaning up disk space deleted ~20 GB of JetBrains Toolbox backups (`~/.cache/JetBrains/Toolbox/backup/*`) at 22:53. Because `/` is mounted with `discard`, ext4 turned the freed extents into a stream of TRIM requests to the OCI block volume, which kept `sda` 100% busy on discards for ~6 minutes with almost zero reads/writes. Every other process needing IO queued behind them → IO PSI `full` ~26%.

A smaller preceding wave (22:47–22:50, peak ~19%) came from the same session's whole-disk `du -xsh` / `find / -xdev` scans — ordinary metadata reads, not enough on its own to page.

No service was at fault and nothing needed restarting. Memory PSI stayed at 0 throughout; vps-oracle2 was unaffected. Unrelated to the two 2026-08-17 IO PSI incidents (memory overcommit, trivy scan concurrency) — trivy's last scan was at 22:39.

## 2. Evidence chain

Live PSI at alert time, already falling; memory pressure zero:

```
$ cat /proc/pressure/io
some avg10=1.28 avg60=17.17 avg300=18.94
full avg10=1.11 avg60=15.10 avg300=16.39
$ cat /proc/pressure/memory
full avg10=0.00 avg60=0.00 avg300=0.00
```

Prometheus (`docker exec prometheus wget -qO- localhost:9090/...`, `instance="vps-oracle"`, `[3m]` rate — `[1m]` returns empty because node_oracle is scraped at 60s). Per-minute values, minute of 22:xx:

```
io PSI full %      47:6 48:13 49:19 50:15 51:4 52:1 53:0 54:9 55:22 56:26 57:26 58:26 59:20 00:7
reads/s            47:366 48:826 49:991 50:725 51:211 52:15 53:0 54:8 55:9 56:3 57:2 58:1 59:16
writes/s           47:61 48:137 49:154 50:103 51:60 52:30 53:24 54:103 55:107 56:31 57:28 58:24 59:25
sda io_time %      47:35 48:76 49:87 50:62 51:19 52:3 53:2 54:36 55:84 56:98 57:98 58:99 59:76
discards/s         47:4 48:9 49:8 50:2 51:2 52:2 53:2 54:66 55:147 56:154 57:148 58:149 59:119 00:46
discard time %     54:36 55:86 56:100 57:100 58:100 59:77 00:27
root avail (GB)    52:97.5 53:118.1
```

Two different signatures:

- **Wave 1 (22:47–22:50):** ~1000 reads/s drives the utilisation — matches the sudo log:
  ```
  22:45:59 sudo du -xsh /var/lib/docker /var/lib/rancher /var/lib/containerd /home/ubuntu /var/log ... /swapfile
  22:48:54 sudo du -xh --max-depth=2 /home/ubuntu
  22:48:55 sudo find / -xdev -type f -newermt ... -size +10M
  22:49:24 sudo find / -xdev -type f -newermt ... -size +50M
  ```
- **Wave 2 (22:54–22:59):** disk 98–100% busy with reads/writes near idle — the whole busy time is discard time. Free space on `/` jumped +20.6 GB at 22:53, and the sudo log shows the session sizing exactly those directories just before:
  ```
  22:52:55 sudo du -sh /home/ubuntu/.cache/JetBrains/Toolbox/backup/IDEA-U-261.25134.95-...
  22:52:55 sudo du -sh /home/ubuntu/.cache/JetBrains/Toolbox/backup/PyCharm-P-262.7132.31-...
  ```
  `~/.cache/JetBrains/Toolbox/backup/` was empty afterwards (mtime 22:53).

Mount options and trim schedule:

```
$ findmnt -no OPTIONS /
rw,relatime,discard,errors=remount-ro,commit=30
$ systemctl list-timers fstrim.timer
Mon 2026-09-28 00:09:41 HKT ... Mon 2026-09-21 00:42:55 HKT ... fstrim.timer
```

Red herring ruled out: testcontainers (ryuk) containers were starting all evening (21:06, 21:38–21:46, 22:40–22:47) — the 21:38–21:46 runs produced no spike, and none started during wave 2.

## 3. Root cause

With the `discard` mount option, ext4 issues a TRIM for every extent freed, synchronously with the journal commit (`commit=30`). Deleting tens of GB of files frees millions of blocks at once, so the kernel pushes a long burst of discard requests to the device. On the OCI paravirtualized block volume discards are not free — they occupy the device queue like real IO, and at ~150 discards/s they kept `sda` 100% busy for ~6 minutes. Anything else that needed the disk (journal commits, container writes, page-cache misses) stalled behind them, which is exactly what PSI `full` measures.

A diagnostic trap: the usual "reads/writes per second" panels look idle during such an event. Only `io_time` + `node_disk_discard*` metrics reveal it.

## 4. Fix

Batch the TRIMs instead of issuing them inline: remove `discard` from the root line of `/etc/fstab` and remount. `fstrim.timer` is already enabled, so freed blocks are still returned to the volume once a week at ~00:10 Monday, when nobody is working.

Applied the same evening (host `/etc/fstab` is not tracked in this repo):

```bash
sudo cp -p /etc/fstab /etc/fstab.bak-20260924
sudo sed -i -E 's/^(LABEL=cloudimg-rootfs\s+\/\s+ext4\s+)discard,/\1/' /etc/fstab
sudo mount -o remount,nodiscard /
sudo systemctl daemon-reload
```

Why not keep `discard` and just "delete more slowly": deletions happen from many sources (cleanup sessions, `docker system prune`, `crictl rmi --prune` from the inspector, image GC), so a host-level fix beats relying on every deleter to be gentle.

## 5. Verification

```
$ diff /etc/fstab.bak-20260924 /etc/fstab
< LABEL=cloudimg-rootfs	/	 ext4	discard,commit=30,errors=remount-ro	0 1
> LABEL=cloudimg-rootfs	/	 ext4	commit=30,errors=remount-ro	0 1
$ findmnt -no OPTIONS /
rw,relatime,errors=remount-ro,commit=30
$ sudo findmnt --verify
0 parse errors, 0 errors, 1 warning     # the warning is the pre-existing /swapfile entry
$ systemctl is-enabled fstrim.timer
enabled
```

Next bulk delete: `node_disk_discards_completed_total` should stay flat at deletion time; the discard burst moves to Monday ~00:10 (`journalctl -u fstrim` shows the trimmed amount).

## 6. Leftovers / lessons

- When an IO PSI alert shows high `io_time` but low read/write IOPS, check `node_disk_discard_*` before hunting for a noisy process.
- Whole-disk `du` / `find /` scans alone produce ~20% PSI `full` on this volume — prefer targeted paths when looking for space.
- A cloud-image rebuild of this host would bring `discard` back — re-apply the fstab edit on any new vps_oracle instance.
- No inspector check added: this was operator-induced and one-off; after the fstab change the trigger no longer exists.
