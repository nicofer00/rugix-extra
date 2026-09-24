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

umask 077
cat > /etc/cloudflared/defaults.env <<EOF
LOCAL_SERVICE=${RECIPE_PARAM_LOCAL_SERVICE}
SSH_ENABLE=${RECIPE_PARAM_SSH_ENABLE}
RUGIX_ADMIN_ENABLE=${RECIPE_PARAM_RUGIX_ADMIN_ENABLE}
LOGIN_POLICY=${RECIPE_PARAM_LOGIN_POLICY}
API_ACCESS_POLICY=${RECIPE_PARAM_API_ACCESS_POLICY}
USE_FEDRAMP=${RECIPE_PARAM_USE_FEDRAMP}
EOF
chmod 644 /etc/cloudflared/defaults.env

# Ensure account.env exists even if 01-run.sh did not run (empty placeholders).
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
install -D -m 755 "${RECIPE_DIR}/files/cloudflared-select-protocol.sh" \
    -t /usr/lib/cloudflared/

install -D -m 644 "${RECIPE_DIR}/files/cloudflared-provision.service" \
    -t /usr/lib/systemd/system/
install -D -m 644 "${RECIPE_DIR}/files/cloudflared.service" \
    -t /usr/lib/systemd/system/
install -D -m 644 "${RECIPE_DIR}/files/cloudflared-refresh.service" \
    -t /usr/lib/systemd/system/

# Drop-ins so named units trigger a tunnel refresh on every start/restart.
# Upstream should write /var/lib/cloudflared/device.env before it finishes start.
REFRESH_AFTER="${RECIPE_PARAM_REFRESH_AFTER:-}"
REFRESH_AFTER="${REFRESH_AFTER//,/ }"
for unit in ${REFRESH_AFTER}; do
    [ -n "${unit}" ] || continue
    # Normalize: allow "foo" or "foo.service"
    case "${unit}" in
        *.service|*.target|*.socket|*.path|*.timer) ;;
        *) unit="${unit}.service" ;;
    esac
    dropin_dir="/etc/systemd/system/${unit}.d"
    install -d -m 755 "${dropin_dir}"
    cat > "${dropin_dir}/cloudflared-refresh.conf" <<EOF
[Service]
# After this unit reaches running/success, refresh tunnel provisioning.
# --no-block avoids delaying the upstream unit on Cloudflare API calls.
ExecStartPost=-/bin/systemctl start --no-block cloudflared-refresh.service
EOF
    chmod 644 "${dropin_dir}/cloudflared-refresh.conf"
    echo "cloudflared: installed refresh drop-in for ${unit}"
done

systemctl enable cloudflared-provision.service
systemctl enable cloudflared.service
