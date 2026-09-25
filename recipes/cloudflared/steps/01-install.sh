#!/usr/bin/env bash

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    jq

mkdir -p --mode=0755 /usr/share/keyrings
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
    -o /usr/share/keyrings/cloudflare-main.gpg

echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' \
    > /etc/apt/sources.list.d/cloudflared.list

apt-get update
apt-get install -y cloudflared

install -d -m 700 /var/lib/cloudflared
install -d -m 755 /etc/cloudflared
install -d -m 755 /usr/lib/cloudflared

install -D -m 644 "${RECIPE_DIR}/files/cloudflared-state.toml" \
    /etc/rugix/state/cloudflared.toml

# pull configured domain for service, 00-run.sh already validated
ENV_FILE="${RUGIX_PROJECT_DIR}/.env"
if [ -e "${ENV_FILE}" ]; then
    # shellcheck source=/dev/null
    . "${ENV_FILE}"
fi

sed -e "s|__LOCAL_SERVICE__|${RECIPE_PARAM_LOCAL_SERVICE}|g" \
    -e "s|__DOMAIN_WILDCARD__|\"*.${CLOUDFLARE_DOMAIN:-}\"|g" \
    "${RECIPE_DIR}/files/config.yaml" \
    > /etc/cloudflared/config.yaml
chmod 644 /etc/cloudflared/config.yaml

umask 077
cat > /etc/cloudflared/defaults.env <<EOF
LOCAL_SERVICE=${RECIPE_PARAM_LOCAL_SERVICE}
EOF
chmod 644 /etc/cloudflared/defaults.env

# Ensure account.env exists even if 00-run.sh did not run (empty placeholders).
if [ ! -f /etc/cloudflared/account.env ]; then
    umask 077
    cat > /etc/cloudflared/account.env <<EOF
CLOUDFLARE_API_TOKEN=
CLOUDFLARE_ACCOUNT_ID=
CLOUDFLARE_ZONE_ID=
CLOUDFLARE_DOMAIN=
EOF
    chmod 600 /etc/cloudflared/account.env
fi

install -D -m 755 "${RECIPE_DIR}/files/cloudflared-provision.sh" \
    -t /usr/lib/cloudflared/

install -D -m 644 "${RECIPE_DIR}/files/cloudflared-provision.service" \
    -t /usr/lib/systemd/system/
install -D -m 644 "${RECIPE_DIR}/files/cloudflared.service" \
    -t /usr/lib/systemd/system/

systemctl enable cloudflared-provision.service
systemctl enable cloudflared.service
