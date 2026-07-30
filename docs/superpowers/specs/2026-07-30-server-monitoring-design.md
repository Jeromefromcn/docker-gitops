# 服务器级监控告警系统 — 设计（Prometheus + Grafana）

日期：2026-07-30

## 背景

最初评估过三个方案（Prometheus+Grafana / Netdata / Beszel+Uptime Kuma），先选了 Beszel+Uptime Kuma 并完整实现、部署、验证过一轮。实现过程中暴露了两个 Beszel 数据模型上的硬限制：

1. `alerts` collection 有 `(user, system, name)` 唯一索引，`name` 是固定的指标枚举，**同一指标只能配一条告警规则**，没有 warning/critical 两档并存的空间。
2. 告警通知**没有消息模板能力**（GitHub 上有对应的开放 feature request，官方还没做），发出来的 Telegram 消息是写死的英文句子，没法加醒目的颜色/emoji 区分级别和恢复状态。

这两点都是当初选型时没预料到的产品限制，权衡后决定推倒重来，换成 Prometheus + Grafana——牺牲一部分"轻量"换回配置灵活度。原 Beszel/Uptime Kuma 的部署、compose 文件、git 提交记录（均未 push 过）已经完整清除。

## 目标与范围

延续原设计的范围：

- **宿主机指标**：CPU / 内存 / 磁盘使用率，两档 severity（warning/critical）
- **服务可用性探活**：现有 HTTP(S) 服务和 TCP 端口是否可达
- **告警渠道**：Telegram，消息要醒目（emoji/颜色区分级别），恢复要用绿色元素跟告警区分开

**不在本次范围内**（YAGNI，明确排除）：
- 容器级指标
- 日志扫描/异常关键字告警
- Alertmanager（Grafana 自带的 Unified Alerting 直接对接 Telegram，省掉这个组件）

**命名与消息语言**：告警规则名称、Grafana 里的各项配置名称、Telegram 通知消息内容全部用**英文**。本设计文档自身仍用中文书写。

## 架构

一套紧耦合的监控系统，四个组件放进**同一个** compose 目录（`vps_oracle/monitoring/`），因为它们彼此就是单向依赖链、脱离彼此没有独立存在的意义：Grafana 唯一数据源是这个 Prometheus，Prometheus 唯一抓取对象是这两个 exporter。

- **Prometheus**：抓取、存储、评估告警规则
- **node_exporter**：本机宿主机指标采集（标准做法是只读挂载宿主机 `/proc`、`/sys`、`/` 到容器里读取，不需要 `network_mode: host`）
- **blackbox_exporter**：服务可用性探测（HTTP/TCP），一份配置覆盖全部探测目标
- **Grafana**：仪表盘 + 告警评估 + 通知（Unified Alerting，不需要额外的 Alertmanager）

**多主机扩展**：未来新主机只加一个 node_exporter（放在新主机自己的目录下，类似之前 Beszel agent 的模式），不复制整个 `monitoring` 目录；该主机的 node_exporter 需要能被这台 Prometheus 抓到（需要主机间网络可达，这是这个方案相对 Beszel/Uptime Kuma 的已知代价——之前评估时就提到过，多主机场景要打通 exporter 网络）。

### 网络与暴露

- **Grafana**：HTTP UI，加入 `proxy` 网络，走 NPM 反代（`grafana.jerome.cloudns.asia`），不发布宿主机端口
- **Prometheus**：不对外暴露，没有登录认证，只用 `docker exec` 或本机端口做临时 PromQL 调试
- **node_exporter / blackbox_exporter**：纯指标接口，不加入 `proxy` 网络，只需要 Prometheus 能在 docker 网络内部连到即可（同一 compose 文件内默认网络互通）

### 持久化与配置文件

- `/etc/monitoring/prometheus-data`：Prometheus 数据
- `/etc/monitoring/grafana-data`：Grafana 数据（含仪表盘、用户等运行时状态）
- Prometheus/blackbox_exporter 的配置文件（`prometheus.yml`、`blackbox.yml`）是**应用配置而非运行时数据**，随仓库提交、以只读方式挂载进容器，改配置走"改文件 → git commit → `docker compose up -d`"，不是去容器里改
- Grafana 的告警规则、数据源、Contact Point 尽量走**声明式 provisioning**（YAML 文件放 `provisioning/` 目录，随仓库提交，容器启动时自动加载），这是相对 Beszel 最大的改善——不用再写脚本调 API 做"先查再增删改"那套

