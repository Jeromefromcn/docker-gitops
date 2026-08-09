# vps_oracle/compose/provider-switch

切 Claude Code 后端 provider 的小 HTTP UI（单文件 stdlib，`app.py` + `status.py`）。挂在 `proxy` 网络上，NPM 反代成 `https://provider.jerome.cloudns.asia`（access list=self-only）。每次打开都实时重扫两组的 `.env` 状态 + 探测 CCR 可达性，点按钮原子改写 `/home/ubuntu/.claude-provider/<组>.env`。

整个分组切换系统（direnv + 分组 env + CCR + 本 UI + NPM）的完整文档、加新分组的步骤、四个坑、回滚等，见 [`../ccr/README.md`](../ccr/README.md)。
