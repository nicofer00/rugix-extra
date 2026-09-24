#!/usr/bin/env bash
# Provision a Cloudflare named tunnel when a per-device subdomain is configured.
#
# Build-time (project .env → /etc/cloudflared/account.env):
#   CLOUDFLARE_API_TOKEN   Account API token (Tunnel Edit + Zone DNS Edit)
#   CLOUDFLARE_ACCOUNT_ID
#   CLOUDFLARE_ZONE_ID
#   CLOUDFLARE_DOMAIN      Zone apex (e.g. example.com)
#
# Per-device opt-in (/var/lib/cloudflared/device.env), set after flash:
#   TUNNEL_SUBDOMAIN=my-device-01
#
# If TUNNEL_SUBDOMAIN is missing or blank, this script exits without calling
# Cloudflare (no tunnel). If tunnel.token already exists, creation is skipped.

set -euo pipefail

ACCOUNT_ENV="/etc/cloudflared/account.env"
DEVICE_ENV="/var/lib/cloudflared/device.env"
DEFAULTS_ENV="/etc/cloudflared/defaults.env"
TOKEN_FILE="/var/lib/cloudflared/tunnel.token"
TUNNEL_ID_FILE="/var/lib/cloudflared/tunnel.id"
HOSTNAME_FILE="/var/lib/cloudflared/hostname"
STATE_DIR="/var/lib/cloudflared"

mkdir -p "${STATE_DIR}"
chmod 700 "${STATE_DIR}"

if [ -f "${ACCOUNT_ENV}" ]; then
    # shellcheck source=/dev/null
    set -a
    . "${ACCOUNT_ENV}"
    set +a
fi

if [ -f "${DEFAULTS_ENV}" ]; then
    # shellcheck source=/dev/null
    set -a
    . "${DEFAULTS_ENV}"
    set +a
fi

if [ -f "${DEVICE_ENV}" ]; then
    # shellcheck source=/dev/null
    set -a
    . "${DEVICE_ENV}"
    set +a
fi

TUNNEL_SUBDOMAIN="${TUNNEL_SUBDOMAIN:-}"
if [ -z "${TUNNEL_SUBDOMAIN}" ]; then
    echo "cloudflared-provision: TUNNEL_SUBDOMAIN not set; skipping tunnel creation"
    exit 0
fi

if [ -s "${TOKEN_FILE}" ]; then
    echo "cloudflared-provision: tunnel token already present; skipping creation"
    exit 0
fi

: "${CLOUDFLARE_API_TOKEN:?CLOUDFLARE_API_TOKEN is required in ${ACCOUNT_ENV}}"
: "${CLOUDFLARE_ACCOUNT_ID:?CLOUDFLARE_ACCOUNT_ID is required in ${ACCOUNT_ENV}}"
: "${CLOUDFLARE_ZONE_ID:?CLOUDFLARE_ZONE_ID is required in ${ACCOUNT_ENV}}"
: "${CLOUDFLARE_DOMAIN:?CLOUDFLARE_DOMAIN is required in ${ACCOUNT_ENV}}"

LOCAL_SERVICE="${LOCAL_SERVICE:-http://127.0.0.1:80}"
FQDN="${TUNNEL_SUBDOMAIN}.${CLOUDFLARE_DOMAIN}"
TUNNEL_NAME="${TUNNEL_SUBDOMAIN}"

API="https://api.cloudflare.com/client/v4"
AUTH_HEADER="Authorization: Bearer ${CLOUDFLARE_API_TOKEN}"

cf_api() {
    local method="$1"
    local url="$2"
    local data="${3:-}"
    if [ -n "${data}" ]; then
        curl -fsS --request "${method}" \
            --header "${AUTH_HEADER}" \
            --header "Content-Type: application/json" \
            --data "${data}" \
            "${url}"
    else
        curl -fsS --request "${method}" \
            --header "${AUTH_HEADER}" \
            --header "Content-Type: application/json" \
            "${url}"
    fi
}

