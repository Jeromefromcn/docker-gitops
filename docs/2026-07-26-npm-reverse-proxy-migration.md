# 2026-07-26 引入 nginx-proxy-manager，把服务迁到域名 + HTTPS 反代

一次从零搭反代、并把已有服务迁进去的完整记录。含 7 个坑，每个坑都能单独成文。

> **⚠️ 发表前须脱敏**：见文末[脱敏清单](#发表前须脱敏的内容)。本仓库是私有仓库，这里保留了完整细节。

---

## 一、背景与目标

改动前的状态：

- 一台 Oracle Cloud ARM VPS，上面跑着 `3x-ui`（VLESS + Reality 代理服务）
- 所有服务各自把端口 publish 到宿主机，靠"公网 IP + 非常规端口"访问
- 没有域名、没有 HTTPS，管理面板是明文 HTTP

目标：

1. 搭一个 nginx-proxy-manager（下称 NPM）作为统一的反代入口
2. 所有 HTTP(S) 服务改成走域名 + Let's Encrypt 证书
3. 服务自身不再对公网暴露端口，NPM 成为唯一入口

## 二、最终架构

```
                    公网
                     │
         ┌───────────┴───────────┐
         │                       │
    :80 / :443              :39876
         │                       │
    ┌────▼────┐                  │  VLESS + Reality
    │   NPM   │                  │  客户端直连，不经过 NPM
    │ (nginx) │                  │
    └────┬────┘                  │
         │  proxy 网络（容器名解析）│
    ┌────┴──────────────┐        │
    │                   │        │
  npm 自己           3x-ui ◄──────┘
  127.0.0.1:81    :46213 面板
                  :51234 订阅
```

| 域名 | 指向 | 说明 |
|---|---|---|
| `npm.jerome.cloudns.asia` | `127.0.0.1:81` | NPM 用自己反代自己的管理面板 |
| `panel.3x.jerome.cloudns.asia` | `3x-ui:46213` | 3x-ui 面板（走容器名） |
| `sub.3x.jerome.cloudns.asia` | `3x-ui:51234` | 订阅服务（走容器名） |
| — | `IP:39876` | VLESS 节点，协议要求直连，不走反代 |

宿主机对公网只保留：`22`（SSH）、`80`/`443`（NPM）、`39876`（节点）。

## 三、关键决策与理由

### 3.1 用一个共享的 external 网络，而不是每个服务各自的默认网络

```bash
docker network create proxy   # 手动创建一次，不属于任何 compose 的生命周期
```

每个要被反代的服务在自己的 compose 里：

```yaml
services:
  myapp:
    networks:
      - proxy        # ← 真正让这个容器挂上网卡的是这里

networks:
  proxy:
    external: true   # ← 这里只是声明"用已存在的那个，别新建"
```

**两层 `networks` 的区别**（很多人在这里含糊）：

- 顶层 `networks:` 是一份"网络名册"，只声明网络的来源/定义，不会让任何容器加入
- service 下的 `networks:` 才是真正给这个容器挂网卡
- 附带效果：service 一旦**显式写了** `networks:`，compose 就不再额外附加项目默认网络（`<project>_default`）

**好处**：NPM 里 Forward Hostname 直接填容器名（Docker 内置 DNS 解析），服务不用 publish 任何端口，容器重建 IP 变了也不用改配置。

### 3.2 哪些容器该加入 `proxy`

最初写 README 时，我按"新服务加入、老服务（3x-ui）保持现状"来划分——这是个偷懒的理由，被用户当场指出不成立。后来改成按原则划分：

- **默认**：有 HTTP(S) 服务、要被反代的容器，都加入
- **例外**：协议本身要求客户端直连的端口（VLESS/Reality 的原始握手端口），该 publish 就 publish——它从来就不是反代的对象
- **不加入**：纯后端、不对外提供服务的容器（数据库、worker），保持默认隔离

关键澄清：**加入 `proxy` 网络不会自动收回宿主机端口**。这是两件事，要一起做才有意义，只做前者只是多一条路、没少一条路。

### 3.3 管理面板不开公网端口，用 NPM 反代自己

NPM 管理面板在容器内监听 `81`，是**明文 HTTP**。三个方案的取舍：

| 方案 | 密码是否明文过公网 | 免 SSH 随时访问 |
|---|---|---|
| 直接 publish `81` 到公网 | ❌ 是 | ✅ |
| `127.0.0.1:81:81` + SSH 隧道 | ✅ 否 | ❌ 每次要开隧道 |
| **NPM 反代自己，走域名 + 443** | ✅ 否 | ✅ |

最终选第三种：Proxy Host 填 `127.0.0.1:81`，Scheme 填 `http`，SSL 走 Let's Encrypt。配好之后 compose 里的 `81` 端口映射完全删掉。

**Scheme 为什么填 `http` 而不是 `https`**：这一栏指的是 *NPM 去连后端* 用什么协议。浏览器→NPM 走 HTTPS（Force SSL），NPM→`127.0.0.1:81` 走 HTTP，因为 81 上根本没有 TLS 监听。填 `https` 会直接 502。

---

## 四、踩坑实录

### 坑 1：两层防火墙，本机全绿但外面进不来

**现象**：Let's Encrypt 申请证书失败。

```
Detail: 161.118.254.107: Fetching http://npm.jerome.cloudns.asia/.well-known/
acme-challenge/JXeYmV...: Timeout during connect (likely firewall problem)
```

**排查**：本机 `curl 127.0.0.1:80` 返回 200，iptables 里 80 也放行了——本机视角一切正常。

**根因**：云服务器有**两层独立的防火墙**，缺一层就不通：

1. **实例内的 iptables**——查出来只放行了 `22/8090/9090/3001/80`，**443 从来就没放行过**
2. **OCI 的 VCN Security List**——云平台级别，独立于 iptables，只能在控制台改

`80` 是被云平台那层挡住的，所以本机看着通、外部却超时。

**修复**：

```bash
sudo iptables -I INPUT 8 -p tcp --dport 443 -j ACCEPT
sudo netfilter-persistent save    # 不 save 重启就丢
```

加上在 OCI 控制台补 `80`/`443` 的 Ingress Rule。

**衍生问题：80 端口能不能平时关掉，只在申请证书时开？** 不能。Let's Encrypt 证书有效期 90 天，NPM 内置的续期定时器会自动重跑同一套 HTTP-01 验证，一样要走 80。关掉的话续期会**静默失败**，等发现时通常已经是证书过期、网站打不开了。80 上只有证书验证和 HTTP→HTTPS 跳转，没有敏感入口，常年开着风险很低。

### 坑 2：一个被广泛传播的错误说法（127.0.0.1 会死循环）

用户拿另一个 AI 的答复来对照：

> 因为你的 NPM 是运行在 Docker 容器内部的。在容器的视角里，127.0.0.1 代表的是"容器自己"，如果填 127.0.0.1，NPM 就会在容器内部无限循环请求自己，导致 502。

**这个说法是错的**，而且错得很有迷惑性——前半句（127.0.0.1 指向容器自己）是对的，结论却不成立。

**实测**：

```bash
$ docker exec npm curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:81/
200
```

秒回，没有任何循环。

**为什么不会循环**：NPM 容器里是**一个 nginx 进程管理多个虚拟主机**——一个监听 443（处理域名反代请求），另一个监听 81（管理后台）。443 转发到 `127.0.0.1:81` 是"从一个端口的监听器转发到另一个端口的监听器"，单跳转发，不是递归。

**真正会死循环的填法**：Forward 目标填域名自身，或者端口也填 443（443 转发到 443）。

> 这段很适合单独成文：**技术说法要用可执行的实验去证伪，而不是靠听起来合理**。一条 `docker exec ... curl` 就能终结争论。

### 坑 3：一个字符的 typo，报 502

证书签发成功后访问报 502。翻 nginx 错误日志：

```
127.0.01 could not be resolved (3: Host not found), client: ...,
server: npm.jerome.cloudns.asia, request: "GET / HTTP/1.1"
```

`127.0.01`——少了一个 `0`。nginx 把它当域名去解析，当然解析不出来。

**教训**：502 不要停在"502 = 后端挂了"，`proxy_host` 的错误日志会直接告诉你 nginx 到底在往哪连。日志路径：`/data/nginx/../logs/proxy-host-N_error.log`。

顺带发现日志里已经有扫描机器人在批量试探 `/​.env`、`/docker-compose.yml`、`/secrets.json`、`/credentials.json`——域名一上公网几分钟内就会被扫，这是常态。

### 坑 4：面板根路径 404

`https://panel.3x.jerome.cloudns.asia/` 返回 404，但反代链路是通的（TLS 握手成功、能拿到响应）。

3x-ui 出于安全考虑，面板不在根路径，而在一个自定义的 `webBasePath` 下。查数据库拿到确切值：

```bash
python3 -c "
import sqlite3
con = sqlite3.connect('/etc/x-ui/db/x-ui.db')
print(con.execute(\"SELECT key,value FROM settings WHERE key='webBasePath'\").fetchall())
"
```

**教训**：区分"反代不通"和"反代通了但路径不对"——前者拿不到响应，后者能拿到一个明确的 HTTP 状态码。

### 坑 5：订阅链接里还带着已经收回的内部端口

把订阅服务从 `51234` 收回宿主机后，面板生成的订阅链接仍然可能拼成 `https://sub.xxx:51234/sub/...`——那个端口已经不对外了，客户端拿到就是死链接。

查数据库确认：`subDomain` 空、`subURI` 空、`subPort` 还是 `51234`。

**修复**：面板 → Subscribe Settings → **Reverse Proxy URI** 填 `https://sub.3x.jerome.cloudns.asia/sub/`；Clash 那一栏对应填 `.../clash/`。这个字段会整体覆盖 `subDomain`/`subPort` 的拼接逻辑。

值得注意的是，**UI 自己的帮助文字已经把这个场景写清楚了**："if the subscription is reached through a reverse proxy on a different port, set 'Reverse Proxy URI' instead"。而当时的第一反应是去改上面那个 `Listen Port`——那是容器内部实际监听的端口，改了反而会让 NPM 连不上。

> 成文角度：**"改哪个字段"的直觉经常是错的——内部监听端口 vs 对外公布地址，是两个不能混的概念。**

### 坑 6：VPN 把自己的管理流量吃掉了（自环）

**现象**：面板间歇性 `ERR_CONNECTION_CLOSED`，刷新几次又能进。

**线索**：nginx access log 里，客户端 IP 显示为 `161.118.254.107`——**VPS 自己的公网 IP**。

**根因**：用户开着这台服务器自己的 VPN 在访问面板，形成了一个环：

```
浏览器 → VPN 隧道 → VPS → 从 VPS 出口绕回公网 → 打回 VPS 自己的 443 → nginx → 面板
```

这种"服务器代理自己"的路径本身就不稳定，间歇性断连是典型症状。

**修复**：在 Clash/Mihomo 的全局路由规则里加一条直连：

```
DOMAIN-SUFFIX,jerome.cloudns.asia,DIRECT
```

配在服务端订阅里，所有拉这份订阅的客户端自动生效，不用每台设备手动改。

> 成文角度：**自建代理的人几乎都会踩这个环**——管理后台的域名必须在自己的代理规则里走直连。

### 坑 7（压轴）：X-Forwarded-For 污染了节点地址

这是整个过程中最隐蔽、也最有文章价值的一个。

**现象演进**：先是"有的客户端能用有的不能用"，最后变成**所有客户端全部连不上**。

**服务端逐项排查，全部正常**：

- 容器 `healthy`，xray 进程活着（进程启动时间与 config 修改时间对得上，不是跑着旧配置的僵尸进程）
- Reality 私钥、`target`、`serverNames`、`shortIds` 全部正确
- 用私钥反推公钥，与客户端订阅里的完全一致
- fail2ban 零封禁，日志为空
- 用户从外部 `nc -zv <IP> 39876` → `succeeded`，**网络层完全通**

**中途的一次错误猜测**（值得写进文章）：我先怀疑是 OCI Security List 里 `39876` 那条规则被误删了——推理链看着很合理（"本机全绿、外部全断"、"今天刚动过 OCI 控制台"）。用户直接截图证明规则还在，猜测被证伪。**合理的推理链不等于正确的结论，让对方去验证比自己继续推演更快。**

**决定性线索**——客户端的实际报错：

```
dial tcp 203.185.15.62:39876: connect: connection refused
```

反查 `203.185.15.62` → `ctinets.com`，是**用户自己的 ISP 出口 IP**。再看订阅内容：

```yaml
proxies:
- name: sg-node-...
  server: 203.185.15.62   # ← 应该是服务器地址，却填成了客户端自己的 IP
  port: 39876
```

**根因**：

1. 迁移到 NPM 之后，NPM 按反向代理标准做法给后端带上 `X-Forwarded-For`（真实客户端 IP）——NPM 这么做是**正确**的
2. 3x-ui 生成节点链接时，错误地把这个"客户端 IP"当成了"服务器自己的地址"
3. 面板本来有一张 `hosts` 表专门用来**固定**节点对外地址，但它是**空的**，没有任何值去覆盖这个错误猜测

三个条件叠加，才导致订阅里的 `server` 字段变成了"谁来拉订阅就填谁的 IP"。

**为什么之前一直没问题**：以前客户端直连 `IP:端口` 拉订阅，根本不经过反代，压根走不到这条代码路径。**这是个只有"走反代"才会触发的潜伏 bug。**

**为什么我早期没发现**（方法论上的教训）：我在服务器上测试拉订阅时，"检测到的客户端 IP"恰好就是服务器自己的公网 IP，输出看起来完全正确——**测试的观察点本身掩盖了 bug**。同样的命令，从外部设备执行就能立刻暴露。

**修复**：面板 → Hosts → Add Host

| 字段 | 值 |
|---|---|
| Inbounds | `sg-node` |
| Address | `jerome.cloudns.asia`（用域名而非 IP，DDNS 换 IP 时不用改） |
| Port | `39876` |
| Security | `same`（继承现有 Reality 配置，不覆盖 SNI/密钥） |

其余 Host header / Path / Mux / Sockopt / Clash 等字段全部留空——那些是给 WS/gRPC/CDN 场景用的，原始 TCP + Reality 用不上。

---

## 五、沉淀下来的排查方法

1. **分层定位，逐层证伪**：本机监听 → 本机防火墙 → 云平台防火墙 → 协议层 → 客户端配置。每层用一条能给出明确结论的命令去测。
2. **注意观察点带来的偏差**：从服务器上测自己的公网服务，结论经常是误导性的（坑 1 的 80 端口、坑 7 的订阅内容，都栽在这上面）。**关键验证必须从外部设备做。**
3. **让报错自己说话**：`ERR_CONNECTION_CLOSED`、`502`、`404` 本身信息量很低；nginx 的 `proxy-host-N_error.log`、certbot 的 `letsencrypt.log`、客户端的 `dial tcp ... refused` 才是真线索。
4. **区分"连不上"的三种形态**：`timeout`（被墙/丢包）、`connection refused`（连到了但没人监听）、`能连上但握手失败`（协议/密钥问题）。坑 7 里正是 `refused` 这个词提示了"连到了一个错误的地址"。
5. **配置类问题直接查数据源**：面板 UI 未必展示全部字段，`sqlite3` 查 settings/hosts 表能一眼看到真实值。

## 六、遗留与待办

- **Telegram bot 409 冲突**：`Conflict: terminated by other getUpdates request`。只在保存设置触发重启的瞬间报，之后不复现，但提示可能有另一处在用同一个 bot token，未确认。
- **OCI 冗余端口未清理**：`58921`、`46213`、`51234` 本机已无监听，可以从 Security List 删掉。其中 `58921` 做过完整取证（git 历史、bash_history、journalctl、docker 事件、全盘配置搜索）**均无记录**，最接近的是已删除的 subconverter 服务用的 `58217`，推测是当年手滑打错的数字。
- **不加入 `proxy` 网络的服务如何反代**：可以用 `proxy` 网络的网关 IP `172.19.0.1`（实测可通，填宿主机公网 IP 不通）。更稳妥的是给 NPM 加 `extra_hosts: ["host.docker.internal:host-gateway"]`，用 `host.docker.internal` 代替硬编码 IP。目前未实施。
- **3x-ui 健康检查仍未验证真实 VLESS 握手**，沿用 [2026-07-24 事故记录](incidents/2026-07-24-3x-ui-vless-unreachable.md)的结论，未改进。

## 七、附：NPM / nginx / certbot 的分工

写文章时容易混淆，这里理清楚。**真正干活的始终是 nginx**，NPM 不参与任何网络和加密工作。

不用 NPM、纯手写要做的事：

1. `certbot certonly --webroot ...` 拿证书（走 ACME HTTP-01 验证）
2. 手写 `listen 443 ssl` 的 server 块，配 `ssl_certificate` / `ssl_certificate_key`，反代场景再加 `proxy_pass`
3. 另写 80 端口的 server 块做 301 跳转，并给 `/.well-known/acme-challenge/` 留出路径
4. `nginx -s reload`
5. 自己配 cron/systemd timer 跑 `certbot renew`，续完再 reload
6. 每加一个域名，1–5 全部重来一遍

NPM 做的事，全部是**自动化上面这些步骤**：

- 表单 → 自动生成 nginx 配置文件（`/data/nginx/proxy_host/N.conf`）
- 点按钮 → 后台代跑 certbot（日志里能看到完整命令行）
- 内置续期定时器（启动日志 `SSL Renewal Timer initialized`）替代 cron
- 每次改动自动 `nginx -t` + `nginx -s reload`

**TLS 终止**的概念也要讲清楚：加密只存在于"浏览器 → nginx"这一段，nginx → 后端通常仍是明文 HTTP。这就是坑 3 里 Scheme 要填 `http` 的原因。

---

## 发表前须脱敏的内容

本仓库私有，以下内容在公开文章里应替换为占位符：

| 类型 | 本文出现的值 | 建议替换为 |
|---|---|---|
| 公网 IP | `161.118.254.107` | `203.0.113.10`（文档示例段） |
| 域名 | `jerome.cloudns.asia` 及各子域名 | `example.com` |
| 面板自定义路径 | `webBasePath` 的真实值（本文已省略） | 保持不写，这是一层实际的安全屏障 |
| 节点端口 | `39876` | 可保留（已在文中说明是非常规端口），或改为 `xxxxx` |
| 客户端出口 IP | `203.185.15.62` | `198.51.100.20` |
| Reality 公钥 / UUID / subId | 本文已全部省略 | 保持不写 |

另外，坑 7 涉及 3x-ui 在反代场景下的地址推断缺陷，如果要写成公开文章，建议同时给出规避方法（配置 Hosts 表），避免读者照搬架构后踩同一个坑。
