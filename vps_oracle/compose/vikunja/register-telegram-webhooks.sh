#!/usr/bin/env bash
# 给指定（或全部）Vikunja project 注册 Telegram 通知 webhook，转发给 vikunja-notify-relay
# （拼好项目名/任务标题/任务超链接的 HTML 消息后，再转发给 apprise 的 vikunja-tg 持久化配置）。
#
# 前提：
#   - apprise 容器已用 `POST /add/vikunja-tg` 存好 tgram:// 目标（见 docs/2026-08-03-vikunja-apprise-telegram-webhooks.md）
#   - vikunja 的 docker-compose.yml 已加 VIKUNJA_OUTGOINGREQUESTS_ALLOWNONROUTABLEIPS=true 并 up -d 过
#   - vps_oracle/vikunja-notify-relay 已经 docker compose up -d 过
#   - 本机能跑 `docker run --network proxy curlimages/curl`（用于容器间调用，不依赖宿主机装 curl）
#
# 用法：
#   VIKUNJA_TOKEN=tk_xxx ./register-telegram-webhooks.sh            # 对所有真实 project（排除 -2/-4 这类伪 project）生效
#   VIKUNJA_TOKEN=tk_xxx ./register-telegram-webhooks.sh 5 7 12     # 只对指定 project id 生效
#
# 新建 project 后，对新 id 重跑一次即可补上 webhook（本版本 Vikunja 的 API token 拿不到
# /api/v1/user/settings/webhooks 的全局 webhook 权限，只能逐 project 注册，见文档里的说明）。

set -euo pipefail

: "${VIKUNJA_TOKEN:?必须设置 VIKUNJA_TOKEN 环境变量（Vikunja Settings > API Tokens 生成）}"

RELAY_URL="http://vikunja-notify-relay:8080/"

# 四个事件都发到同一个 relay 地址，relay 自己根据 payload 里的 event_name 分流格式化。
EVENTS=("task.assignee.created" "task.reminder.fired" "task.overdue" "task.updated")

curl_v() {
  docker run --rm --network proxy curlimages/curl:8.10.1 -s "$@"
}

if [ "$#" -gt 0 ]; then
  PROJECT_IDS=("$@")
else
  mapfile -t PROJECT_IDS < <(
    curl_v -H "Authorization: Bearer ${VIKUNJA_TOKEN}" http://vikunja:3456/api/v1/projects \
      | python3 -c "import sys,json;[print(p['id']) for p in json.load(sys.stdin) if p['id'] > 0]"
  )
fi

for PID in "${PROJECT_IDS[@]}"; do
  echo "=== project ${PID} ==="
  for EVENT in "${EVENTS[@]}"; do
    STATUS=$(curl_v -X PUT -H "Authorization: Bearer ${VIKUNJA_TOKEN}" -H "Content-Type: application/json" \
      -d "{\"target_url\":\"${RELAY_URL}\",\"events\":[\"${EVENT}\"]}" \
      -o /dev/null -w "%{http_code}" \
      "http://vikunja:3456/api/v1/projects/${PID}/webhooks")
    echo "  ${EVENT}: ${STATUS}"
  done
done
