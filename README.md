# docker-gitops

集中管理所有服务器上运行的 Docker Compose 配置，作为唯一可信来源（source of truth）。

## 目录结构

```
docker-gitops/
└── <host>/                # 按服务器分组，如 vps_oracle
    └── compose/            # 该服务器上所有 docker compose 栈
        └── <compose>/      # 每个 compose 栈一个目录（可包含多个服务）
            └── docker-compose.yml
```

`<host>/` 下除 `compose/` 外，也可能有其他不属于 docker compose 管理的子目录（如 `k3s/`、`inspector/`），各自遵循自己的约定，见对应子目录的 README。

## inspector（主機巡檢）

`vps_oracle/inspector/` 是 host-native bash 巡檢腳本（非容器），由 systemd timer 每天 09:00/21:00 觸發：偵測並清理游離的 VS Code/Claude session 行程樹、堆積的 `.vscode-server` 版本目錄，每輪必發一封英文 Telegram 報告。設計背景（自我保護規則、auto/alert 分級）見 [設計文件](docs/superpowers/specs/2026-08-15-vps-oracle-inspector-design.md)，執行/測試/部署操作見 [`vps_oracle/inspector/README.md`](vps_oracle/inspector/README.md)。

## k3s（雲原生實驗平台，进行中）

`vps_oracle/k3s/` 是在同一台机器上用 K3s 复刻一套云原生开发运维实验平台的多阶段工程——目标是**逐服务**把 compose 栈迁到 k8s，对外域名/端口保持不变，compose 环境去留按服务单独判断，不是要整体推翻现有架构。完整背景、阶段拆解（A 叢集基礎層 → B GitOps 啟動 → C 遷移範本 → D 剩餘服務遷移 → E 供應鏈安全 → F 多環境泳道 → G 服務網格 → H compose 退場評估）见 [K3s 雲原生實驗平台路線圖](docs/superpowers/specs/2026-08-05-k3s-cloud-native-platform-roadmap.md)，各阶段的安装/操作细节见 [`vps_oracle/k3s/README.md`](vps_oracle/k3s/README.md)。

截至目前（phase F+G 已完成，H 尚未开始）：叢集基礎（K3s + Cilium + local-path 存儲）、ArgoCD app-of-apps GitOps 迴路保留在 k3s；`homepage`/`trilium`/`dify`/`vikunja`/`apprise`/`llm`（llama-cpp/open-webui）——即 phase C+D 迁移过的全部服务——2026-08-18 评估后已迁回 compose（详见 [迁移计划一](docs/superpowers/plans/2026-08-18-k3s-to-compose-migration.md)、[迁移计划二](docs/superpowers/plans/2026-08-18-k3s-to-compose-migration-part2.md)）；`evidence-os-website`（原本 k3s 原生，无 compose 前身）同样于同日迁入 compose。k3s 上仅保留 `lab-environment`/`headlamp` 两个 k3s 原生服务（详见下方 `lab-environment`、`headlamp` 等相关章节），以及 phase F+G 新增、由 Istio Ambient 服务网格驱动的 `pr-lanes` 命名空间（`hello-frontend`/`hello-backend`，PR 预览泳道练习环境，取代已退场的 `placeholder-hello`；机制详见 [`vps_oracle/k3s/README.md`](vps_oracle/k3s/README.md) 的「Istio Ambient / PR Lanes」一节）；其余服务仍在 `<host>/compose/` 下运行，见下方「不会迁移到 k3s 的服务」。

### 不会迁移到 k3s 的服务

以下服务经评估后决定继续留在 compose，不排进任何迁移阶段：

