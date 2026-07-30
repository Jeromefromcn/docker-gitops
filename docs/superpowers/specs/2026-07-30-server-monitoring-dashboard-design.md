# 服务器级监控大盘 — 设计（Grafana Dashboard）

日期：2026-07-30

## 背景

`vps_oracle/monitoring` 的 Prometheus + Grafana 告警系统（见 [server-monitoring-design.md](2026-07-30-server-monitoring-design.md)）已经部署完成：Prometheus 抓取 node_exporter/blackbox_exporter，Grafana 做告警评估 + Telegram 通知。告警解决的是"阈值突破时通知我"，但目前没有一个可以直接打开看"服务器现在整体状态怎么样"的可视化大盘。本次要补上这块——CPU、内存、磁盘、网络等常用指标的仪表盘。

## 目标与范围

- 单机（vps_oracle）范围的服务器级监控大盘：CPU、内存、磁盘、网络等常用指标。
- 复用已部署的 Prometheus 数据源（`uid: prometheus`，见 Task 3 datasource provisioning）和 node_exporter 抓取的指标（`job_name: node`）。

**不在本次范围内**：
- 新增或修改任何告警规则（Task 6/7 的 host-metrics-rules.yml / probe-rules.yml 保持不动）。
- 修改 node-exporter 的 `network_mode`（详见下方"网络指标准确度"）。
- 多主机模板变量扩展（目前只有一个 host，暂不做 `$host` / `$instance` 多选下拉之外的额外设计）。

## 落地方式

延续本仓库对 Grafana 的声明式 provisioning 原则（数据源、告警规则都是 YAML 随仓库提交，容器启动时自动加载），dashboard 也走同样的模式，而不是手工在 UI 里点：

- 新增 `vps_oracle/monitoring/grafana/provisioning/dashboards/dashboards.yml` — dashboard provider 配置，声明一个指向本地 JSON 目录的 provider，`updateIntervalSeconds` 设置为定期从磁盘重新加载（后续改 JSON 文件不需要重启容器）。
- 新增 `vps_oracle/monitoring/grafana/provisioning/dashboards/node-exporter-full.json` — 从 Grafana 官方 dashboard 仓库（grafana.com）下载社区维护的 **Node Exporter Full**（dashboard ID `1860`）最新版本 JSON，固定版本提交进本仓库（不在 Grafana 运行时联网拉取，符合"配置即代码、可审计、离线可用"的原则）。

**下载后的适配点**：
1. 把 JSON 里 datasource 相关的模板变量/输入项（社区仪表盘导入时一般会问"选择你的 Prometheus 数据源"）固定替换成 Task 3 已建好的 `uid: prometheus`，这样导入时不需要人工再选一次数据源。
2. 确认仪表盘的 `job` 变量默认值/正则能匹配到 `prometheus.yml` 里配置的 `job_name: node`（否则面板会显示"No data"）。

**Folder**：`Monitoring`（与现有 `host-metrics-rules.yml` / `probe-rules.yml` / `self-monitoring-rules.yml` 用同一个 folder，一个地方能看全部监控相关内容）。

## 兼容性验证

Dashboard 1860 是社区维护多年的老牌仪表盘，早期版本包含过 Angular 面板（Grafana 从 9.x 开始逐步废弃、近期版本已完全移除 Angular 面板支持），新版本已经改用 timeseries 等现代面板类型。当前部署的是 Grafana `13.1.1`。实施阶段必须实际导入验证：

- 每个面板是否正常渲染（有没有"panel plugin not found"之类的报错）。
- 如果发现个别面板类型不兼容，摘掉该面板或替换成等价的现代面板类型，不因为个别面板报错就放弃整个仪表盘。

## 网络指标准确度

维持 [server-monitoring-design.md](2026-07-30-server-monitoring-design.md) 当初的架构决定：node-exporter 用 bind-mount（`/:/host:ro,rslave` + `--path.rootfs=/host`）而非 `network_mode: host`，是为了避免 host 网络/端口冲突/loopback 这类之前在 Beszel 方案上反复踩过的调试复杂度，且这台 VPS 有公网 IP，host 网络会让无认证的 metrics 端口直接暴露在公网网卡上。

代价：网络接口吞吐量面板看到的是 node-exporter 容器自己的 veth 网卡数据，不是宿主机真实网卡（公网/内网）的吞吐量。本次不改这个架构决定——网络面板照常显示，仅供看趋势（流量在涨还是在跌），不能当成宿主机真实带宽的绝对值使用。

## 验证步骤

1. 部署后在 Grafana UI（`https://grafana.jerome.cloudns.asia`）→ Dashboards → Monitoring folder 打开 "Node Exporter Full"。
2. 确认 CPU / 内存 / 磁盘相关面板都显示非报错的真实数据（不是"No data"或"panel plugin not found"）。
3. 确认网络相关面板能显示数据（哪怕数值对应的是容器 veth，而非宿主机真实网卡）。
4. 确认 dashboard 出现在 `Monitoring` folder 下，不与现有告警规则混淆展示。

## 未来扩展

- 如果之后有多台主机接入这套 Prometheus，dashboard 的 `job`/`instance` 变量下拉天然支持多选，无需改 JSON 本身。
- 如果对网络流量准确性有硬需求，更稳妥的替代方案是以后单独加一个不暴露端口、只做 host 网络 metrics 采集的方式（例如 textfile collector + cron 脚本），而不是整体切换 node-exporter 的 `network_mode`。
