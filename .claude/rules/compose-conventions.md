---
paths:
  - "*/compose/**"
---

# Compose 约定

编写或修改任何 `<host>/compose/<compose>/docker-compose.yml` 时必须遵守。这里是这些约定的唯一权威来源，`README.md` 只做指引。

- 不提交任何密钥/密码/token。敏感配置放 `.env` 文件（已在 `.gitignore` 排除），compose 里通过 `env_file` 或环境变量引用
- 镜像版本尽量锁定具体 tag 或 digest，不用 `latest`
- 每次改动尽量小、单一职责，方便 review 和回滚
- 每个 compose 目录对应一个独立的 docker-compose 栈，栈内可以有多个服务，但不同栈的文件不要混放到同一个目录
- **时区**：容器统一用 `environment: TZ: "Asia/Hong_Kong"`，保证日志时间戳跟人对得上。
  - **光有 `TZ` 不一定生效**：程序还得能在镜像里查到 `/usr/share/zoneinfo/Asia/Hong_Kong`，查不到不报错，直接**静默回退 UTC**。2026-08-21 全量排查——镜像里没有 zone 文件、实际跑成 UTC 的：`portainer/portainer-ce`、`headlamp`、cilium（只带 `UTC` 一个 zone）、`alpine/socat`、`busybox`；镜像里带 zone 文件的：`ubuntu/squid`、`nginx:*-alpine`、grafana、prom 系列。**特例**：vikunja、homepage 的镜像里同样没有 zone 文件，但运行时自带 tzdata（Go 的 `time/tzdata`、Node 的 ICU），照样是 `+0800`——所以判断标准始终是程序的实际行为，不是文件在不在。
  - **镜像不带 tzdata 时**，挂那一个 1.2 KB 的 zone 文件，不要挂整个 2.1 MB 目录：
    ```yaml
    volumes:
      - /usr/share/zoneinfo/Asia/Hong_Kong:/usr/share/zoneinfo/Asia/Hong_Kong:ro
    ```
    **不要用 `/etc/localtime:/etc/localtime:ro`**（网上最常见的写法，在这里是白挂）：Go 只在 `TZ` 未设置时才读 `/etc/localtime`，一旦 `TZ` 设成 zone 名就只查 `/usr/share/zoneinfo`。portainer 就是这么修的。
  - **k3s 侧**同理，但先看命名空间：`headlamp`、`pr-lanes` 带 `pod-security.kubernetes.io/enforce: baseline`，而 baseline profile **禁止 hostPath volume**，这类命名空间改用 ConfigMap 装 zone 文件再 `subPath` 挂载，见 [`vps_oracle/k3s/apps/headlamp/k8s/tzdata-configmap.yaml`](../../vps_oracle/k3s/apps/headlamp/k8s/tzdata-configmap.yaml)。
  - **`docker exec <容器> date` 不是可靠的检查手段**：prom 系列镜像里的 busybox `date` 完全不认 IANA zone 名（只认 POSIX 写法 `TZ=HKT-8`），显示 UTC，但 Prometheus 主进程日志其实是 `+08:00`；portainer 则根本没有 shell。判断真实时区看**应用自己的日志时间戳**，或拿 `docker inspect -f '{{.State.StartedAt}}'` 跟第一条日志比对。
  - **故意保持现状的**：prometheus / node-exporter / blackbox-exporter（应用日志已经是 `+08:00`；唯一能修好 busybox `date` 的 `TZ=HKT-8` 反而会把应用日志打回 UTC，两个消费者要求的格式互斥）；cilium（为一个日志时区滚动重启全集群 CNI DaemonSet 不划算，且它输出 UTC 跟 kubectl 和其他 k8s 组件一致）。
- **日志大小限制**：每个 service 都要显式声明 `logging`，避免日志把磁盘写满：
  ```yaml
  logging:
    driver: json-file
    options:
      max-size: "10m"
      max-file: "5"
  ```
- **端口最少暴露**：宿主机上只发布确实需要直连的端口（如 3x-ui 的节点端口、npm 的 80/443）。管理面板/内部服务（3x-ui 面板、Prometheus、Grafana、Portainer UI 等）一律不发布到宿主机，统一走 NPM 反代到 `proxy` 网络内部端口；应急访问走 SSH + 容器内部 IP，不额外开端口。
- **最小权限**：能力允许的容器加 `security_opt: [no-new-privileges:true]`（monitoring、portainer 已启用）。挂载 `/var/run/docker.sock` 属于已知的高风险例外（如 portainer），要在注释里明确标注原因，不能悄悄引入新的等价挂载。
- **重启策略**：统一 `restart: unless-stopped`，宿主机重启后自动拉起，但手动停止不会被拉回来。
- **网络隔离**：跨栈互通走外部网络 `proxy`（子网 `172.19.0.0/16`，`docker network create proxy --subnet 172.19.0.0/16 --gateway 172.19.0.1 --ip-range 172.19.1.0/24` 手动建一次），不需要对外暴露的服务不要挂到 `proxy` 上。
  - **`--ip-range` 是故意划的**：把动态分配限制在 `172.19.1.0/24`，让 `172.19.0.0/24` 整段只能被 compose 里显式 `ipv4_address:` 认领，物理上跟动态分配池不重叠。背景：2026-08-16 宿主机意外重启，3x-ui 钉死的静态 IP（`172.19.0.2`）被同网络里某个先启动、走默认动态分配的容器抢走，导致 3x-ui 起不来——根因是"钉死的静态 IP"和"给别人用的动态池"当时共用同一段地址，谁先 attach 网络谁就可能抢到，与启动顺序强相关而不可控。划分地址段之后即使 3x-ui/npm 最后一个启动，动态分配器也不会分到 `.2`/`.3`，问题在结构上不会再复现。
  - 目前钉死静态 IP 的容器：`3x-ui`（`172.19.0.2`）、`npm`（`172.19.0.3`）、`prometheus`（`172.19.0.4`，让 k3s apiserver 通过内部 IP 访问，没有接 NPM 反代；`proxy` 同时也是 `prometheus`/`grafana` 唯一的对外出口，原因见 `vps_oracle/compose/monitoring/docker-compose.yml` 末尾 `networks.default` 的注释）。以后新增需要固定 IP 的服务，从 `172.19.0.5` 往后在此登记，不要占用 `172.19.1.0/24`。
- **暴露内容用英文**：任何会展示给最终用户/访客的内容（如 dashboard 标题、服务卡片描述、UI 文案等）统一用英文；仓库内部的注释、文档、commit message 不受此限，按原有习惯用中文即可。

## 改完之后

- 仓库目录就是运行目录，直接在对应目录应用：`cd <host>/compose/<compose> && docker compose up -d`
- 但**不要假设仓库里的定义跟线上一致**——会重建容器的操作，先跟用户确认。
- 一次 commit 一个改动，范围限定在单个 compose 栈。
