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
# The public hostnames are one label under CLOUDFLARE_DOMAIN so they match
# Universal SSL (*.example.com): my-device-01.example.com, and when enabled
# my-device-01-ssh.example.com and my-device-01-admin.example.com.
# config.yaml is written here from account.env, device.env, and defaults.env.
#
# Optional Access policy names (defaults.env), empty means that hostname stays public:
#   LOGIN_POLICY        Allow policy for SSH and admin
#   API_ACCESS_POLICY   Service Auth policy for the API hostname
# Lookup checks policies on the Access application for CLOUDFLARE_DOMAIN
# (or *.CLOUDFLARE_DOMAIN) first, then account reusable policies.
# When either is set, CLOUDFLARE_API_TOKEN also needs Access: Apps and Policies
# read and write.
#
# If TUNNEL_SUBDOMAIN is missing or blank, this script exits without calling
# Cloudflare (no tunnel). An existing tunnel token still refreshes config, DNS,
# and Access apps.
#
# Recovery: if a tunnel with this hostname label already exists (e.g. previous
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
CONFIG_YAML="/etc/cloudflared/config.yaml"

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

# A local token means the tunnel was already created. Still refresh config.yaml
# and DNS from the current settings.
HAVE_LOCAL_TUNNEL=0
if [ -s "${TOKEN_FILE}" ] && [ -s "${TUNNEL_ID_FILE}" ]; then
    HAVE_LOCAL_TUNNEL=1
fi

: "${CLOUDFLARE_API_TOKEN:?CLOUDFLARE_API_TOKEN is required in ${ACCOUNT_ENV}}"
: "${CLOUDFLARE_ACCOUNT_ID:?CLOUDFLARE_ACCOUNT_ID is required in ${ACCOUNT_ENV}}"
: "${CLOUDFLARE_ZONE_ID:?CLOUDFLARE_ZONE_ID is required in ${ACCOUNT_ENV}}"
: "${CLOUDFLARE_DOMAIN:?CLOUDFLARE_DOMAIN is required in ${ACCOUNT_ENV}}"

LOCAL_SERVICE="${LOCAL_SERVICE:-http://127.0.0.1:80}"
SSH_ENABLE="${SSH_ENABLE:-true}"
RUGIX_ADMIN_ENABLE="${RUGIX_ADMIN_ENABLE:-false}"
LOGIN_POLICY="${LOGIN_POLICY:-}"
API_ACCESS_POLICY="${API_ACCESS_POLICY:-}"

# Universal SSL covers a single level (*.zone). Dashboard publishes
# {subdomain}.{domain}; ingress hostname and DNS name must be that FQDN once.
CLOUDFLARE_DOMAIN="${CLOUDFLARE_DOMAIN%.}"
TUNNEL_SUBDOMAIN="${TUNNEL_SUBDOMAIN%.}"
ZONE_LABEL="${CLOUDFLARE_DOMAIN%%.*}"
if [[ "${TUNNEL_SUBDOMAIN}" == *".${CLOUDFLARE_DOMAIN}" ]]; then
    TUNNEL_SUBDOMAIN="${TUNNEL_SUBDOMAIN%."${CLOUDFLARE_DOMAIN}"}"
fi
if [ -n "${ZONE_LABEL}" ] && [[ "${TUNNEL_SUBDOMAIN}" == *".${ZONE_LABEL}" ]]; then
    TUNNEL_SUBDOMAIN="${TUNNEL_SUBDOMAIN%."${ZONE_LABEL}"}"
fi
TUNNEL_LABEL="${TUNNEL_SUBDOMAIN//./-}"
if [ -z "${TUNNEL_LABEL}" ]; then
    echo "cloudflared-provision: TUNNEL_SUBDOMAIN is empty after normalizing against ${CLOUDFLARE_DOMAIN}" >&2
    exit 1
fi
FQDN="${TUNNEL_LABEL}.${CLOUDFLARE_DOMAIN}"
SSH_FQDN="${TUNNEL_LABEL}-ssh.${CLOUDFLARE_DOMAIN}"
ADMIN_FQDN="${TUNNEL_LABEL}-admin.${CLOUDFLARE_DOMAIN}"
TUNNEL_NAME="${TUNNEL_LABEL}"
echo "cloudflared-provision: public hostname ${FQDN}"

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

write_config() {
    local ssh_rule="" admin_rule=""
    if [ "${SSH_ENABLE}" = "true" ]; then
        ssh_rule="$(cat <<EOF
  - hostname: "${SSH_FQDN}"
    service: "ssh://127.0.0.1:22"
EOF
)"
    fi
    if [ "${RUGIX_ADMIN_ENABLE}" = "true" ]; then
        admin_rule="$(cat <<EOF
  - hostname: "${ADMIN_FQDN}"
    service: "http://127.0.0.1:7492"
EOF
)"
    fi

    cat > "${CONFIG_YAML}" <<EOF
ingress:
${ssh_rule}
${admin_rule}
  - hostname: "*.${CLOUDFLARE_DOMAIN}"
    service: "${LOCAL_SERVICE}"
  - service: "http_status:404"
