#!/usr/bin/env bash
# Register a Telegram notification webhook for a specified (or all) Vikunja project, forwarding to vikunja-notify-relay
# (which assembles an HTML message with the project name/task title/task hyperlink, then forwards per Vikunja account
#  to the apprise vikunja-tg-{username} persisted config — one target per account, not a shared one).
#
# Preconditions:
#   - the apprise container has already stored a tgram:// target for each Vikunja account via `POST /add/vikunja-tg-<username>` (see docs/2026-08-03-vikunja-apprise-telegram-webhooks.md)
#   - vikunja's docker-compose.yml has VIKUNJA_OUTGOINGREQUESTS_ALLOWNONROUTABLEIPS=true and it's been `up -d`-ed
#   - vps_oracle/vikunja-notify-relay has been `docker compose up -d`-ed
#   - this machine can run `docker run --network proxy curlimages/curl` (for container-to-container calls, without depending on a host-installed curl)
#
# Usage:
#   VIKUNJA_TOKEN=tk_xxx ./register-telegram-webhooks.sh            # applies to all real projects (excludes pseudo-projects like -2/-4)
#   VIKUNJA_TOKEN=tk_xxx ./register-telegram-webhooks.sh 5 7 12     # applies only to the specified project ids
#
# After creating a new project, re-run with the new id to add its webhook (this version of Vikunja's API token
# has no access to the global webhook permission under /api/v1/user/settings/webhooks, so registration is per
# project only — see the doc for details).

set -euo pipefail

: "${VIKUNJA_TOKEN:?VIKUNJA_TOKEN environment variable must be set (generated in Vikunja Settings > API Tokens)}"

RELAY_URL="http://vikunja-notify-relay:8080/"

# All four events go to the same relay address; the relay formats them by the event_name in the payload.
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
