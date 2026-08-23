# docs

这个仓库的知识分两层：**根 README 和各子目录 README 是"现在是什么样"的唯一权威**，这里放的是"为什么会这样/怎么走到这一步"，按需查，不是日常操作要先读的东西。

| 目录 | 放的是什么 | 什么时候来看 |
|---|---|---|
| [`incidents/`](incidents/README.md) | 故障排查记录，按时间倒序，含根因 | 遇到类似症状时先搜一遍，可能有现成根因 |
| [`misc/`](misc/README.md) | 跟日常运维无关的其他资料（上游反馈、外部报告等） | 基本不需要主动看 |
| `superpowers/plans/`、`superpowers/specs/` | 设计文档、实施计划，多为某个阶段的时间快照 | 深挖某个当前行为"当初为什么这么设计"时；**不代表现状**——现状看 README，这里的内容可能已被后续变更取代 |
| [`container-topology/`](container-topology/v3.md) | 历次容器部署拓扑快照（v1/v2/v3），每版记录当时的全量服务分布 | 想看某个时间点的整体架构长什么样；最新版本号最大 |
| [`2026-07-26-npm-reverse-proxy-migration.md`](2026-07-26-npm-reverse-proxy-migration.md) | 从零搭 NPM 反代、迁移已有服务的完整记录，含 7 个坑 | 排查 NPM 相关问题时可能有现成案例 |

`superpowers/plans/`、`superpowers/specs/` 里的文件不逐篇在这里列——数量太多（35+ 篇）且大部分内容已经被对应的 README 章节吸收；真正当前有效、还没被 README 覆盖的会从根 README 或 `vps_oracle/k3s/README.md` 里直接链接过去。找不到直接链接、又想深挖某个阶段的历史决策时，按文件名日期/关键词在这两个子目录里搜。
