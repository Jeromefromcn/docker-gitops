# vps_oracle/compose/redis

统一 Redis 实例,给用户自己搭的服务用。**第三方自带 Redis 的服务(如 dify 的 `dify-redis`)保持各自独立实例,不迁移到这里**——和统一 Postgres 的取舍一致(见 `../postgres/README.md`)。

## 隔离模型:一个共享实例 + 每应用一个 ACL 用户

用 **Redis ACL 用户 + key 前缀命名空间** 做隔离,而不是每个应用起一个实例:

- 每个应用一个 ACL 用户,形如 `user notes on ><password> ~notes:* +@all`
- `~<prefix>:*` 限定该用户**只能访问** `<prefix>:` 前缀下的 key
- 应用 A 的进程**在权限层面**读写不了应用 B 的 key——不是靠"约定各自别用对方前缀",而是 Redis 强制
- 一个实例、一份数据目录、一个管理界面,资源开销最小
- 若某应用需要完全隔离(独立内存上限、要 `FLUSHALL` 等),再给它单独起一个实例

## 结构

```
redis/
├── docker-compose.yml        # redis + redisinsight 两个服务
├── .env.example              # 模板(复制成 .env 填真实值)
├── redis/
│   ├── redis.conf            # 共享实例配置(persistence / maxmemory)
│   └── users.acl             # 【生成物,gitignored】每应用一个 ACL 用户
└── scripts/
    └── gen-users-acl.sh      # 从 .env 生成 users.acl
```

- `redis` :统一实例。`default` 网络纯后端,无发布端口、不挂 proxy。应用容器加入 `default` 网络,连 `redis:6379`。
- `redisinsight`:管理界面(Redis 官方 GUI)。挂 `proxy` 网络走 NPM,无内建鉴权 → 挂 `self-only-and-auth`(Basic Auth)。未发布宿主端口。

## 首次部署顺序

```bash
cd vps_oracle/compose/redis
cp .env.example .env          # 填 REDIS_PASSWORD / REDISINSIGHT_PASSWORD / 各 APP_*_PASSWORD
./scripts/gen-users-acl.sh    # 生成 redis/users.acl(含真实密码,gitignored)
docker compose up -d
```

> 必须先跑 `gen-users-acl.sh` 再 `up -d`——compose 把 `./redis/users.acl` 只读挂载进容器,文件不存在会导致 redis 启动失败。

## 怎么加一个新应用

1. `.env` 加两块:
   ```
   APP_<NAME>_PASSWORD=...
   APP_<NAME>_KEY_PREFIX=<prefix>   # 建议用应用名,如 notes / todo
   ```
2. `./scripts/gen-users-acl.sh` 重新生成 `users.acl`
3. `docker compose restart redis`
4. 把应用容器加入 redis 栈的 `default` 网络,连 `redis:6379`,用 `<name>` 用户 + 对应密码,key 统一加 `<prefix>:` 前缀

## 管理界面

`https://redisinsight.jerome.cloudns.asia`(NPM 反代,`self-only-and-auth` 访问列表 + Basic Auth)。连 redis 时用对应应用的 ACL 用户,选 **Add Redis Database** → Host: `redis`,Port: `6379`,Username: 应用名,Password: 对应密码。

## 运维

- 数据:bind mount `/etc/redis/data`(AOF + RDB,见 `redis.conf`)
- 备份:redis 不单列备份脚本;依赖实例数据 + 现有备份流程(如需纳入,见 `../postgres/scripts/` 的备份模式)
- 应用侧用哪个用户连,就只能看见/操作哪个 `~<prefix>:` 下的 key
