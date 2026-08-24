#!/usr/bin/env bash
# 一次建好一條 NPM 反代記錄：mint token → 查 access list id → 建/複用憑證 → 建 proxy host →
# 驗證 ssl_forced/http2_support 沒被靜默重置 → nginx -t。全程在同一個 shell 進程內完成，
# token 不用跨命令傳遞——見 README「用腳本一次建好 proxy host」一節的說明。
#
# 前提：
#   - 本機（VPS）能跑 `docker run --network proxy curlimages/curl`，且裝了 jq
#   - vps_oracle/compose/npm/.npm-automation.env 存在（自動化帳號，僅 Proxy Hosts: Manage 權限）
#
# 用法：
#   ./add-proxy-host.sh <service>.jerome.cloudns.asia <forward-host> <forward-port> [self-only|self-only-and-auth]
#   第 4 個參數預設 self-only；無內建鑑權的管理面板要傳 self-only-and-auth（見根 README 的規則）
#
# 不做的事：
#   - domain 已經有 proxy host 就直接報錯退出，不做覆蓋更新
#   - 不支援 Custom Locations（repo 約定盡量不用，見根 README「能不用 Custom Locations 就不用」）
#   - 不會自動加 homepage 卡片，跑完會提醒，需另外編輯 vps_oracle/compose/homepage/config/services.yaml

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/.npm-automation.env"

if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
  echo "用法: $0 <domain> <forward-host> <forward-port> [self-only|self-only-and-auth]" >&2
  exit 1
fi

DOMAIN="$1"
FORWARD_HOST="$2"
FORWARD_PORT="$3"
ACCESS_LIST_NAME="${4:-self-only}"

if [[ "$ACCESS_LIST_NAME" != "self-only" && "$ACCESS_LIST_NAME" != "self-only-and-auth" ]]; then
  echo "錯誤: 第 4 個參數只能是 self-only 或 self-only-and-auth，收到「${ACCESS_LIST_NAME}」" >&2
  exit 1
fi

if ! [[ "$FORWARD_PORT" =~ ^[0-9]+$ ]]; then
  echo "錯誤: forward-port 必須是數字，收到「${FORWARD_PORT}」" >&2
  exit 1
fi

CURL_IMAGE="curlimages/curl:8.10.1"
NPM_BASE="http://npm:81"

curl_v() {
  docker run --rm --network proxy "$CURL_IMAGE" -sS "$@"
}

echo "==> minting NPM API token"
TOKEN=$(curl_v -X POST "${NPM_BASE}/api/tokens" \
  -H 'Content-Type: application/json' \
  -d "{\"identity\":\"${NPM_AUTOMATION_EMAIL}\",\"secret\":\"${NPM_AUTOMATION_PASSWORD}\"}" | jq -r '.token')

if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
  echo "錯誤: mint token 失敗，檢查 .npm-automation.env 帳密/權限" >&2
  exit 1
fi

auth_curl() {
  curl_v -H "Authorization: Bearer ${TOKEN}" "$@"
}

echo "==> resolving access list id for ${ACCESS_LIST_NAME}"
ACCESS_LIST_ID=$(auth_curl "${NPM_BASE}/api/nginx/access-lists" | jq -r --arg name "$ACCESS_LIST_NAME" '.[] | select(.name == $name) | .id')
if [ -z "$ACCESS_LIST_ID" ]; then
  echo "錯誤: 在 NPM 裡找不到名叫 ${ACCESS_LIST_NAME} 的 access list" >&2
  exit 1
fi
echo "    ${ACCESS_LIST_NAME} -> id ${ACCESS_LIST_ID}"

echo "==> checking existing proxy hosts for ${DOMAIN}"
EXISTING_HOST_ID=$(auth_curl "${NPM_BASE}/api/nginx/proxy-hosts" | jq -r --arg d "$DOMAIN" '.[] | select(.domain_names[]? == $d) | .id')
if [ -n "$EXISTING_HOST_ID" ]; then
  echo "錯誤: ${DOMAIN} 已經有 proxy host（id ${EXISTING_HOST_ID}），本腳本不做覆蓋更新，改用 NPM UI 或根 README 的手動 API 流程" >&2
  exit 1
fi

echo "==> checking existing certificates for ${DOMAIN}"
CERT_ID=$(auth_curl "${NPM_BASE}/api/nginx/certificates" | jq -r --arg d "$DOMAIN" '[.[] | select(.domain_names[]? == $d)] | first | .id // empty')