| 服务 | 不迁移的原因 |
|---|---|
| `npm` | 是「域名/端口对外不变」这个迁移承诺的锚点——A~D 每迁一个服务都是「k3s 先跑通，再改 NPM 转发规则」，NPM 自己不能同时也在变，否则等于同时挪动锚点和被固定的东西，风险疊加。且 NPM 的「迁移」实质上可能是换成 k8s-native ingress + cert-manager 而非把 NPM 容器化搬进去，这个定性判断要等 D 阶段全部服务迁完、稳定后才有依据。刻意留到 H 阶段才评估 |
| `portainer` | 靠读写 docker socket 管理宿主机**全部** docker 容器（含两个不属本仓库管理的专案）。k3s 用 containerd 不是 docker，portainer 看不到 pod——把这个容器搬进 k3s 没有意义；k8s 侧要有等价的可视化管理面板，该找 k8s 原生方案（ArgoCD UI 已经是一个），而不是迁移 portainer 本身 |
| `monitoring`（prometheus/node-exporter/blackbox-exporter/grafana） | node-exporter 靠 bind mount 读宿主机 `/proc`/`/sys`，监控的是**宿主机本身**；blackbox-exporter 探测的是外部端点存活。若把这套监控系统搬进 k3s，一旦叢集本身出问题，监控会跟着一起挂，违反「监控系统要独立于被监控对象」这个可观测性基本原则 |
| `ccr` / `switchboard` | CCR 的消费者是跑在**宿主机本身**（不是容器）的 `claude` CLI 进程，走不了 docker 网络，所以 CCR 例外地要发布端口，且刻意绑 `127.0.0.1` 不对外暴露（见 `docs/superpowers/specs/2026-08-09-claude-provider-group-switch-design.md`）。这条逻辑在 k3s 下同样成立：k3s 的 pod network 对宿主机进程来说一样是「外部」，要嘛发 NodePort 放弃 `127.0.0.1`-only 的隔离，要嘛留在宿主机层——架构上就不适合迁，跟风险评估无关。switchboard 是 CCR 的配套开关（现已通用化为配置驱动的开关框架，jerome-ccr/bridget-ccr 只是其中两个开关），同理 |
| `3x-ui` | 39876 是客户端直连的 VLESS+Reality 原始 TCP，不走 HTTP 反代，且有过真实故障史（见 `docs/incidents/2026-07-24-3x-ui-vless-unreachable.md`）。compose 里还有个关键设计：釘死静态 IP（`172.19.0.2`）+ xray 自己的 DNS hosts 覆写，让「透过 VLESS 隧道反过来访问自建服务」的流量留在 docker `proxy` 网络内部直通 NPM、不出宿主机也不被 SNAT，NPM 的 access list 放行的正是这个静态 IP。k3s 的 pod network（Cilium）跟 docker bridge 是两张独立的网，迁移会打断这条内部直通路径，需要额外重建（如改放行节点 IP）；再加上任何 k8s 方案（扩 NodePort 范围要重启 k3s、hostNetwork 又跟未来的 PSS/Kyverno 冲突）都要动到一个运作良好的线上端口，风险/收益不成比例，**暂时不迁移** |

## 工作方式

仓库目录本身就是服务运行目录，直接在仓库里对应的 compose 目录下执行 compose 命令：

```bash
cd ~/jerome/docker-gitops/<host>/compose/<compose> && docker compose up -d
```

compose 文件里涉及的挂载卷统一用绝对路径（如 `/etc/x-ui/...`），因此工作目录搬到仓库里不影响容器内的数据位置。

## 新增一个服务

1. 在对应 `<host>/compose/` 目录下新建 `<compose>/docker-compose.yml`
2. 在该目录下 `docker compose up -d` 启动
3. `git add` + commit

## 给服务接入 NPM 反代

新增/修改一条 NPM 反代记录时，按下面的配置来，保持跟现有栈风格一致。

> NPM 已于 2026-08-21 从 2.12.3 升到 2.15.1，而 2.13.0 起换成了 React 新界面。下面的字段本身都还在，但位置/名称可能跟旧界面有出入——下次照着操作时如果对不上，顺手把这段改掉。

**Details 标签页**

| 字段 | 值 |
|---|---|
| Domain Names | `<service>.jerome.cloudns.asia` |
| Scheme | `http` |
| Forward Hostname / IP | 容器名（跟 compose 里的 `container_name` 一致，靠 `proxy` 网络的 Docker DNS 解析，不用填 IP） |
| Forward Port | 容器内部实际监听端口（不是宿主机端口，这些服务本来就不发布端口） |
| Cache Assets | 关闭 |
| Block Common Exploits | 开启 |
| Websockets Support | 开启 |
| Access List | 一律选 `self-only` |
| Custom Locations | 尽量不加，理由见下面的约定 |

**SSL 标签页**

| 字段 | 值 |
|---|---|
| SSL Certificate | 选跟 Domain Names 一致的证书；新域名选 "Request a new SSL Certificate" |
| Email Address for Let's Encrypt | 固定填 `jeromefromcn@gmail.com`，跟现有证书保持一致，不用再查 |
| Force SSL | 开启 |
| HTTP/2 Support | 开启 |
| HSTS Enabled | 关闭 |

