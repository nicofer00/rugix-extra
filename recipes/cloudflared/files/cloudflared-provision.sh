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
#
# Recovery: if a tunnel named TUNNEL_SUBDOMAIN already exists (e.g. previous
# device died), look it up by name, fetch its run token, and reuse it so the
# new board can join the same public hostname.

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

# HTTP helper. With fail_on_http=1 (default), curl -f aborts on 4xx/5xx.
# Pass fail_on_http=0 to capture conflict/error JSON bodies for recovery.
cf_api() {
    local method="$1"
    local url="$2"
    local data="${3:-}"
    local fail_on_http="${4:-1}"
    local curl_opts=(-sS --request "${method}" --header "${AUTH_HEADER}" --header "Content-Type: application/json")
    if [ "${fail_on_http}" = "1" ]; then
        curl_opts+=(-f)
    fi
    if [ -n "${data}" ]; then
        curl "${curl_opts[@]}" --data "${data}" "${url}"
    else
        curl "${curl_opts[@]}" "${url}"
    fi
}

# Returns tunnel id for an exact non-deleted name match, or empty.
find_tunnel_id_by_name() {
    local name="$1"
    local encoded list_resp
    encoded="$(jq -nr --arg n "${name}" '$n | @uri')"
    list_resp="$(cf_api GET \
        "${API}/accounts/${CLOUDFLARE_ACCOUNT_ID}/cfd_tunnel?name=${encoded}&is_deleted=false")"

    if [ "$(echo "${list_resp}" | jq -r '.success')" != "true" ]; then
        echo "cloudflared-provision: failed to list tunnels: ${list_resp}" >&2
        return 1
    fi

    echo "${list_resp}" | jq -r --arg name "${name}" '
        [.result[]? | select(.name == $name and .deleted_at == null) | .id] | .[0] // empty
    '
}

fetch_tunnel_token() {
    local tunnel_id="$1"
    local token_resp token
    token_resp="$(cf_api GET \
        "${API}/accounts/${CLOUDFLARE_ACCOUNT_ID}/cfd_tunnel/${tunnel_id}/token")"

    if [ "$(echo "${token_resp}" | jq -r '.success')" != "true" ]; then
        echo "cloudflared-provision: failed to fetch tunnel token: ${token_resp}" >&2
        return 1
    fi

    token="$(echo "${token_resp}" | jq -r '.result')"
    if [ -z "${token}" ] || [ "${token}" = "null" ]; then
        echo "cloudflared-provision: token endpoint returned empty result" >&2
        return 1
    fi
    printf '%s\n' "${token}"
}

ensure_ingress() {
    local tunnel_id="$1"
    local config_payload config_resp
    config_payload="$(jq -nc \
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

    config_resp="$(cf_api PUT \
        "${API}/accounts/${CLOUDFLARE_ACCOUNT_ID}/cfd_tunnel/${tunnel_id}/configurations" \
        "${config_payload}")"

    if [ "$(echo "${config_resp}" | jq -r '.success')" != "true" ]; then
        echo "cloudflared-provision: failed to configure tunnel ingress: ${config_resp}" >&2
        return 1
    fi
}

ensure_dns() {
    local tunnel_id="$1"
    local dns_payload dns_resp error_code
    dns_payload="$(jq -nc \
        --arg name "${FQDN}" \
        --arg content "${tunnel_id}.cfargotunnel.com" \
        '{type: "CNAME", proxied: true, name: $name, content: $content}')"

    # Do not fail on HTTP errors — existing CNAME is expected on recovery.
    dns_resp="$(cf_api POST \
        "${API}/zones/${CLOUDFLARE_ZONE_ID}/dns_records" \
        "${dns_payload}" \
        0)"

    if [ "$(echo "${dns_resp}" | jq -r '.success')" = "true" ]; then
        return 0
    fi

    error_code="$(echo "${dns_resp}" | jq -r '.errors[0].code // empty')"
    # 81053 / 81057: record already exists for this hostname.
    if [ "${error_code}" = "81057" ] || [ "${error_code}" = "81053" ]; then
        echo "cloudflared-provision: DNS record already exists; continuing"
        return 0
    fi

    echo "cloudflared-provision: failed to create DNS record: ${dns_resp}" >&2
    return 1
}

