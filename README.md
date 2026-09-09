# docker-gitops

集中管理所有服务器上运行的 Docker Compose 配置，作为唯一可信来源（source of truth）。

## 目录结构

```
docker-gitops/
└── <host>/                # 按服务器分组，如 vps_oracle
    ├── compose/            # 该服务器上所有 docker compose 栈
    │   └── <compose>/      # 每个 compose 栈一个目录（可包含多个服务）
    │       └── docker-compose.yml
    └── host-native/        # 直接跑在宿主机上的 systemd 服务（非容器）
        └── <service>/      # 每个服务一个目录：README + systemd unit
```

`<host>/` 下除 `compose/` 外，也可能有其他不属于 docker compose 管理的子目录：`k3s/`（ArgoCD GitOps 管理的集群，改动走 git push + ArgoCD sync，不是手动命令，见 `vps_oracle/k3s/README.md`）、`dotfiles/`（符号链接式本机配置，见 `vps_oracle/dotfiles/README.md`）、`host-native/`（本节下方说明）。各自遵循自己的约定，见对应子目录的 README。

## host-native（直接跑在宿主机上的 systemd 服務）

`vps_oracle/host-native/` 底下每個子目錄對應一個不適合塞進 docker compose 的服務——需要碰宿主機命名空間、`~/.claude` 之類使用者 home、iptables 這類東西，一律用 systemd unit 常駐，unit 檔案跟原始碼（或第三方套件的部署設定）一起進這個 repo：

| 子目錄 | 是什麼 |
|---|---|
| [`inspector/`](vps_oracle/host-native/inspector/README.md) | host-native bash 巡檢腳本，systemd timer 每天 09:00/21:00 觸發，偵測並清理游離的 VS Code/Claude session 行程樹、堆積的 `.vscode-server` 版本目錄，每輪必發一封英文 Telegram 報告。設計背景（自我保護規則、auto/alert 分級）見 [設計文件](docs/superpowers/specs/2026-08-15-vps-oracle-inspector-design.md) |
| [`host-firewall/`](vps_oracle/host-native/host-firewall/README.md) | 手寫 iptables 規則的唯一可信來源，systemd oneshot 開機時套用 |
| [`npm-nodeport-relay/`](vps_oracle/host-native/npm-nodeport-relay/README.md) | host netns 裡的 TCP relay，讓 NPM（docker 容器）連得到宿主機才拿得到的 k3s NodePort |
| [`cc-window/`](vps_oracle/host-native/cc-window/README.md) | 第三方 Claude Code 多會話管理台（`npm install -g cc-window`），本地網頁看板 |

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

部分 compose 栈自己有 README（记录该栈特有的操作步骤/坑），进目录前先看有没有：[`ccr/README.md`](vps_oracle/compose/ccr/README.md)、[`dify/README.md`](vps_oracle/compose/dify/README.md)、[`npm/README.md`](vps_oracle/compose/npm/README.md)、[`switchboard/README.md`](vps_oracle/compose/switchboard/README.md)。

## 新增一个服务

完整流程（建栈 → 共享资源的 prod/dev 两套池 → 启动 → NPM 反代 → homepage 卡片 → 提交，附收尾自检清单）见 [`.claude/skills/add-service/SKILL.md`](.claude/skills/add-service/SKILL.md)。

## 给服务接入 NPM 反代

完整流程——Details/SSL 两个标签页的字段表、[`add-proxy-host.sh`](vps_oracle/compose/npm/add-proxy-host.sh) 脚本用法，以及三个都会**静默失败**的坑（SSL 开关保存后自我重置、反代到 k3s NodePort 必须填宿主机内网 IP 而非主机名、API 改 `locations` 写进数据库但不重新渲染磁盘配置）——见 [`.claude/skills/npm-proxy-host/SKILL.md`](.claude/skills/npm-proxy-host/SKILL.md)。

**其中最要命的一条留在这里**：能不用 Custom Locations 就不用。普通转发把上游主机名放进变量逐请求解析，后端没了只挂这一个站；而**每条 Custom Location 都把主机名写死进 `proxy_pass`**，字面量上游必须在载入配置时就解析成功，否则 nginx 直接 `[emerg]` 拒绝启动——**全部反代站点一起挂**。运行中的 nginx 看不出异常，它只在下一次冷启动（宿主机重启、`docker compose up -d`、镜像升级）时引爆。2026-08-21 升级 NPM 时就这么炸过，全站中断约 90 秒。路径分发优先交给服务自己的 nginx/网关做；停用一个 stack 时同步把对应的 proxy host disable 掉。
## 给新服务加 homepage 卡片

homepage 2026-08-18 已从 k3s 迁回 compose（见上面「k3s」一节），配置源文件是 **`vps_oracle/compose/homepage/config/services.yaml`**。卡片格式、icon 取名规则、以及「安全敏感的服务（如 3x-ui）不上卡片」这条例外，见 [`.claude/skills/add-service/SKILL.md`](.claude/skills/add-service/SKILL.md) 的第 5 步。改完 `cd vps_oracle/compose/homepage && docker compose up -d` 直接生效，不用 push/ArgoCD。

## 给 Vikunja 项目接 Telegram 通知（透过 vikunja-notify-relay + Apprise）

Vikunja 的任务事件（指派/提醒到期/逾期/完成）通过 webhook 转发给 `vikunja-notify-relay`（`vps_oracle/compose/vikunja` 栈里的第二个 service，拼出带项目名/任务标题/任务超链接的消息），再转给 `apprise` 按 Vikunja 账号分别路由到各自的 Telegram（每个账号一个 target，不是共用一个）。原理、已知限制（没有真正的全局 webhook）、以及给新 project 补 webhook 的脚本用法，见 [`docs/2026-08-03-vikunja-apprise-telegram-webhooks.md`](docs/2026-08-03-vikunja-apprise-telegram-webhooks.md)。relay 代码：[`vps_oracle/compose/vikunja/notify-relay/`](vps_oracle/compose/vikunja/notify-relay/)；注册脚本：[`vps_oracle/compose/vikunja/register-telegram-webhooks.sh`](vps_oracle/compose/vikunja/register-telegram-webhooks.sh)。

## 约定

编写 compose 文件的约定——时区（含 tzdata 静默回退 UTC 的坑）、日志大小限制、端口最少暴露、最小权限、重启策略、网络隔离与静态 IP 登记、对外内容用英文——统一维护在 [`.claude/rules/compose-conventions.md`](.claude/rules/compose-conventions.md)。那里是唯一权威，人和 Claude 读的是同一份。

另外两份规则：k3s/ArgoCD 的改动纪律见 [`.claude/rules/k3s-gitops.md`](.claude/rules/k3s-gitops.md)，文档该写进哪一层见 [`.claude/rules/docs-layout.md`](.claude/rules/docs-layout.md)。

## Host 列表

| Host | 说明 | 详情 |
|---|---|---|
| vps_oracle | Oracle Cloud VPS | [vps_oracle/README.md](vps_oracle/README.md) |
| vps_gcp | GCP free-tier e2-micro（只纳管 `tofu/` 一层） | [vps_gcp/README.md](vps_gcp/README.md) |

其他背景/历史资料（故障记录、设计存档等，非日常操作必读）见 [`docs/README.md`](docs/README.md)。