**⚠️ 已知坑**：创建时把 Force SSL / HTTP/2 Support 打开保存，有时会被静默重置回关闭状态。**保存后要重新打开这条记录复查一遍**，发现关掉了就再勾一次并保存。

**⚠️ 已知坑（反代到 k3s NodePort 时）**：Forward Hostname/IP 必须直接填宿主机内网 IP（目前是 `10.0.0.95`），不能填 `host.docker.internal` 或其他主机名——NPM 的 nginx 生成的 proxy_pass 配置走 Docker 内嵌 DNS resolver 动态解析，不读容器的 `/etc/hosts`/`extra_hosts`，填主机名会报 "could not be resolved" 导致 502。另外这个 IP 是 DHCP 分配的（`ip -4 addr show enp0s6` 显示 `dynamic`），不是静态 IP——如果 Oracle 换了地址，所有指向 NodePort 的反代会静默变成 502，排查前先确认这个 IP 有没有变。详见 [`vps_oracle/k3s/README.md`](vps_oracle/k3s/README.md) 和 [`vps_oracle/compose/npm/docker-compose.yml`](vps_oracle/compose/npm/docker-compose.yml) 里 `extra_hosts` 的注释。

**⚠️ 已知坑（API 改 `locations` 时可能不生效，且会静默失败）**：dify 迁移切流时发现，`PUT /api/nginx/proxy-hosts/{id}` 带上完整 `locations` 数组一起改，NPM 会把新值写进它自己的数据库（之后 `GET` 能读到新值），但生成 `/data/nginx/proxy_host/{id}.conf` 这一步没有跟着重新渲染——磁盘上的文件还是旧内容。若这份旧文件里引用的上游主机名此时已经解析不到（比如对应的 compose 容器已经 `stop`），`nginx -t` 会报 `host not found in upstream`，API 返回 `{"error":{"message":"Internal Error"}}`（500），重试也一样失败，此时 nginx 还在跑更早之前最后一次成功 reload 的配置——如果那份配置引用的容器也已经停了，站点对外直接 502，且**这个 502 不会自愈，卡在这个状态直到人工介入**。当时的修法：`docker exec npm cat /data/nginx/proxy_host/{id}.conf` 确认磁盘文件确实没跟着变，改用 `docker exec npm sed -i ...` 直接编辑这份文件（改成跟 API 已经写入数据库的值一致），`docker exec npm nginx -t` 验证语法，再 `docker exec npm nginx -s reload` 手动生效——数据库和磁盘配置两边最终还是一致的，只是靠人工把 NPM 自己没做完的那一步补上。**排查线索**：`docker logs npm` 里的 `nginx: [emerg] host not found in upstream "..."` 精确点出是哪个上游主机名解析失败；用这个失败的旧主机名去反查是不是某个已经停掉的 compose 容器。**规避建议**：以后要切换带多条 `locations` 的服务，考虑切流前**不要**提前停掉旧的 compose 容器（等确认 API 更新真的生效、`nginx -T` 里能看到新配置之后再停），或者切完之后立刻验证磁盘文件而不是只信任 API 返回值/数据库读值。

**⚠️ 约定：能不用 Custom Locations 就不用**

上面那条坑有一个跟切流无关、但严重得多的普遍形态。NPM 生成配置时，普通转发把上游主机名放进变量（`set $server "trilium";`），nginx 逐请求经 Docker 内嵌 DNS 解析，后端容器没了只是这一个站 502；但**每一条 Custom Location 都会把主机名写死进 `proxy_pass`**（NPM 的 `_location.conf` 模板），字面量上游必须在**载入配置时**就解析成功，否则 nginx 直接 `[emerg]` 拒绝启动——**全部反代站点一起挂**，不只是那一个。

而运行中的 nginx 靠先前解析到的位址继续跑，所以后端容器停掉之后，从监控、面板、日志全都看不出异常。它只在**下一次 nginx 冷启动**时引爆：宿主机重启、`docker compose up -d`、镜像升级——通常是一个跟它无关的时机。2026-08-21 升级 NPM 时就是这样炸的（dify 容器已经停了 45 小时，全站中断约 90 秒），来龙去脉见 [`vps_oracle/compose/npm/README.md`](vps_oracle/compose/npm/README.md)。

所以：

