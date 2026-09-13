#!/usr/bin/env bash
# Create one NPM reverse-proxy record in one go: mint token → look up access list id →
# create/reuse certificate → create proxy host → verify ssl_forced/http2_support weren't
# silently reset → nginx -t. The whole flow runs inside a single shell process, so the
# token doesn't need to be passed across commands — see the "Create a proxy host in one go
# with a script" section in the README.
#
# Preconditions:
#   - This machine (the VPS) can run `docker run --network proxy curlimages/curl`, and jq is installed
#   - vps_oracle/compose/npm/.npm-automation.env exists (the automation account, only Proxy Hosts: Manage permission)
#
# Usage:
#   ./add-proxy-host.sh <service>.jerome.cloudns.asia <forward-host> <forward-port> [self-only|self-only-and-auth]
#   The 4th argument defaults to self-only; admin panels without built-in auth must pass
#   self-only-and-auth (see the rule in the root README)
#
# What it doesn't do:
#   - If the domain already has a proxy host it errors out and exits, no overwrite-update
#   - No Custom Locations support (the repo convention is to avoid them where possible, see
#     "avoid Custom Locations when you can" in the root README)
#   - It doesn't add a homepage card automatically; it reminds you at the end — edit
#     vps_oracle/compose/homepage/config/services.yaml separately

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/.npm-automation.env"

if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
  echo "Usage: $0 <domain> <forward-host> <forward-port> [self-only|self-only-and-auth]" >&2
  exit 1
fi

DOMAIN="$1"
FORWARD_HOST="$2"
FORWARD_PORT="$3"
ACCESS_LIST_NAME="${4:-self-only}"

if [[ "$ACCESS_LIST_NAME" != "self-only" && "$ACCESS_LIST_NAME" != "self-only-and-auth" ]]; then
  echo "Error: the 4th argument must be either self-only or self-only-and-auth, got '${ACCESS_LIST_NAME}'" >&2
  exit 1
fi

if ! [[ "$FORWARD_PORT" =~ ^[0-9]+$ ]]; then
  echo "Error: forward-port must be a number, got '${FORWARD_PORT}'" >&2
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
  echo "Error: failed to mint token, check the credentials/permissions in .npm-automation.env" >&2
  exit 1
fi

auth_curl() {
  curl_v -H "Authorization: Bearer ${TOKEN}" "$@"
}

echo "==> resolving access list id for ${ACCESS_LIST_NAME}"
ACCESS_LIST_ID=$(auth_curl "${NPM_BASE}/api/nginx/access-lists" | jq -r --arg name "$ACCESS_LIST_NAME" '.[] | select(.name == $name) | .id')
if [ -z "$ACCESS_LIST_ID" ]; then
  echo "Error: could not find an access list named ${ACCESS_LIST_NAME} in NPM" >&2
  exit 1
fi
echo "    ${ACCESS_LIST_NAME} -> id ${ACCESS_LIST_ID}"

echo "==> checking existing proxy hosts for ${DOMAIN}"
EXISTING_HOST_ID=$(auth_curl "${NPM_BASE}/api/nginx/proxy-hosts" | jq -r --arg d "$DOMAIN" '.[] | select(.domain_names[]? == $d) | .id')
if [ -n "$EXISTING_HOST_ID" ]; then
  echo "Error: ${DOMAIN} already has a proxy host (id ${EXISTING_HOST_ID}); this script does not do overwrite-updates, use the NPM UI or the manual API flow in the root README" >&2
  exit 1
fi

echo "==> checking existing certificates for ${DOMAIN}"
CERT_ID=$(auth_curl "${NPM_BASE}/api/nginx/certificates" | jq -r --arg d "$DOMAIN" '[.[] | select(.domain_names[]? == $d)] | first | .id // empty')

if [ -n "$CERT_ID" ]; then
  echo "    found existing certificate id ${CERT_ID}, reusing"
else
  echo "==> requesting new Let's Encrypt certificate for ${DOMAIN}"
  CERT_RESPONSE=$(auth_curl -X POST "${NPM_BASE}/api/nginx/certificates" \
    -H 'Content-Type: application/json' \
    -d "{\"provider\":\"letsencrypt\",\"domain_names\":[\"${DOMAIN}\"],\"meta\":{\"dns_challenge\":false}}")
  CERT_ID=$(echo "$CERT_RESPONSE" | jq -r '.id // empty')
  if [ -z "$CERT_ID" ]; then
    echo "Error: certificate creation failed: $CERT_RESPONSE" >&2
    exit 1
  fi
  echo "    new certificate id ${CERT_ID}"
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
  echo "Error: proxy host creation failed: $HOST_RESPONSE" >&2
  exit 1
fi
echo "    proxy host id ${HOST_ID}"

echo "==> verifying ssl_forced / http2_support weren't silently reset"
VERIFY=$(auth_curl "${NPM_BASE}/api/nginx/proxy-hosts/${HOST_ID}")
SSL_OK=$(echo "$VERIFY" | jq -r '.ssl_forced')
HTTP2_OK=$(echo "$VERIFY" | jq -r '.http2_support')

if [ "$SSL_OK" != "true" ] || [ "$HTTP2_OK" != "true" ]; then
  echo "    detected the known gotcha (silently reset after save), PUTting back the fix"
  auth_curl -X PUT "${NPM_BASE}/api/nginx/proxy-hosts/${HOST_ID}" \
    -H 'Content-Type: application/json' \
    -d '{"ssl_forced":true,"http2_support":true}' > /dev/null
  VERIFY=$(auth_curl "${NPM_BASE}/api/nginx/proxy-hosts/${HOST_ID}")
  SSL_OK=$(echo "$VERIFY" | jq -r '.ssl_forced')
  HTTP2_OK=$(echo "$VERIFY" | jq -r '.http2_support')
  if [ "$SSL_OK" != "true" ] || [ "$HTTP2_OK" != "true" ]; then
    echo "Warning: still not applied after the fix, manually check ${DOMAIN} in the NPM UI" >&2
  else
    echo "    fix applied"
  fi
fi

echo "==> nginx -t"
if docker exec npm nginx -t; then
  echo "    OK"
else
  echo "Warning: nginx -t failed, check docker logs npm" >&2
fi

cat <<SUMMARY

=== Done ===
domain:       ${DOMAIN}
forward:      http://${FORWARD_HOST}:${FORWARD_PORT}
access list:  ${ACCESS_LIST_NAME} (id ${ACCESS_LIST_ID})
certificate:  id ${CERT_ID}
proxy host:   id ${HOST_ID}

Don't forget:
  - If this is a new service, add a homepage card: vps_oracle/compose/homepage/config/services.yaml
  - Custom Locations, k3s NodePort, and other special cases are not handled by this script; see "wiring a service into an NPM reverse proxy" in the root README
SUMMARY