## 密钥处理

- **Grafana 初始管理员密码**：环境变量注入（`.env`，gitignored），不写死在 compose 文件里
- **Telegram bot token**：Grafana 的 provisioning YAML 支持用环境变量占位符（`${VAR}`），实际 token 存 `.env`，不进 git——具体的占位符语法在写实施计划时要对着 Grafana 版本核实清楚，避免猜错格式
- Prometheus、node_exporter、blackbox_exporter 均不涉及密钥

## 告警设计

### 宿主机指标（两档 severity，恢复了最初的设计）

| 指标 | 警告级别 | 严重级别 |
|---|---|---|
| CPU | >75%，持续 15 分钟 | >90%，持续 10 分钟 |
| 内存 | >70%，持续 15 分钟 | >85%，持续 10 分钟 |
| 磁盘使用率 | >75%，立即 | >85%，立即 |

每条规则打 `severity: warning` 或 `severity: critical` 标签。磁盘不设持续时间要求（磁盘占用变化慢，到阈值基本就是真实状态）；网络流量异常暂不设阈值（没有历史基线，先攒数据）。共 6 条告警规则。

### 服务可用性探活（blackbox_exporter，不分级，二元状态）

| 目标 | 探测方式 | 说明 |
|---|---|---|
| `https://npm.jerome.cloudns.asia` | HTTP，模块 `http_2xx` | NPM 管理面板 |
| `https://panel.3x.jerome.cloudns.asia` | HTTP，自定义模块，接受状态码含 404 | 面板走随机路径，根路径 404 是正常现象（见[迁移文档](../../2026-07-26-npm-reverse-proxy-migration.md)） |
| `https://sub.3x.jerome.cloudns.asia/sub/` | HTTP，模块 `http_2xx` | 订阅服务 |
| `jerome.cloudns.asia:39876` | TCP，模块 `tcp_connect` | VLESS 节点端口 |
| `https://portainer.jerome.cloudns.asia/` | HTTP，模块 `http_2xx` | Portainer 管理面板 |

Prometheus 抓取间隔与 blackbox 探测间隔建议 60 秒，配合 Grafana 告警规则的 `for` 字段（比如持续 2 分钟不通才报警）避免网络抖动误报。

### 消息模板（Grafana Unified Alerting，解决最初换方案的核心诉求）

用 Grafana 的通知模板（Go template），按 `severity` 标签和 `$status`（firing/resolved）动态生成消息前缀：

- Firing + critical：`🚨🔴 CRITICAL: ...`
- Firing + warning：`⚠️🟠 WARNING: ...`
- Resolved：`✅🟢 RESOLVED: ...`

具体模板语法在写实施计划时核对 Grafana 当前版本的文档确认，避免语法猜错。

## 部署与验证步骤（概要，具体命令留给实施计划）

1. 部署 `monitoring` compose stack（Prometheus + node_exporter + blackbox_exporter + Grafana）
2. NPM 加 `grafana.jerome.cloudns.asia` 反代规则
3. Prometheus 抓取 node_exporter/blackbox_exporter 是否正常（查 Prometheus 自己的 targets 页面，本机端口临时访问）
4. Grafana 配置 Prometheus 数据源、Telegram Contact Point、6 条告警规则 + 消息模板
5. 端到端验证：分别触发一次真实的指标告警和一次探活告警，确认 Telegram 收到消息且格式符合预期（emoji/颜色区分明确），再验证恢复通知也正常

## 未来扩展

- **多主机**：新主机加一个 node_exporter compose（同之前 Beszel agent 模式），需要保证 Prometheus 能网络可达（这是相对 Beszel/Uptime Kuma 已知的代价，之前方案对比时就提到过）。
- **Uptime 探活目标增长**：blackbox_exporter 的 targets 列表直接加，走 Prometheus 配置文件即可，没有额外依赖需要引入。
