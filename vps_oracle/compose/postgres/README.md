# postgres

统一 PostgreSQL 实例 + pgAdmin 4 Web 管理界面，供用户自己开发的未来应用使用。

每个应用一个独立 database + 独立 role（应用用自己 role 连接、只看得见自己的库），按库 `pg_dump` 备份。

**范围**：三方服务（dify 自带 `postgres:15` + `pgvector:pg16`、k3s lab-environment `postgres:16`、repo 外 love-bird-boss `postgres:16`）**不迁移到这里**，各自维持现状。本栈只服务用户自建应用。

## 架构

| container_name | role | 网络 | 宿主端口 |
|---|---|---|---|
| `postgres` | 统一 PG 实例（`postgres:17-alpine`），纯后端 | 仅 `default` | 无（不对外） |
| `pgadmin` | pgAdmin 4 Web 管理界面 | `default` + `proxy` | 无（只走 NPM） |

- `postgres` 只挂 `default` 网络、不发布端口 —— 纯后端，不进 `proxy`（仓库约定）。
- `pgadmin` 挂 `default`（连 postgres）+ `proxy`（让 NPM 反代），不发布宿主端口，管理面板只走 NPM。

## 给服务接入 NPM 反代

在 NPM panel 手动建 proxy host（仓库约定：NPM 配置是文档化操作，不提交配置文件）：

**Details 标签页**

| 字段 | 值 |
|---|---|
| Domain Names | `pgadmin.jerome.cloudns.asia` |
| Scheme | `http` |
| Forward Hostname / IP | `pgadmin`（容器名，走 proxy 网络，Docker DNS 解析） |
| Forward Port | `80` |
| Cache Assets | Off |
| Block Common Exploits | On |
| Websockets Support | On |
| Access List | `self-only` |

**SSL 标签页**：Domain 新建证书，Email `jeromefromcn@gmail.com`，Force SSL / HTTP/2 On，HSTS Off。

> ⚠️ **已知坑**：创建时打开的 Force SSL / HTTP/2 Support 保存后可能被静默重置回关。保存后重新打开这条记录复查一遍，发现关了再勾一次并保存。

## 给新服务加 homepage 卡片

本栈没有对外暴露的"服务主页"（pgAdmin 是管理面板），按仓库约定管理面板也放卡片。在 `vps_oracle/compose/homepage/config/services.yaml` 的 `Infra Services` 分类下加：

```yaml
    - PostgreSQL Admin:
        icon: si-postgresql
        href: https://pgadmin.jerome.cloudns.asia
        description: PostgreSQL admin (unified instance)
```

## 首次安装

```bash
cd /home/ubuntu/jerome/docker-gitops/vps_oracle/compose/postgres
cp .env.example .env        # 填入真实密码/邮箱
# 确保 proxy 网络已建（仓库 README 有 docker network create ...）
docker compose up -d
```

验证：

```bash
docker compose ps                       # postgres healthy, pgadmin running
docker exec postgres pg_isready         # 就绪
docker exec postgres psql -U postgres -c '\l'   # 应看到 app_notes / app_todo
```

## 怎么加一个新应用（复制即可）

每个自建应用 = 一个 role + 一个 database。在 `init/init-databases.sh` 里加一行：

```bash
create_role_and_db "app_name"
```

**但注意**：`/docker-entrypoint-initdb.d/` 只在**首次初始化（空数据目录）**时执行。已运行过的实例要这样补：

```bash
# 在容器里建 role + db（与脚本逻辑一致，幂等可重跑）
docker exec -i postgres psql -U postgres -v ON_ERROR_STOP=1 <<'SQL'
DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='app_name') THEN
    CREATE ROLE app_name LOGIN PASSWORD 'change-me';
  END IF;
END $$;
SELECT 'CREATE DATABASE app_name OWNER app_name'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname='app_name')\gexec
SQL
```

然后把 `create_role_and_db "app_name"` 追加进 `init/init-databases.sh`，保证未来重建数据目录时仍幂等。

应用连接串：`postgres://app_name:<password>@postgres:5432/app_name`（`postgres` 容器名，走同一 compose 网络的 `default` 网络）。

## 备份

按库 `pg_dump`（逻辑备份）。脚本 `scripts/backup-databases.sh` 在**宿主**用 cron 调度（与 `monitoring/scripts/check-sync.sh` 同款模式；cron 条目只放宿主，不提交）：

```cron
30 2 * * * /home/ubuntu/jerome/docker-gitops/vps_oracle/compose/postgres/scripts/backup-databases.sh
```

- 输出：`/etc/postgres/backups/<db>/<db>-YYYYMMDD.sql`，每库保留最近 14 份
- `pg_dump` 不含 role 等集群级对象 —— roles 由 `init/init-databases.sh` 声明式管理；需要时用 `pg_dumpall -g` 单独导出
- 三方 PG（dify / love-bird-boss / lab-env）的备份**不在此栈范围**，另行处理

## 坑

- **initdb 只跑一次**：`init/init-databases.sh` 只在首次初始化执行，之后加应用要手动补跑（见上文），同时把行加回脚本保持声明式。
- **pgAdmin 只管本栈**：`pgadmin` 只连 `default` 网络，够不着宿主机其他 PG 实例（它们各自在别的 compose 网络或带宿主端口）。这是有意的 —— 三方服务暂不迁移，也不扩大 pgAdmin 攻击面。
- **访问控制**：NPM Access List 设 `self-only`，管理面板不要对外网开放。
- **版本**：本栈 `postgres:17-alpine`（pin digest）。跟现有三方 PG 版本（15/16）不同，互不干扰。