if [ -n "$CERT_ID" ]; then
  echo "    找到既有憑證 id ${CERT_ID}，複用"
else
  echo "==> requesting new Let's Encrypt certificate for ${DOMAIN}"
  CERT_RESPONSE=$(auth_curl -X POST "${NPM_BASE}/api/nginx/certificates" \
    -H 'Content-Type: application/json' \
    -d "{\"provider\":\"letsencrypt\",\"domain_names\":[\"${DOMAIN}\"],\"meta\":{\"dns_challenge\":false}}")
  CERT_ID=$(echo "$CERT_RESPONSE" | jq -r '.id // empty')
  if [ -z "$CERT_ID" ]; then
    echo "錯誤: 建證書失敗: $CERT_RESPONSE" >&2
    exit 1
  fi
  echo "    新證書 id ${CERT_ID}"
fi

echo "==> creating proxy host"
HOST_BODY=$(jq -n \
  --arg domain "$DOMAIN" \
  --arg fhost "$FORWARD_HOST" \
  --argjson fport "$FORWARD_PORT" \
  --argjson cert "$CERT_ID" \
  --argjson acl "$ACCESS_LIST_ID" \
  '{
    domain_names: [$domain],
    forward_scheme: "http",
    forward_host: $fhost,
    forward_port: $fport,
    certificate_id: $cert,
    ssl_forced: true,
    hsts_enabled: false,
    hsts_subdomains: false,
    http2_support: true,
    block_exploits: true,
    caching_enabled: false,
    allow_websocket_upgrade: true,
    access_list_id: $acl,
    advanced_config: "",
    locations: []
  }')

HOST_RESPONSE=$(auth_curl -X POST "${NPM_BASE}/api/nginx/proxy-hosts" \
  -H 'Content-Type: application/json' \
  -d "$HOST_BODY")
HOST_ID=$(echo "$HOST_RESPONSE" | jq -r '.id // empty')
if [ -z "$HOST_ID" ]; then
  echo "錯誤: 建 proxy host 失敗: $HOST_RESPONSE" >&2
  exit 1
fi
echo "    proxy host id ${HOST_ID}"

echo "==> verifying ssl_forced / http2_support 沒被靜默重置"
VERIFY=$(auth_curl "${NPM_BASE}/api/nginx/proxy-hosts/${HOST_ID}")
SSL_OK=$(echo "$VERIFY" | jq -r '.ssl_forced')
HTTP2_OK=$(echo "$VERIFY" | jq -r '.http2_support')

if [ "$SSL_OK" != "true" ] || [ "$HTTP2_OK" != "true" ]; then
  echo "    偵測到已知坑（保存後被靜默重置），重新 PUT 修回去"
  auth_curl -X PUT "${NPM_BASE}/api/nginx/proxy-hosts/${HOST_ID}" \
    -H 'Content-Type: application/json' \
    -d '{"ssl_forced":true,"http2_support":true}' > /dev/null
  VERIFY=$(auth_curl "${NPM_BASE}/api/nginx/proxy-hosts/${HOST_ID}")
  SSL_OK=$(echo "$VERIFY" | jq -r '.ssl_forced')
  HTTP2_OK=$(echo "$VERIFY" | jq -r '.http2_support')
  if [ "$SSL_OK" != "true" ] || [ "$HTTP2_OK" != "true" ]; then
    echo "警告: 修復後仍未生效，請手動到 NPM UI 檢查 ${DOMAIN}" >&2
  else
    echo "    修復成功"
  fi
fi

echo "==> nginx -t"
if docker exec npm nginx -t; then
  echo "    OK"
else
  echo "警告: nginx -t 失敗，檢查 docker logs npm" >&2
fi

cat <<SUMMARY

=== 完成 ===
domain:       ${DOMAIN}
forward:      http://${FORWARD_HOST}:${FORWARD_PORT}
access list:  ${ACCESS_LIST_NAME} (id ${ACCESS_LIST_ID})
certificate:  id ${CERT_ID}
proxy host:   id ${HOST_ID}

別忘了：
  - 若這是新服務，補一張 homepage 卡片：vps_oracle/compose/homepage/config/services.yaml
  - Custom Locations、k3s NodePort 等特殊情況本腳本不處理，見根 README「给服务接入 NPM 反代」
SUMMARY
