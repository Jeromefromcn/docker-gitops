# provider-switch 通用化改造 — switchboard 设计文档

- 日期：2026-08-13
- 状态：设计已确认，待实施
- 涉及主机：vps_oracle
- 前置文档：[`2026-08-09-claude-provider-group-switch-design.md`](2026-08-09-claude-provider-group-switch-design.md)（provider-switch 的原始设计，本文档改造的对象）

---

## 1. 背景与动机

现有 `vps_oracle/compose/provider-switch/` 只做一件事：切 jerome/bridget 两组的 Claude provider（Official ↔ CCR）。开关的种类、数量都硬编码在 `status.py` 的 `GROUPS` 字典和 `app.py` 的 `toggle_group()` 里——加一个新开关就要改代码、重建镜像。

用户希望把这个容器改造成一个**通用的、配置驱动的开关框架**：读一个配置文件就知道有哪些开关，每个开关"打开"/"关闭"时调用什么逻辑也由配置决定。加/删任何开关都不需要改动引擎本身的代码，只需要写配置 + 挂逻辑脚本。这样将来任何"需要一个开关"的场景（例如某服务的 debug logging）都能复用同一套 UI/引擎，而不必每次都新起一个专门的小服务。

### 1.1 需求清单

| # | 需求 |
|---|---|
| R1 | 开关的增删只通过配置 + 脚本完成，不改动引擎代码 |
| R2 | 每个开关"打开/关闭"时执行什么逻辑，完全由使用者决定——脚本可以调用任何代码 |
| R3 | 沿用 provider-switch 的原则：UI 每次打开都现场查真实状态，不缓存、不假设 |
| R4 | 现有 jerome/bridget 的 CCR 切换功能原地保留，行为不变 |
| R5 | 服务改名为 `switchboard`，相关文档/引用同步更新 |

---

## 2. 方案取舍

**逻辑定义方式**：shell 脚本 vs Python handler 插件 vs HTTP webhook。选 shell 脚本——脚本可以调用任何语言、任何代码，扩展性最高，且和现有 `toggle_group()`"写文件"的实现方式天然契合，不需要为每种新逻辑类型都预先在引擎里注册一个 handler 类。

**改造范围**：原地改造 provider-switch（改名 switchboard）vs 新建独立服务。选原地改造——避免同时维护两套开关 UI、两条 NPM 反代、两张 homepage 卡片。

**脚本粒度**：每个开关 3 个独立脚本（`status.sh`/`on.sh`/`off.sh`）vs 1 个脚本 + 子命令参数。选 3 个独立文件——职责清楚，不会因为参数解析的 bug 让 `on` 误跑到 `off` 的逻辑。

---

## 3. 最终设计

### 3.1 目录结构

```
vps_oracle/compose/switchboard/
  app.py                 ← 通用引擎：HTTP handler、渲染、/toggle 分发
  config.py              ← 通用引擎：加载 switches.ini、执行 status/on/off、锁、超时
  switches.ini            ← 开关清单（提交进 git，不含密钥）
  switches/
    jerome-ccr/
      status.sh
      on.sh
      off.sh
    bridget-ccr/
      status.sh
      on.sh
      off.sh
  Dockerfile
  docker-compose.yml
  README.md
  test_app.py
  test_config.py
```

新增开关 = 新建 `switches/<id>/` 目录 + 3 个脚本 + 在 `switches.ini` 加一个 section + `docker compose up -d --build`（跟本仓库其他任何改动的部署方式一致，不需要热加载机制）。

### 3.2 `switches.ini` 结构

配置格式用 stdlib 的 `configparser`（INI），不用 YAML——本仓库这类小服务的既有约定是"纯标准库无框架"（见 `provider-switch/README.md`，`Dockerfile` 里也没有任何 `pip install` 步骤），引入 PyYAML 这样的第三方依赖会打破这条约定；`switches.ini` 这种扁平的 section+key=value 结构本来也不需要 YAML 的表达力，INI 反而更省心，还原生支持注释。

```ini
[jerome-ccr]
group = Provider          ; 可选，用于 UI 分组显示
label = jerome
on_label = CCR             ; 状态文字 + "Switch to X" 按钮文字都取自这里
off_label = Official

[bridget-ccr]
group = Provider
label = bridget
on_label = CCR
off_label = Official
```

section 名对应 `switches/<id>/` 目录名（即开关 id）。`group` 缺省时该开关不分组，单独一行显示。

### 3.3 每个开关的脚本契约

| 脚本 | 调用时机 | 契约 |
|---|---|---|
| `status.sh` | 每次 `GET /`（状态必须现场查，见 R3） | exit 0 = **on**；exit 2 = **error**（脚本自己发现的异常，比如读配置文件时的权限错误——跟超时/脚本不存在一样归入 ERROR，不当 off 处理）；其余非 0 = **off**。stdout 第一行（可选）作为 detail 文字显示在该行——用来承载原来写死的 endpoint/健康度信息，通用开关不一定有这类信息，留空即可。 |
| `on.sh` | `POST /toggle`，当前状态为 off 时 | exit 0 = 成功，非 0 = 失败。 |
| `off.sh` | `POST /toggle`，当前状态为 on 时 | 同上。 |

失败处理：
- `on.sh`/`off.sh` 失败（非 0 退出）→ 不静默跳转回 `/`，而是展示一个错误页面，带上截断后的 stderr。
- `status.sh` 失败/超时 → 该行显示 **ERROR**，不当作 off（一个坏掉的探测冒充"安全的关闭状态"比明确报错更危险），且隐藏该行的切换按钮（状态未知时不应该允许操作）。

### 3.4 引擎行为