- **路径分发优先交给服务自己的 nginx/网关做**，NPM 只做一条普通转发指向那一个容器。dify 之所以需要 8 条 Custom Location，正是因为这个仓库的 dify compose 里没有官方那个 `nginx` service。
- **停用一个 compose stack 时，同步在 NPM 里把对应的 proxy host disable 掉**。反代记录开着、后端却没了，就是在埋雷。
- 兜底：`vps_oracle/inspector/checks/npm-nginx-config.sh` 每天 09:00/21:00 跑一次 `nginx -t`，配置坏了会发 Telegram alert。它跑在独立行程里，不影响正在服务的 nginx，所以任何时候都可以手动跑一次确认：`docker exec npm nginx -t`。

## 给新服务加 homepage 卡片

homepage 2026-08-18 已从 k3s 迁回 compose（见上面「k3s」一节），配置源文件是 **`vps_oracle/compose/homepage/config/services.yaml`**。每新增一个服务，在对应分类（`Infra Services` / `Apps`）下加一张卡片，跟现有条目保持同样格式：

```yaml
    - <服务名>:
        icon: <icon-name>.png
        href: https://<service>.jerome.cloudns.asia
        description: <一句话描述，英文>
```

- `icon`：优先用 [walkxcode/dashboard-icons](https://github.com/walkxcode/dashboard-icons) 里对应的文件名（homepage 会自动去 CDN 拉）；没有专门图标的用 `si-<name>`（simple-icons）顶替，如 `si-anthropic`
- `description`：访客可见，按下面"暴露内容用英文"的约定用英文
- 没有 `container`/`server` 字段——迁回 compose 后这个字段本可以恢复（挂 docker.sock），但 2026-08-18 决定继续不挂，保持跟迁移前 k3s 状态一致，只做卡片本身
- **例外**：安全敏感的服务（如 3x-ui）不上卡片，加之前先问一句

改完后 `cd vps_oracle/compose/homepage && docker compose up -d` 直接生效，不用 push/ArgoCD。

## 给 Vikunja 项目接 Telegram 通知（透过 vikunja-notify-relay + Apprise）

Vikunja 的任务事件（指派/提醒到期/逾期/完成）通过 webhook 转发给 `vikunja-notify-relay`（`vps_oracle/compose/vikunja` 栈里的第二个 service，拼出带项目名/任务标题/任务超链接的消息），再转给 `apprise` 按 Vikunja 账号分别路由到各自的 Telegram（每个账号一个 target，不是共用一个）。原理、已知限制（没有真正的全局 webhook）、以及给新 project 补 webhook 的脚本用法，见 [`docs/2026-08-03-vikunja-apprise-telegram-webhooks.md`](docs/2026-08-03-vikunja-apprise-telegram-webhooks.md)。relay 代码：[`vps_oracle/compose/vikunja/notify-relay/`](vps_oracle/compose/vikunja/notify-relay/)；注册脚本：[`vps_oracle/compose/vikunja/register-telegram-webhooks.sh`](vps_oracle/compose/vikunja/register-telegram-webhooks.sh)。

## 约定

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
  - **k3s 侧**同理，但先看命名空间：`headlamp`、`pr-lanes` 带 `pod-security.kubernetes.io/enforce: baseline`，而 baseline profile **禁止 hostPath volume**，这类命名空间改用 ConfigMap 装 zone 文件再 `subPath` 挂载，见 [`vps_oracle/k3s/apps/headlamp/k8s/tzdata-configmap.yaml`](vps_oracle/k3s/apps/headlamp/k8s/tzdata-configmap.yaml)。
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
  - 目前钉死静态 IP 的容器：`3x-ui`（`172.19.0.2`）、`npm`（`172.19.0.3`）、`prometheus`（`172.19.0.4`，只为了让 k3s apiserver 通过内部 IP 访问，没有接 NPM 反代，见 `vps_oracle/compose/monitoring/docker-compose.yml`）。以后新增需要固定 IP 的服务，从 `172.19.0.5` 往后在此登记，不要占用 `172.19.1.0/24`。
- **暴露内容用英文**：任何会展示给最终用户/访客的内容（如 dashboard 标题、服务卡片描述、UI 文案等）统一用英文；仓库内部的注释、文档、commit message 不受此限，按原有习惯用中文即可。

## Host 列表

| Host | 说明 |
|---|---|
| vps_oracle | Oracle Cloud VPS |
