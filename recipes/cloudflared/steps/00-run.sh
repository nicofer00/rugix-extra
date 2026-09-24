#!/usr/bin/env bash

set -euo pipefail

# Inject Cloudflare account credentials from the consumer project .env into the
# image. Expected variables:
#   CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID, CLOUDFLARE_ZONE_ID, CLOUDFLARE_DOMAIN
# Missing .env still builds; devices cannot provision until account.env is populated.

ENV_FILE="${RUGIX_PROJECT_DIR}/.env"

echo ".env" >> "${LAYER_REBUILD_IF_CHANGED}"

CLOUDFLARE_API_TOKEN=""
CLOUDFLARE_ACCOUNT_ID=""
CLOUDFLARE_ZONE_ID=""
CLOUDFLARE_DOMAIN=""

if [ -e "${ENV_FILE}" ]; then
    # shellcheck source=/dev/null
    . "${ENV_FILE}"
fi

ACCOUNT_DIR="${RUGIX_ROOT_DIR}/etc/cloudflared"
mkdir -p "${ACCOUNT_DIR}"

umask 077
cat > "${ACCOUNT_DIR}/account.env" <<EOF
CLOUDFLARE_API_TOKEN=${CLOUDFLARE_API_TOKEN:-}
CLOUDFLARE_ACCOUNT_ID=${CLOUDFLARE_ACCOUNT_ID:-}
CLOUDFLARE_ZONE_ID=${CLOUDFLARE_ZONE_ID:-}
CLOUDFLARE_DOMAIN=${CLOUDFLARE_DOMAIN:-}
EOF
chmod 600 "${ACCOUNT_DIR}/account.env"