- **并发探测**：一次 `GET /` 对所有开关的 `status.sh` 用线程池并发执行（`max_workers=8`），页面加载时间取决于最慢的一个探测，而不是所有探测时间之和——这条在开关数量增长后才会体现价值，现在两个开关也不会变慢。
- **锁**：引擎（不是脚本作者）在调用 `on.sh`/`off.sh` 前对该开关 id 加 `flock`，序列化并发的 `/toggle` 请求。锁文件放在 `switches/<id>/.lock`，跟 `status.py` 原来把锁放在 `env_path + ".lock"` 是同一个思路——锁挨着它保护的资源。
- **超时**：`status.sh` 5 秒，`on.sh`/`off.sh` 15 秒。超时按失败处理（见 3.3）。
- 所有脚本继承容器自身的环境变量（跟现在 `CCR_TOKEN` 走 `docker-compose.yml` 的 `environment` 一样），密钥不进 `switches.ini`。

### 3.5 UI

`render_page()` 的表格变为：`Group（如有）| Name | State | Detail | Action`。

- State/Action 按钮文字来自该开关的 `on_label`/`off_label`，不再是全局写死的 `PROVIDER_LABELS`。
- Detail 列显示 `status.sh` 输出的第一行，没有则留空（原来的 endpoint/健康度列被这一个通用字段取代）。
- ERROR 状态：红色 `ERROR` 文字，不渲染切换按钮。

### 3.6 jerome/bridget CCR 开关的迁移

现有 `toggle_group()` 按当前状态二选一分支的逻辑，拆成两个开关各 3 个脚本：

- `switches/jerome-ccr/status.sh`：读 `jerome.env` 判断 `ANTHROPIC_BASE_URL` 是否存在（对应现在的 `read_config`），再探测 CCR 连通性（对应 `check_connectivity`），把结果拼成 detail 文字（如 `"CCR http://127.0.0.1:3456 — reachable"` / `"... — UNREACHABLE"`）。
- `switches/jerome-ccr/on.sh`：写入 CCR 那两行 `export`（tmp 文件 + `rename` 原子替换，跟现在一致）。
- `switches/jerome-ccr/off.sh`：清空文件（写注释行）。
- `bridget-ccr` 三个脚本结构相同，路径换成 `bridget.env`。

两组脚本之间有一定重复（都是"读 env 文件 + 探测同一个 CCR + 原子写"），但换来每个开关自包含、互不影响、可以独立修改而不担心影响另一组——符合当前只有两个几乎相同用例的规模，不需要为此提前抽象出共享库。

### 3.7 改名（`provider-switch` → `switchboard`）影响范围

代码/配置侧（本次实施一起改）：

| 文件 | 改动 |
|---|---|
| 目录 `vps_oracle/compose/provider-switch/` | 整体改名为 `switchboard/` |
| `docker-compose.yml` | `container_name`、`image` 改为 `switchboard` |
| 根 `README.md` | `ccr` / `provider-switch` 那一行的服务名更新 |
| `vps_oracle/compose/ccr/README.md` | 目前是整个切换系统的主文档，含多处 `provider-switch` 专属操作步骤（如"编辑 `status.py` 的 `GROUPS` 字典"），需要重写成基于 `switches.ini` + `switches/<id>/` 目录的通用步骤 |
| `vps_oracle/k3s/apps/homepage/k8s/config/services.yaml` | homepage 卡片名称/描述更新 |

线上基础设施（**实施到这一步前，会单独再跟用户确认一次**，不在写代码的同时顺手做掉）：

- NPM 反代：`provider.jerome.cloudns.asia → provider-switch:8091` 改为 `switchboard.jerome.cloudns.asia → switchboard:8091`（新建 proxy host + 新证书 + access list=self-only，旧的下线）。

---

## 4. 测试策略

| 层 | 方法 |
|---|---|
| 引擎（`config.py`） | 临时目录 + 极简假脚本（`exit 0`、`printf`）模拟 `switches/<id>/`，断言 `switches.ini` 解析、并发探测、锁、超时、失败展示的行为——取代现在 `test_status.py` 里手写的 `GROUPS` |
| HTTP（`app.py`） | 起服务，用临时 `switches.ini` + 假脚本目录 monkeypatch 配置来源，curl `/` 和 `/toggle`，断言页面内容和 `.lock`/开关脚本的调用——延续现在 `test_app.py` 的 `TestDoPostWiring` 模式 |
| 真实脚本（`jerome-ccr`/`bridget-ccr`） | 脚本本身很薄（几行 shell），不做单元测试，沿用 `ccr/README.md` 现有的 `curl` 验证方式做手工/集成验证 |

---

## 5. 已知约束与风险

| # | 事项 | 说明 |
|---|---|---|
| C1 | 脚本以容器内 uid 1001 运行，能碰到的宿主机路径取决于 `docker-compose.yml` 挂的 volume | 新开关如果需要访问新的宿主机路径，要在 compose 文件里显式加 volume——这是一次基础设施改动，不是"纯配置"，需要重建容器。刻意不做成"挂载 `docker.sock`"或宽泛权限来图方便：一个网页按钮能直接控制所有其他容器的风险面太大，不做这个默认选项 |
| C2 | `status.sh` 失败与"关闭"是两种不同状态 | 引擎必须能区分 ERROR 和 off，否则一个坏探测会被误读成"安全地关闭了"（3.3/3.4） |
| C3 | 两组 CCR 脚本有重复 | 当前规模下（2 个几乎相同的开关）不值得为此抽共享库，等出现第三个同构用例再考虑 |
| C4 | 改名涉及线上 NPM 反代/证书 | 属于共享基础设施改动，执行前需再次确认（3.7） |

---

## 6. 开放项

无——本次讨论中的实现细节（超时秒数、线程池大小、锁文件位置）已在设计中给出默认值，实施时如证明不合适可以直接调整，不影响整体架构。
