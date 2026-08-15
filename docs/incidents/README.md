# Incidents

按时间倒序记录服务器上服务出问题的排查过程和根因，方便以后同类问题复用经验。

新增记录时，文件名格式：`YYYY-MM-DD-<service>-<简短描述>.md`，模板见任意一篇现有记录。

| 日期 | 服务 | 简述 | 记录 |
|---|---|---|---|
| 2026-08-15 | vscode-server | 远程会话堆积引发资源尖峰（负载 38.7），根因链上游为 ccr 卡死 bug | [链接](2026-08-15-vscode-sessions-resource-spike.md) |
| 2026-08-15 | ccr | VS Code 扩展经 ccr 走第三方 provider 逐 token SSE 致会话卡死，SSE 合并中间件修复 | [链接](2026-08-15-ccr-vscode-extension-stall.md) |
| 2026-08-06 | npm | access list 误拦流量：daemon 重启后 proxy 网内容器 IP 漂移，与 xray DNS 覆写和放行规则错位，修复为钉静态 IP | [链接](INCIDENT-2026-08-06-proxy-access-ip-mismatch.md) |
| 2026-08-06 | k3s/docker | k3s 装载 br_netfilter 使 Docker 残留 raw 表规则生效，bridge 内容器互连失败 | [链接](INCIDENT-2026-08-06-br-netfilter-stale-iptables-rules.md) |
| 2026-07-24 | 3x-ui | VLESS 连不上，重启容器恢复，根因指向健康检查过浅 | [链接](2026-07-24-3x-ui-vless-unreachable.md) |
