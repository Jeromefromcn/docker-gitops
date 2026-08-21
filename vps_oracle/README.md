# vps_oracle

Oracle Cloud VPS 上跑的服务。

## 服务器信息

- 域名：`jerome.cloudns.asia`（DDNS，解析到本机）
- 当前 IP：`161.118.254.107`（IP 会变，以域名解析结果为准，这里仅记录最近一次已知值）

## 目录结构

这台机器上不是只有 docker compose，`vps_oracle/` 下每个子目录是各自独立的 scope：

| 目录 | 管的是什么 | 约定见 |
|---|---|---|
| `compose/` | docker compose 栈，每个子目录就是该栈的工作目录 | 根 [README.md](../README.md) |
| `k3s/` | K3s 云原生实验平台（Cilium / ArgoCD / Istio Ambient / Kyverno / Trivy / Sealed Secrets + `lab-environment`、`headlamp`、`pr-lanes` 三个负载），一律走 GitOps，不手动 `kubectl apply` | [k3s/README.md](k3s/README.md) |
| `inspector/` | 宿主机巡检脚本 + systemd timer，跨 docker 与 k3s 两侧做只读体检 | [inspector/README.md](inspector/README.md) |
| `host-firewall/` | 宿主机 iptables 规则脚本（`INPUT` 默认 REJECT，逐条放行） | 脚本自身注释 |
| `npm-nodeport-relay/` | host netns 里的 TCP relay，补上 NPM 容器到 k3s NodePort 的可达性 | [npm-nodeport-relay/README.md](npm-nodeport-relay/README.md) |

下面的网络约定只适用于 `compose/`；k3s 侧的网络（Cilium pod network、NodePort、NPM 反代到 NodePort 的坑）见 `k3s/README.md` 和根 README。

## 网络

统一用一个共享的 external Docker 网络做反代入口：

```bash
docker network create proxy
```

这个网络不属于任何一个服务的 compose 生命周期，手动创建一次，长期存在，`docker compose down` 不会把它删掉。

- **nginx-proxy-manager**（[compose/npm/](compose/npm/)）：唯一对外暴露 80/443 的入口，加入了 `proxy` 网络。

- **默认规则：有 HTTP(S) 服务、要被 NPM 反代的容器，都加入 `proxy` 网络**，不发布端口给宿主机，NPM 里直接用容器名当 Forward Hostname/IP，例如：

  ```yaml
  networks:
    - proxy

  networks:
    proxy:
      external: true
  ```

  好处：服务本身不暴露端口，NPM 是唯一入口，攻击面最小；地址用容器名解析，重建容器也不用改配置。这是默认做法，不因为服务"新"或"旧"而例外。

- **例外：协议本身要求客户端直连、不是 HTTP、没法走 NPM 反代的端口**（比如 VPN 节点的原始握手端口）：这类端口该发布到宿主机就发布，跟加不加入 `proxy` 网络无关——它们从来就不是 NPM 反代的对象。如果同一个服务里还有 HTTP 部分（比如管理面板、订阅接口），那部分仍然按上面默认规则走 `proxy` + 容器名。

- **纯后端、不对外提供服务、不需要被反代的容器**（数据库、内部 worker 等）：不要加入 `proxy` 网络，保持默认隔离，避免被同网络里的其他容器直接访问到。
