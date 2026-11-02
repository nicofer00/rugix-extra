#!/usr/bin/env bash

set -euo pipefail

OUTPUT_DIR="${RECIPE_PARAM_OUTPUT_DIR}"
UNIT_PATTERNS="${RECIPE_PARAM_UNIT_PATTERNS}"
FROM_PATTERN="${RECIPE_PARAM_FROM_PATTERN}"
TO_PATTERN="${RECIPE_PARAM_TO_PATTERN}"
DEPENDENCY_MODE="${RECIPE_PARAM_DEPENDENCY_MODE}"
INCLUDE_BOOT_PLOT="${RECIPE_PARAM_INCLUDE_BOOT_PLOT}"
ENABLE_ONESHOT="${RECIPE_PARAM_ENABLE_ONESHOT}"
PUBLISH_NGINX="${RECIPE_PARAM_PUBLISH_NGINX}"
NGINX_DOCROOT="${RECIPE_PARAM_NGINX_DOCROOT}"
INVENTORY_FILE="${RECIPE_PARAM_INVENTORY_FILE}"

case "${DEPENDENCY_MODE}" in
    both|order|require) ;;
    *)
        echo "systemd-diagrams: invalid dependency_mode='${DEPENDENCY_MODE}' (expected both|order|require)" >&2
        exit 1
        ;;
esac

install -d -m 755 /usr/lib/systemd-diagrams
install -d -m 755 /etc/systemd-diagrams
install -d -m 755 /usr/share/systemd-diagrams
install -d -m 755 "${OUTPUT_DIR}"

install -D -m 755 "${RECIPE_DIR}/files/systemd-diagrams-generate.sh" \
    -t /usr/lib/systemd-diagrams/
install -D -m 644 "${RECIPE_DIR}/files/systemd-diagrams.service" \
    -t /usr/lib/systemd/system/
install -D -m 644 "${RECIPE_DIR}/files/index.html" \
    -t /usr/share/systemd-diagrams/

# Quote values so space-separated patterns survive sourcing.
{
    printf 'OUTPUT_DIR=%q\n' "${OUTPUT_DIR}"
    printf 'UNIT_PATTERNS=%q\n' "${UNIT_PATTERNS}"
    printf 'FROM_PATTERN=%q\n' "${FROM_PATTERN}"
    printf 'TO_PATTERN=%q\n' "${TO_PATTERN}"
    printf 'DEPENDENCY_MODE=%q\n' "${DEPENDENCY_MODE}"
    printf 'INCLUDE_BOOT_PLOT=%q\n' "${INCLUDE_BOOT_PLOT}"
    printf 'PUBLISH_NGINX=%q\n' "${PUBLISH_NGINX}"
    printf 'NGINX_DOCROOT=%q\n' "${NGINX_DOCROOT}"
} > /etc/systemd-diagrams/defaults.env
chmod 644 /etc/systemd-diagrams/defaults.env

if [ "${PUBLISH_NGINX}" = "true" ]; then
    if ! command -v nginx >/dev/null 2>&1 && [ ! -d /var/www/html ] && [ ! -d /etc/nginx ]; then
        echo "systemd-diagrams: publish_nginx=true but nginx was not found." >&2
        echo "systemd-diagrams: include rugix-extra/nginx (or install nginx) in the layer." >&2
        exit 1
    fi
    install -d -m 755 "${NGINX_DOCROOT}"
    install -D -m 644 "${RECIPE_DIR}/files/index.html" \
        "${NGINX_DOCROOT}/index.html"
    # Snippets are includable from server{}; bare location blocks must not go in conf.d.
    if [ -d /etc/nginx/snippets ]; then
        # Rewrite alias to the configured docroot.
        sed "s|alias /var/www/html/systemd/;|alias ${NGINX_DOCROOT}/;|" \
            "${RECIPE_DIR}/files/nginx-systemd-diagrams.conf" \
            > /etc/nginx/snippets/systemd-diagrams.conf
        chmod 644 /etc/nginx/snippets/systemd-diagrams.conf
        echo "systemd-diagrams: installed /etc/nginx/snippets/systemd-diagrams.conf"
        echo "systemd-diagrams: include it from a server block if /systemd/ is not already under the site root"
    fi
fi

if [ "${ENABLE_ONESHOT}" = "true" ]; then
    systemctl enable systemd-diagrams.service
fi

# Bake-time inventory of installed unit files (not a live dependency graph).
INVENTORY_PATH="${RUGIX_ARTIFACTS_DIR}/${INVENTORY_FILE}"
install -d -m 755 "$(dirname "${INVENTORY_PATH}")"
{
    echo "# systemd unit inventory generated at image build time"
    echo "# This is not a live systemd-analyze dependency graph."
    echo "#"
    date -u +"generated_at=%Y-%m-%dT%H:%M:%SZ"
    echo
    echo "## list-unit-files"
    systemctl list-unit-files \
        --type=service,target,socket,timer,path,mount,automount,swap,slice \
        --no-pager --all 2>/dev/null \
        || systemctl list-unit-files --no-pager --all 2>/dev/null \
        || echo "(systemctl list-unit-files unavailable in build chroot)"
    echo
    echo "## list-dependencies multi-user.target"
    systemctl list-dependencies multi-user.target --no-pager 2>/dev/null \
        || echo "(systemctl list-dependencies unavailable in build chroot)"
} > "${INVENTORY_PATH}"

echo "systemd-diagrams: wrote inventory artifact ${INVENTORY_PATH}"
