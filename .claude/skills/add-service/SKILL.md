---
name: add-service
description: 在这个 GitOps 仓库里新增一个服务的完整流程——建 compose 栈、按需为共享资源（minio/postgres/redis）开 prod+dev 两套隔离池、接 NPM 反代、加 homepage 卡片、提交。当用户要「加一个新服务」「部署一个新应用」「新建一个 compose 栈」时使用。
---

# 新增一个服务

逐步执行，**每一步都不能跳**——漏掉 homepage 卡片或 NPM 记录是最常见的遗漏。

## 1. 建 compose 栈

在对应 `<host>/compose/` 下新建 `<compose>/docker-compose.yml`。写之前先读 [`.claude/rules/compose-conventions.md`](../../rules/compose-conventions.md)（编辑该路径下的文件时会自动载入）——时区、日志上限、端口最少暴露、`restart: unless-stopped`、`proxy` 网络、最小权限这几条都是硬约束，CI 会检查。

不需要对外暴露的服务**不要**挂到 `proxy` 网络上；需要的话也**不要**发布宿主机端口，统一走 NPM 反代到容器内部端口。

## 2. 共享资源：prod / dev 两套隔离池

如果这个服务要用到共享的 minio / postgres / redis，**开两套互相隔离的资源**，dev 那套名字加 `_dev` 后缀：

| 共享资源 | prod | dev |
|---|---|---|
| minio | `<name>` bucket | `<name>_dev` bucket |
| postgres | `<name>` 数据库 | `<name>_dev` 数据库 |
| redis | `<name>` ACL 用户 | `<name>_dev` ACL 用户 |

- postgres 建库走 [`vps_oracle/compose/postgres/init/init-databases.sh`](../../../vps_oracle/compose/postgres/init/init-databases.sh)。
- redis ACL 用户由 [`vps_oracle/compose/redis/scripts/gen-users-acl.sh`](../../../vps_oracle/compose/redis/scripts/gen-users-acl.sh) 从 `.env` 生成，生成物 `redis/users.acl` 含明文密码、已 gitignore，不要提交。
- 已存在的 notes / todo **不做追溯改造**，保持现状。

## 3. 启动

```bash
cd <host>/compose/<compose> && docker compose up -d
```

仓库目录就是运行目录，没有单独的部署路径。

## 4. 接 NPM 反代

用 `npm-proxy-host` skill。域名 `<service>.jerome.cloudns.asia`；如果这个服务同时要有 dev 环境，dev 用 `<service>.dev.jerome.cloudns.asia`。

## 5. 加 homepage 卡片

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
## 6. 提交

```bash
git add <host>/compose/<compose> vps_oracle/compose/homepage/config/services.yaml
git commit
```

一次 commit 一个改动。commit message 用英文（Conventional Commits）。

## 收尾自检

- [ ] compose 里有 `logging` / `TZ` / `restart: unless-stopped` / 固定的镜像 tag 或 digest
- [ ] 没有多余的宿主机端口发布
- [ ] 密钥在 `.env` 里，不在 compose 里
- [ ] NPM 记录建好，且**回头复查过** Force SSL / HTTP/2 没被静默重置
- [ ] homepage 卡片加了（安全敏感的服务除外，加之前先问）
- [ ] `python3 .github/scripts/check-compose-conventions.py` 通过
