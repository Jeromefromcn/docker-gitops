# 2026-07-24 3x-ui VLESS unreachable

## Symptoms
- User reported the vless service was unreachable; around 19:30 HKT it recovered after manually restarting the `3x-ui` container
- The container health check showed `healthy` the entire time, and Docker never auto-restarted it (`RestartCount: 0`, `OOMKilled: false`, `ExitCode: 0`)

## Investigation
- `docker inspect`: the container itself had not crashed; host `dmesg`/`journalctl` showed no OOM, no kernel process-kill records, and memory/disk were sufficient
- `docker events` showed no events in the failure time window (no die/unhealthy/oom)
- Container logs: the timestamps below are all **UTC** (the container itself has `TZ=Asia/Hong_Kong`, but this batch of log timestamps came from a UTC source, so add +8 to convert). From UTC 05:17 (13:17 HKT) when the user logged in successfully, up to UTC 11:24 (19:24 HKT, roughly matching the user's recollection of a manual restart around 19:30) just before the manual restart, **the logs are completely empty for 6 hours**, and the last line before the restart is a graceful shutdown (`WebSocket hub stopped` → `Shutting down servers`), not a crash
- Health check definition: `nc -z 127.0.0.1 443/2053/2096`, only testing whether the port can complete a TCP handshake, not verifying whether the VLESS protocol itself works correctly
- The container's `ulimit -n` was just the default 1024, not raised separately
- Investigated fail2ban (the `3x-ipl` jail, an IP-based ban mechanism): the jail was enabled, but source logs, ban logs, and historical ban logs were all empty, **ruling out** fail2ban / IP restriction as the cause of this failure

## Root cause
- High confidence: **the health check is too shallow** — it only tests port connectivity and cannot tell whether xray-core is actually handling VLESS traffic correctly, so even when the proxy logic misbehaves the container still shows healthy and Docker does not auto-restart
- Suspected but not directly confirmed: the default 1024 file-descriptor limit, under long uptime and a high connection count, may be exhausted, matching the "port reachable but protocol unreachable" symptom
- Because the application logs were completely empty during the failure, the internal code-level root cause cannot be pinned with 100% certainty

## Actions taken
- `docker-gitops/vps_oracle/compose/3x-ui/docker-compose.yml`:
  - healthcheck now also runs `pgrep -f xray-linux-arm64` to confirm the xray core process is alive, not just test the port
  - added `ulimits.nofile` 65535 (was the default 1024), ruling out FD exhaustion
- Brought this compose file under `docker-gitops` repo management (`vps_oracle/compose/3x-ui/`); the repo directory itself is the working directory, deployed by running `docker compose up -d` there directly

## Follow-up
- Next time this kind of problem reappears, **capture the scene first, then restart**:
  ```bash
  docker exec 3x-ui sh -c 'ls /proc/1/fd | wc -l; ulimit -n; ss -s'
  docker inspect 3x-ui --format '{{json .State.Health}}'
  ```
- To improve but not done this time: the health check still does not verify a real VLESS/TLS handshake, it only adds a process-liveness check; if the problem recurs, consider writing a deeper probe script
- To improve: xray currently does not enable a more detailed error log, so next time a real problem occurs the logs may still lack a direct clue