write_state() {
    local tunnel_id="$1"
    local tunnel_token="$2"
    umask 077
    printf '%s\n' "${tunnel_token}" > "${TOKEN_FILE}"
    chmod 600 "${TOKEN_FILE}"
    printf '%s\n' "${tunnel_id}" > "${TUNNEL_ID_FILE}"
    chmod 600 "${TUNNEL_ID_FILE}"
    printf '%s\n' "${FQDN}" > "${HOSTNAME_FILE}"
    chmod 644 "${HOSTNAME_FILE}"
}

TUNNEL_ID=""
TUNNEL_TOKEN=""
RECOVERED=0

echo "cloudflared-provision: looking up tunnel '${TUNNEL_NAME}' for ${FQDN}"
TUNNEL_ID="$(find_tunnel_id_by_name "${TUNNEL_NAME}")"

if [ -n "${TUNNEL_ID}" ]; then
    echo "cloudflared-provision: found existing tunnel ${TUNNEL_ID}; recovering token"
    TUNNEL_TOKEN="$(fetch_tunnel_token "${TUNNEL_ID}")"
    RECOVERED=1
else
    echo "cloudflared-provision: creating tunnel '${TUNNEL_NAME}'"
    CREATE_PAYLOAD="$(jq -nc --arg name "${TUNNEL_NAME}" '{name: $name, config_src: "cloudflare"}')"
    # Capture body on conflict so we can fall back to query-by-name.
    CREATE_RESP="$(cf_api POST \
        "${API}/accounts/${CLOUDFLARE_ACCOUNT_ID}/cfd_tunnel" \
        "${CREATE_PAYLOAD}" \
        0)"

    if [ "$(echo "${CREATE_RESP}" | jq -r '.success')" != "true" ]; then
        # Race: another device created it between list and create — recover by name.
        echo "cloudflared-provision: create failed; attempting recovery by name"
        echo "cloudflared-provision: create response: ${CREATE_RESP}" >&2
        TUNNEL_ID="$(find_tunnel_id_by_name "${TUNNEL_NAME}")"
        if [ -z "${TUNNEL_ID}" ]; then
            echo "cloudflared-provision: create failed and no existing tunnel named '${TUNNEL_NAME}'" >&2
            exit 1
        fi
        TUNNEL_TOKEN="$(fetch_tunnel_token "${TUNNEL_ID}")"
        RECOVERED=1
    else
        TUNNEL_ID="$(echo "${CREATE_RESP}" | jq -r '.result.id')"
        TUNNEL_TOKEN="$(echo "${CREATE_RESP}" | jq -r '.result.token // empty')"

        if [ -z "${TUNNEL_ID}" ] || [ "${TUNNEL_ID}" = "null" ]; then
            echo "cloudflared-provision: create response missing tunnel id: ${CREATE_RESP}" >&2
            exit 1
        fi

        if [ -z "${TUNNEL_TOKEN}" ] || [ "${TUNNEL_TOKEN}" = "null" ]; then
            TUNNEL_TOKEN="$(fetch_tunnel_token "${TUNNEL_ID}")"
        fi
    fi
fi

if [ -z "${TUNNEL_TOKEN}" ] || [ "${TUNNEL_TOKEN}" = "null" ]; then
    echo "cloudflared-provision: unable to obtain tunnel token" >&2
    exit 1
fi

ensure_ingress "${TUNNEL_ID}"
ensure_dns "${TUNNEL_ID}"
write_state "${TUNNEL_ID}" "${TUNNEL_TOKEN}"

if [ "${RECOVERED}" -eq 1 ]; then
    echo "cloudflared-provision: recovered existing tunnel; ready at https://${FQDN}"
else
    echo "cloudflared-provision: tunnel ready at https://${FQDN}"
fi
