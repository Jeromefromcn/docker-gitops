---
name: inspector-check
description: 给 vps_oracle/host-native/inspector 新增或修改一个巡检 check。当需要「加一个巡检项」「让 inspector 检测 X」「补一个告警」，或某次故障复盘后决定补自动检测时使用。强制 checks/ 与 tests/ 一一配对。
---

# 新增一个 inspector 巡检 check

巡检脚本由 systemd timer 每天 09:00/21:00 跑一次，每轮必发一封 Telegram 报告。背景和分级设计见 [设计文档](../../../docs/superpowers/specs/2026-08-15-vps-oracle-inspector-design.md)。

## 铁律：一个 check 一个测试

`checks/<name>.sh` **必须**有对应的 `tests/test-<name>.sh`。CI（`.github/workflows/repo-conventions.yml`）会检查这个配对，缺了直接失败。先写测试再写实现。

## 1. 决定分级：auto 还是 alert

| 分级 | 含义 | 什么时候用 |
|---|---|---|
| `auto` | 检测到就自动清理 | 误判的代价可接受且可逆——dangling image、stopped container、build cache |
| `alert` | 只报告，等人决定 | **误判的代价不对称**——可能是某份数据的唯一副本，或需要人判断的系统状态。docker volume、Released PV、卡住的 Terminating pod 都是 alert |

拿不准就选 `alert`。

## 2. 写测试（先）

照 [`tests/test-k3s-released-pvs.sh`](../../../vps_oracle/host-native/inspector/tests/test-k3s-released-pvs.sh) 的模式：

- `source "$SCRIPT_DIR/lib.sh"` 拿 `assert_true` / `finish_tests`
- 在临时目录里写假的 `docker` / `kubectl` / `crictl` 脚本，`PATH` 前置注入——**测试必须是 hermetic 的**，绝不碰真实的 docker/k8s
- 破坏性的 stub 命令（`rm`/`rmi`/`prune`/`delete`）把 argv 追加到 `$STUB_DIR/calls.log`，测试断言「到底会执行什么」
- 时间相关的 fixture 用 `date -d '-30 minutes'` 在 stub 里现算，别写死时间戳

至少覆盖这几种情况：

- [ ] 该命中的命中了，且 detail 里有可操作的信息
- [ ] 不该命中的没命中（边界值两侧各一个）
- [ ] `auto` check：dry run 只提议不执行（`INSPECTOR_DRY_RUN=1`，断言 `calls.log` 不存在）
- [ ] `alert` check：**从不**产出 `deleted` / `would-delete`
- [ ] 依赖不可用时（kubeconfig 缺失、API 连不上）**发 alert，而不是静默跳过**
- [ ] 字段缺失/格式不对时降级成 `unknown` 或跳过，不让整个循环崩掉

## 3. 写 check

```bash
#!/usr/bin/env bash
# checks/<name>.sh
#
# <一句话说明检测什么>。<对应设计文档里的哪一行，以及分级理由>
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
```

- 输出一律走 `emit_result <tier> <action> <target> <detail>`，`tier` 是 `auto`/`alert`，`action` 是 `flagged`/`deleted`/`would-delete`
- 阈值走环境变量并给默认值：`"${INSPECTOR_XXX:-900}"`
- k3s 相关的 check 用 `${INSPECTOR_KUBECONFIG:-$INSPECTOR_STATE_DIR/kubeconfig}`，文件不存在时发 alert 提示跑 `k3s/setup-kubeconfig.sh`
- `set -e` **不要**用（`-uo pipefail` 即可）——单个条目处理失败不该中断整轮巡检

## 4. 挂进巡检主流程

确认 [`inspect.sh`](../../../vps_oracle/host-native/inspector/inspect.sh) 会发现这个新 check（看它是遍历目录还是有显式清单）。

## 5. 验证

```bash
cd vps_oracle/host-native/inspector/tests && ./test-<name>.sh
for t in test-*.sh; do [ "$t" = test-common.sh ] || ./"$t" >/dev/null || echo "FAIL $t"; done
```

全绿再提交。
