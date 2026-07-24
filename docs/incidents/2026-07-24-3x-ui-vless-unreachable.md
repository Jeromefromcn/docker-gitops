# 2026-07-24 3x-ui VLESS 连接不上

## 现象
- 用户反馈 vless 服务连不上，港时约 19:30 左右手动重启 `3x-ui` 容器后恢复
- 容器健康检查全程显示 `healthy`，Docker 没有自动重启过它（`RestartCount: 0`，`OOMKilled: false`，`ExitCode: 0`）

## 排查过程
- `docker inspect`：容器本身没崩溃，宿主机 `dmesg`/`journalctl` 无 OOM、无内核杀进程记录，内存/磁盘充足
- `docker events` 在故障时间窗口无任何事件（无 die/unhealthy/oom）
- 容器日志：以下时间戳均为 **UTC**（容器本身 `TZ=Asia/Hong_Kong`，但这批日志戳来自 UTC 来源，换算需 +8）。UTC 05:17（港时 13:17）用户登录成功后，到 UTC 11:24（港时 19:24，与用户回忆的 19:30 左右手动重启基本吻合）手动重启前，**长达6小时日志完全空白**，重启前的最后一条是优雅关闭（`WebSocket hub stopped` → `Shutting down servers`），不是崩溃
- 健康检查定义：`nc -z 127.0.0.1 443/2053/2096`，只测端口是否能完成 TCP 握手，不验证 VLESS 协议本身是否正常工作
- 容器 `ulimit -n` 只有默认的 1024，没有单独调高
- 排查了 fail2ban（`3x-ipl` jail，IP 限制封禁机制）：jail 是 enabled 状态，但源日志、ban 日志、历史 ban 日志全部为空，**排除** fail2ban/IP 限制导致本次故障的可能

## 根因
- 较高把握：**健康检查太浅**，只测端口连通性，测不出 xray-core 内部是否真的在正常处理 VLESS 流量，导致即使代理逻辑异常，容器依然显示 healthy，Docker 不会自动重启
- 怀疑但未直接证实：默认 1024 的文件描述符上限，长时间运行、连接数较多时可能耗尽，与"端口通、协议不通"的现象吻合
- 由于故障期间应用日志完全空白，无法 100% 锁定内部代码级根因

## 处理
- `docker-gitops/vps_oracle/3x-ui/docker-compose.yml`：
  - healthcheck 增加 `pgrep -f xray-linux-arm64` 判断，确认 xray 核心进程存活，不只测端口
  - 新增 `ulimits.nofile` 65535（原默认 1024），排除 FD 耗尽的可能
- 把该 compose 文件纳入 `docker-gitops` 仓库管理（`vps_oracle/3x-ui/`），仓库目录本身即为运行目录，直接在该目录执行 `docker compose up -d` 部署

## 后续
- 下次再出现同类问题，**先抓现场再重启**：
  ```bash
  docker exec 3x-ui sh -c 'ls /proc/1/fd | wc -l; ulimit -n; ss -s'
  docker inspect 3x-ui --format '{{json .State.Health}}'
  ```
- 待改进但本次未做：健康检查目前仍未验证真正的 VLESS/TLS 握手，只是加了进程存活判断；如果问题复现，可以考虑做一个更深的探测脚本
- 待改进：xray 当前没有开启更详细的 error log，下次真出问题时日志里可能还是没有直接线索
