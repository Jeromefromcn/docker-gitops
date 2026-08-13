# vps_oracle/compose/switchboard

通用的、配置驱动的开关 UI（stdlib，`app.py` + `config.py`）。挂在 `proxy` 网络上，NPM 反代成 `https://switchboard.jerome.cloudns.asia`（access list=self-only）。

引擎本身不知道任何具体开关是什么——它只读 `switches.ini` 拿到开关清单，对每个开关的 `switches/<id>/{status,on,off}.sh` 三个脚本发号施令：`GET /` 现场跑一遍每个开关的 `status.sh`（不缓存），`POST /toggle` 按当前状态跑 `on.sh` 或 `off.sh`。新增/删除开关只需要加/删一个 `switches/<id>/` 目录 + 三个脚本 + `switches.ini` 里的一个 section，不需要改 `app.py`/`config.py`（但如果新开关要用到新的宿主机路径或密钥，还得改 `docker-compose.yml` 的 volumes/environment 并重建镜像——不是纯配置就够）。设计细节见 [`../../../docs/superpowers/specs/2026-08-13-switchboard-generic-toggle-design.md`](../../../docs/superpowers/specs/2026-08-13-switchboard-generic-toggle-design.md)。

`status.sh` 的退出码是三态契约：exit 0 = **on**；exit 2 = **error**（脚本自己发现的异常，比如读配置文件时的权限错误——跟超时/脚本不存在一样归入 ERROR，绝不能被误读成"安全地关闭了"）；其余非 0 = **off**。`on.sh`/`off.sh` 只有两态：exit 0 = 成功，非 0 = 失败。

`status.sh` 的退出码是三态契约：exit 0 = **on**；exit 2 = **error**（脚本自己发现的异常，比如读配置文件时的权限错误——跟超时/脚本不存在一样归入 ERROR，绝不能被误读成"安全地关闭了"）；其余非 0 = **off**。`on.sh`/`off.sh` 只有两态：exit 0 = 成功，非 0 = 失败。

当前登记的开关：

| id | 说明 |
|---|---|
| `jerome-ccr` | jerome 组的 Claude provider 切换（Official ↔ CCR/智谱） |
| `bridget-ccr` | bridget 组的 Claude provider 切换（Official ↔ CCR/智谱） |

这两个开关所属的整个分组切换系统（direnv + 分组 env + CCR + 本 UI + NPM）的完整文档、加新分组的步骤、已知的坑、回滚等，见 [`../ccr/README.md`](../ccr/README.md)。