echo "cloudflared-provision: creating tunnel '${TUNNEL_NAME}' for ${FQDN}"

CREATE_PAYLOAD="$(jq -nc --arg name "${TUNNEL_NAME}" '{name: $name, config_src: "cloudflare"}')"
CREATE_RESP="$(cf_api POST "${API}/accounts/${CLOUDFLARE_ACCOUNT_ID}/cfd_tunnel" "${CREATE_PAYLOAD}")"

if [ "$(echo "${CREATE_RESP}" | jq -r '.success')" != "true" ]; then
    echo "cloudflared-provision: failed to create tunnel: ${CREATE_RESP}" >&2
    exit 1
fi

TUNNEL_ID="$(echo "${CREATE_RESP}" | jq -r '.result.id')"
TUNNEL_TOKEN="$(echo "${CREATE_RESP}" | jq -r '.result.token')"

if [ -z "${TUNNEL_ID}" ] || [ "${TUNNEL_ID}" = "null" ]; then
    echo "cloudflared-provision: create response missing tunnel id: ${CREATE_RESP}" >&2
    exit 1
fi

if [ -z "${TUNNEL_TOKEN}" ] || [ "${TUNNEL_TOKEN}" = "null" ]; then
    echo "cloudflared-provision: create response missing token; fetching token" >&2
    TOKEN_RESP="$(cf_api GET "${API}/accounts/${CLOUDFLARE_ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/token")"
    TUNNEL_TOKEN="$(echo "${TOKEN_RESP}" | jq -r '.result')"
fi

if [ -z "${TUNNEL_TOKEN}" ] || [ "${TUNNEL_TOKEN}" = "null" ]; then
    echo "cloudflared-provision: unable to obtain tunnel token" >&2
    exit 1
fi

CONFIG_PAYLOAD="$(jq -nc \
    --arg hostname "${FQDN}" \
    --arg service "${LOCAL_SERVICE}" \
    '{
        config: {
            ingress: [
                {hostname: $hostname, service: $service, originRequest: {}},
                {service: "http_status:404"}
            ]
        }
    }')"

CONFIG_RESP="$(cf_api PUT \
    "${API}/accounts/${CLOUDFLARE_ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/configurations" \
    "${CONFIG_PAYLOAD}")"

if [ "$(echo "${CONFIG_RESP}" | jq -r '.success')" != "true" ]; then
    echo "cloudflared-provision: failed to configure tunnel ingress: ${CONFIG_RESP}" >&2
    exit 1
fi

DNS_PAYLOAD="$(jq -nc \
    --arg name "${FQDN}" \
    --arg content "${TUNNEL_ID}.cfargotunnel.com" \
    '{type: "CNAME", proxied: true, name: $name, content: $content}')"

DNS_RESP="$(cf_api POST \
    "${API}/zones/${CLOUDFLARE_ZONE_ID}/dns_records" \
    "${DNS_PAYLOAD}")"

if [ "$(echo "${DNS_RESP}" | jq -r '.success')" != "true" ]; then
    # Idempotent-ish: if the record already exists, continue when content matches.
    ERROR_CODE="$(echo "${DNS_RESP}" | jq -r '.errors[0].code // empty')"
    if [ "${ERROR_CODE}" = "81057" ] || [ "${ERROR_CODE}" = "81053" ]; then
        echo "cloudflared-provision: DNS record already exists; continuing"
    else
        echo "cloudflared-provision: failed to create DNS record: ${DNS_RESP}" >&2
        exit 1
    fi
fi

umask 077
printf '%s\n' "${TUNNEL_TOKEN}" > "${TOKEN_FILE}"
chmod 600 "${TOKEN_FILE}"
printf '%s\n' "${TUNNEL_ID}" > "${TUNNEL_ID_FILE}"
chmod 600 "${TUNNEL_ID_FILE}"
printf '%s\n' "${FQDN}" > "${HOSTNAME_FILE}"
chmod 644 "${HOSTNAME_FILE}"

echo "cloudflared-provision: tunnel ready at https://${FQDN}"
