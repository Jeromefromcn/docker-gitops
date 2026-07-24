# docker-gitops

集中管理所有服务器上运行的 Docker Compose 配置，作为唯一可信来源（source of truth）。

## 目录结构

```
docker-gitops/
└── <host>/                # 按服务器分组，如 vps_oracle
    └── <service>/          # 每个服务一个目录
        └── docker-compose.yml
```

## 工作方式

仓库目录本身就是服务运行目录，直接在仓库里对应的服务目录下执行 compose 命令：

```bash
cd ~/jerome/docker-gitops/<host>/<service> && docker compose up -d
```

compose 文件里涉及的挂载卷统一用绝对路径（如 `/etc/x-ui/...`），因此工作目录搬到仓库里不影响容器内的数据位置。

## 新增一个服务

1. 在对应 `<host>/` 目录下新建 `<service>/docker-compose.yml`
2. 在该目录下 `docker compose up -d` 启动
3. `git add` + commit

## 约定

- 不提交任何密钥/密码/token。敏感配置放 `.env` 文件（已在 `.gitignore` 排除），compose 里通过 `env_file` 或环境变量引用
- 镜像版本尽量锁定具体 tag 或 digest，不用 `latest`
- 每次改动尽量小、单一职责，方便 review 和回滚
- 每个服务目录只放这一个服务相关的文件，不跨服务混放

## Host 列表

| Host | 说明 |
|---|---|
| vps_oracle | Oracle Cloud VPS |