EOF
    chmod 644 "${CONFIG_YAML}"
}

ensure_ingress() {
    local tunnel_id="$1"
    local config_payload config_resp

    write_config
    # Debian yq (jq wrapper) wraps the generated document as the tunnel config.
    config_payload="$(yq -c '{config: .}' "${CONFIG_YAML}")"

    echo "cloudflared-provision: uploading ${CONFIG_YAML} to tunnel ${tunnel_id}"
    config_resp="$(cf_api PUT \
        "${API}/accounts/${CLOUDFLARE_ACCOUNT_ID}/cfd_tunnel/${tunnel_id}/configurations" \
        "${config_payload}" \
        0)"

    if [ "$(echo "${config_resp}" | jq -r '.success')" != "true" ]; then
        echo "cloudflared-provision: failed to configure tunnel ingress: ${config_resp}" >&2
        return 1
    fi
}

ensure_dns() {
    local tunnel_id="$1"
    local hostname="$2"
    local dns_payload dns_resp error_code
    dns_payload="$(jq -nc \
        --arg name "${hostname}" \
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
        echo "cloudflared-provision: DNS record already exists for ${hostname}; continuing"
        return 0
    fi

    echo "cloudflared-provision: failed to create DNS record for ${hostname}: ${dns_resp}" >&2
    return 1
}

publish_dns() {
    local tunnel_id="$1"
    ensure_dns "${tunnel_id}" "${FQDN}"
    if [ "${SSH_ENABLE}" = "true" ]; then
        ensure_dns "${tunnel_id}" "${SSH_FQDN}"
    fi
    if [ "${RUGIX_ADMIN_ENABLE}" = "true" ]; then
        ensure_dns "${tunnel_id}" "${ADMIN_FQDN}"
    fi
}

# Prints the id of a policy named exactly $1 from a Cloudflare list response.
policy_id_named() {
    local name="$1"
    local resp="$2"
    echo "${resp}" | jq -r --arg name "${name}" '
        [.result[]? | select(.name == $name) | .id] | .[0] // empty
    '
}

# Policies attached to the Zero Trust application for this zone.
# Matches the app whose domain is CLOUDFLARE_DOMAIN or *.CLOUDFLARE_DOMAIN.
find_policy_id_on_zone_apps() {
    local name="$1"
    local page=1 total apps_resp app_id app_domain
    local policy_page policy_total policies_resp id
    while true; do
        apps_resp="$(cf_api GET \
            "${API}/accounts/${CLOUDFLARE_ACCOUNT_ID}/access/apps?page=${page}&per_page=100" \
            "" \
            0)"
        if [ "$(echo "${apps_resp}" | jq -r '.success')" != "true" ]; then
            echo "cloudflared-provision: failed to list Access applications: ${apps_resp}" >&2
            return 1
        fi
        while IFS=$'\t' read -r app_id app_domain; do
            [ -n "${app_id}" ] || continue
            case "${app_domain}" in
                "${CLOUDFLARE_DOMAIN}"|"*.${CLOUDFLARE_DOMAIN}") ;;
                *) continue ;;
            esac
            policy_page=1
            while true; do
                policies_resp="$(cf_api GET \
                    "${API}/accounts/${CLOUDFLARE_ACCOUNT_ID}/access/apps/${app_id}/policies?page=${policy_page}&per_page=100" \
                    "" \
                    0)"
                if [ "$(echo "${policies_resp}" | jq -r '.success')" != "true" ]; then
                    echo "cloudflared-provision: failed to list policies for ${app_domain}: ${policies_resp}" >&2
                    return 1
                fi
                id="$(policy_id_named "${name}" "${policies_resp}")"
                if [ -n "${id}" ]; then
                    printf '%s\n' "${id}"
                    return 0
                fi
                policy_total="$(echo "${policies_resp}" | jq -r '.result_info.total_pages // 1')"
                if [ "${policy_page}" -ge "${policy_total}" ]; then
                    break
                fi
                policy_page=$((policy_page + 1))
            done
        done < <(echo "${apps_resp}" | jq -r '.result[]? | [.id, .domain] | @tsv')
        total="$(echo "${apps_resp}" | jq -r '.result_info.total_pages // 1')"
        if [ "${page}" -ge "${total}" ]; then
            return 0
        fi
        page=$((page + 1))
    done
}

# Account-wide reusable policies. Used when the zone application has no match.
find_account_policy_id() {
    local name="$1"
    local page=1 total id resp
    while true; do
        resp="$(cf_api GET \
            "${API}/accounts/${CLOUDFLARE_ACCOUNT_ID}/access/policies?page=${page}&per_page=100" \
            "" \
            0)"
        if [ "$(echo "${resp}" | jq -r '.success')" != "true" ]; then
            echo "cloudflared-provision: failed to list Access policies: ${resp}" >&2
            return 1
        fi
        id="$(policy_id_named "${name}" "${resp}")"
        if [ -n "${id}" ]; then
            printf '%s\n' "${id}"
            return 0
        fi
        total="$(echo "${resp}" | jq -r '.result_info.total_pages // 1')"
        if [ "${page}" -ge "${total}" ]; then
            return 0
        fi
        page=$((page + 1))
    done
}

