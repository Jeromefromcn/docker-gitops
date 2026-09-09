---
name: npm-proxy-host
description: 在 Nginx Proxy Manager 里新建或修改一条反代记录（proxy host）。当需要给某个服务配置 <service>.jerome.cloudns.asia 域名、接入 NPM、申请/复用 SSL 证书、设置 access list，或反代到 k3s NodePort 时使用。包含 add-proxy-host.sh 脚本用法和三个已知会静默失败的坑。
---

# 给服务接入 NPM 反代

新增/修改一条 NPM 反代记录时，按下面的配置来，保持跟现有栈风格一致。

> NPM 已于 2026-08-21 从 2.12.3 升到 2.15.1，而 2.13.0 起换成了 React 新界面。下面的字段本身都还在，但位置/名称可能跟旧界面有出入——下次照着操作时如果对不上，顺手把这段改掉。

**没有 Custom Locations、不用反代到 k3s NodePort 的常规情况**，可以直接跑 [`vps_oracle/compose/npm/add-proxy-host.sh`](../../../vps_oracle/compose/npm/add-proxy-host.sh) 一次建好（含证书申请/复用、access list 按名字选、建完自动验证 SSL 设置没被静默重置），用法见 [`vps_oracle/compose/npm/README.md`](../../../vps_oracle/compose/npm/README.md) 的「用腳本一次建好 proxy host」一节。下面的字段表是这个脚本自动套用的值，也是手动走 UI/API 时的参照。

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
| Access List | 一律选 `self-only`（例外：**无内建鉴权的管理面板**用 `self-only-and-auth`，如 `cc-window`，见 `vps_oracle/host-native/cc-window/README.md`） |
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

**⚠️ 已知坑（反代到 k3s NodePort 时）**：Forward Hostname/IP 必须直接填宿主机内网 IP（目前是 `10.0.0.95`），不能填 `host.docker.internal` 或其他主机名——NPM 的 nginx 生成的 proxy_pass 配置走 Docker 内嵌 DNS resolver 动态解析，不读容器的 `/etc/hosts`/`extra_hosts`，填主机名会报 "could not be resolved" 导致 502。另外这个 IP 是 DHCP 分配的（`ip -4 addr show enp0s6` 显示 `dynamic`），不是静态 IP——如果 Oracle 换了地址，所有指向 NodePort 的反代会静默变成 502，排查前先确认这个 IP 有没有变。详见 [`vps_oracle/k3s/README.md`](../../../vps_oracle/k3s/README.md) 和 [`vps_oracle/compose/npm/docker-compose.yml`](../../../vps_oracle/compose/npm/docker-compose.yml) 里 `extra_hosts` 的注释。

**⚠️ 已知坑（API 改 `locations` 时可能不生效，且会静默失败）**：dify 迁移切流时发现，`PUT /api/nginx/proxy-hosts/{id}` 带上完整 `locations` 数组一起改，NPM 会把新值写进它自己的数据库（之后 `GET` 能读到新值），但生成 `/data/nginx/proxy_host/{id}.conf` 这一步没有跟着重新渲染——磁盘上的文件还是旧内容。若这份旧文件里引用的上游主机名此时已经解析不到（比如对应的 compose 容器已经 `stop`），`nginx -t` 会报 `host not found in upstream`，API 返回 `{"error":{"message":"Internal Error"}}`（500），重试也一样失败，此时 nginx 还在跑更早之前最后一次成功 reload 的配置——如果那份配置引用的容器也已经停了，站点对外直接 502，且**这个 502 不会自愈，卡在这个状态直到人工介入**。当时的修法：`docker exec npm cat /data/nginx/proxy_host/{id}.conf` 确认磁盘文件确实没跟着变，改用 `docker exec npm sed -i ...` 直接编辑这份文件（改成跟 API 已经写入数据库的值一致），`docker exec npm nginx -t` 验证语法，再 `docker exec npm nginx -s reload` 手动生效——数据库和磁盘配置两边最终还是一致的，只是靠人工把 NPM 自己没做完的那一步补上。**排查线索**：`docker logs npm` 里的 `nginx: [emerg] host not found in upstream "..."` 精确点出是哪个上游主机名解析失败；用这个失败的旧主机名去反查是不是某个已经停掉的 compose 容器。**规避建议**：以后要切换带多条 `locations` 的服务，考虑切流前**不要**提前停掉旧的 compose 容器（等确认 API 更新真的生效、`nginx -T` 里能看到新配置之后再停），或者切完之后立刻验证磁盘文件而不是只信任 API 返回值/数据库读值。

**⚠️ 约定：能不用 Custom Locations 就不用**

上面那条坑有一个跟切流无关、但严重得多的普遍形态。NPM 生成配置时，普通转发把上游主机名放进变量（`set $server "trilium";`），nginx 逐请求经 Docker 内嵌 DNS 解析，后端容器没了只是这一个站 502；但**每一条 Custom Location 都会把主机名写死进 `proxy_pass`**（NPM 的 `_location.conf` 模板），字面量上游必须在**载入配置时**就解析成功，否则 nginx 直接 `[emerg]` 拒绝启动——**全部反代站点一起挂**，不只是那一个。

而运行中的 nginx 靠先前解析到的位址继续跑，所以后端容器停掉之后，从监控、面板、日志全都看不出异常。它只在**下一次 nginx 冷启动**时引爆：宿主机重启、`docker compose up -d`、镜像升级——通常是一个跟它无关的时机。2026-08-21 升级 NPM 时就是这样炸的（dify 容器已经停了 45 小时，全站中断约 90 秒），来龙去脉见 [`vps_oracle/compose/npm/README.md`](../../../vps_oracle/compose/npm/README.md)。

所以：

- **路径分发优先交给服务自己的 nginx/网关做**，NPM 只做一条普通转发指向那一个容器。dify 之所以需要 8 条 Custom Location，正是因为这个仓库的 dify compose 里没有官方那个 `nginx` service。
- **停用一个 compose stack 时，同步在 NPM 里把对应的 proxy host disable 掉**。反代记录开着、后端却没了，就是在埋雷。
- 兜底：`vps_oracle/host-native/inspector/checks/npm-nginx-config.sh` 每天 09:00/21:00 跑一次 `nginx -t`，配置坏了会发 Telegram alert。它跑在独立行程里，不影响正在服务的 nginx，所以任何时候都可以手动跑一次确认：`docker exec npm nginx -t`。


## 收尾检查

1. **复查 SSL 标签页**——Force SSL / HTTP/2 有时会被静默重置回关闭，重新打开这条记录确认一次。
2. `docker exec npm nginx -t` 确认配置能载入（这一步能提前发现 Custom Locations 引入的字面量上游解析失败）。
3. 反代到 k3s NodePort 的，`curl -sS -o /dev/null -w 'HTTP %{http_code}\n' https://<service>.jerome.cloudns.asia/` 验证一次。
4. 新服务的话，别忘了 homepage 卡片——见 `add-service` skill。