# Prints the Access policy id for an exact name, or fails.
# Application policies on the zone app come first; account reusable policies are the fallback.
find_policy_id() {
    local name="$1"
    local id
    id="$(find_policy_id_on_zone_apps "${name}")" || return 1
    if [ -n "${id}" ]; then
        printf '%s\n' "${id}"
        return 0
    fi
    id="$(find_account_policy_id "${name}")" || return 1
    if [ -n "${id}" ]; then
        printf '%s\n' "${id}"
        return 0
    fi
    echo "cloudflared-provision: Access policy '${name}' was not found" >&2
    return 1
}

find_access_app_id() {
    local hostname="$1"
    local page=1 total id resp
    while true; do
        resp="$(cf_api GET \
            "${API}/accounts/${CLOUDFLARE_ACCOUNT_ID}/access/apps?page=${page}&per_page=100" \
            "" \
            0)"
        if [ "$(echo "${resp}" | jq -r '.success')" != "true" ]; then
            echo "cloudflared-provision: failed to list Access applications: ${resp}" >&2
            return 1
        fi
        id="$(echo "${resp}" | jq -r --arg hostname "${hostname}" '
            [.result[]? | select(.domain == $hostname) | .id] | .[0] // empty
        ')"
        if [ -n "${id}" ]; then
            printf '%s\n' "${id}"
            return 0
        fi
        total="$(echo "${resp}" | jq -r '.result_info.total_pages // 1')"
        if [ "${page}" -ge "${total}" ]; then
            return 0
        fi
        page=$((page + 1))
    done
}

ensure_access_app() {
    local hostname="$1"
    local policy_id="$2"
    local app_id payload resp
    app_id="$(find_access_app_id "${hostname}")"
    payload="$(jq -nc \
        --arg name "${hostname}" \
        --arg domain "${hostname}" \
        --arg policy_id "${policy_id}" \
        '{
            name: $name,
            domain: $domain,
            type: "self_hosted",
            session_duration: "24h",
            policies: [{id: $policy_id, precedence: 1}]
        }')"
    if [ -n "${app_id}" ]; then
        echo "cloudflared-provision: updating Access application for ${hostname}"
        resp="$(cf_api PUT \
            "${API}/accounts/${CLOUDFLARE_ACCOUNT_ID}/access/apps/${app_id}" \
            "${payload}" \
            0)"
    else
        echo "cloudflared-provision: creating Access application for ${hostname}"
        resp="$(cf_api POST \
            "${API}/accounts/${CLOUDFLARE_ACCOUNT_ID}/access/apps" \
            "${payload}" \
            0)"
    fi
    if [ "$(echo "${resp}" | jq -r '.success')" != "true" ]; then
        echo "cloudflared-provision: failed to set Access application for ${hostname}: ${resp}" >&2
        return 1
    fi
}

# Resolve configured policy names before publishing so a missing policy fails
# instead of leaving the hostname public.
resolve_access_policies() {
    API_POLICY_ID=""
    LOGIN_POLICY_ID=""
    if [ -n "${API_ACCESS_POLICY}" ]; then
        API_POLICY_ID="$(find_policy_id "${API_ACCESS_POLICY}")"
    fi
    if [ -n "${LOGIN_POLICY}" ] && { [ "${SSH_ENABLE}" = "true" ] || [ "${RUGIX_ADMIN_ENABLE}" = "true" ]; }; then
        LOGIN_POLICY_ID="$(find_policy_id "${LOGIN_POLICY}")"
    fi
}

publish_access() {
    if [ -n "${API_POLICY_ID}" ]; then
        ensure_access_app "${FQDN}" "${API_POLICY_ID}"
    fi
    if [ "${SSH_ENABLE}" = "true" ] && [ -n "${LOGIN_POLICY_ID}" ]; then
        ensure_access_app "${SSH_FQDN}" "${LOGIN_POLICY_ID}"
    fi
    if [ "${RUGIX_ADMIN_ENABLE}" = "true" ] && [ -n "${LOGIN_POLICY_ID}" ]; then
        ensure_access_app "${ADMIN_FQDN}" "${LOGIN_POLICY_ID}"
    fi
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

if [ "${HAVE_LOCAL_TUNNEL}" -eq 1 ]; then
    TUNNEL_ID="$(tr -d '[:space:]' < "${TUNNEL_ID_FILE}")"
    echo "cloudflared-provision: tunnel ${TUNNEL_ID} already exists; reuploading config"
    resolve_access_policies
    ensure_ingress "${TUNNEL_ID}"
    publish_dns "${TUNNEL_ID}"
    publish_access
    exit 0
fi

resolve_access_policies
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
publish_dns "${TUNNEL_ID}"
publish_access
write_state "${TUNNEL_ID}" "${TUNNEL_TOKEN}"

if [ "${RECOVERED}" -eq 1 ]; then
    echo "cloudflared-provision: recovered existing tunnel; ready at https://${FQDN}"
else
    echo "cloudflared-provision: tunnel ready at https://${FQDN}"
fi
