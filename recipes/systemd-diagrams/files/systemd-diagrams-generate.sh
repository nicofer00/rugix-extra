#!/usr/bin/env bash

set -euo pipefail

DEFAULTS_ENV="/etc/systemd-diagrams/defaults.env"
if [ -f "${DEFAULTS_ENV}" ]; then
    # shellcheck disable=SC1090
    . "${DEFAULTS_ENV}"
fi

OUTPUT_DIR="${OUTPUT_DIR:-/var/lib/systemd-diagrams}"
UNIT_PATTERNS="${UNIT_PATTERNS:-}"
FROM_PATTERN="${FROM_PATTERN:-}"
TO_PATTERN="${TO_PATTERN:-}"
DEPENDENCY_MODE="${DEPENDENCY_MODE:-both}"
INCLUDE_BOOT_PLOT="${INCLUDE_BOOT_PLOT:-true}"
PUBLISH_NGINX="${PUBLISH_NGINX:-false}"
NGINX_DOCROOT="${NGINX_DOCROOT:-/var/www/html/systemd}"

log() {
    echo "systemd-diagrams: $*"
}

die() {
    echo "systemd-diagrams: $*" >&2
    exit 1
}

command -v systemd-analyze >/dev/null 2>&1 || die "systemd-analyze not found"
command -v dot >/dev/null 2>&1 || die "graphviz 'dot' not found"

install -d -m 755 "${OUTPUT_DIR}"

DOT_ARGS=()
case "${DEPENDENCY_MODE}" in
    both) ;;
    order) DOT_ARGS+=(--order) ;;
    require) DOT_ARGS+=(--require) ;;
    *) die "invalid DEPENDENCY_MODE='${DEPENDENCY_MODE}' (expected both|order|require)" ;;
esac

if [ -n "${FROM_PATTERN}" ]; then
    DOT_ARGS+=(--from-pattern="${FROM_PATTERN}")
fi
if [ -n "${TO_PATTERN}" ]; then
    DOT_ARGS+=(--to-pattern="${TO_PATTERN}")
fi

# Space-separated globs from recipe param (noglob so *.service stays literal).
PATTERN_ARGS=()
if [ -n "${UNIT_PATTERNS}" ]; then
    set -f
    # shellcheck disable=SC2206
    PATTERN_ARGS=( ${UNIT_PATTERNS} )
    set +f
fi

DOT_PATH="${OUTPUT_DIR}/dependencies.dot"
SVG_PATH="${OUTPUT_DIR}/dependencies.svg"
BOOT_SVG_PATH="${OUTPUT_DIR}/boot.svg"

log "generating dependency DOT (${DEPENDENCY_MODE})"
systemd-analyze dot "${DOT_ARGS[@]}" "${PATTERN_ARGS[@]}" >"${DOT_PATH}.tmp"
mv -f "${DOT_PATH}.tmp" "${DOT_PATH}"

log "rendering ${SVG_PATH}"
dot -Tsvg "${DOT_PATH}" -o "${SVG_PATH}.tmp"
mv -f "${SVG_PATH}.tmp" "${SVG_PATH}"

if [ "${INCLUDE_BOOT_PLOT}" = "true" ]; then
    log "generating boot plot ${BOOT_SVG_PATH}"
    systemd-analyze plot >"${BOOT_SVG_PATH}.tmp"
    mv -f "${BOOT_SVG_PATH}.tmp" "${BOOT_SVG_PATH}"
fi

publish_nginx() {
    local src="$1"
    local dest_dir="$2"
    local base
    base="$(basename "${src}")"
    if [ ! -f "${src}" ]; then
        return 0
    fi
    install -D -m 644 "${src}" "${dest_dir}/${base}.tmp"
    mv -f "${dest_dir}/${base}.tmp" "${dest_dir}/${base}"
}

if [ "${PUBLISH_NGINX}" = "true" ]; then
    if [ ! -d "$(dirname "${NGINX_DOCROOT}")" ] && [ ! -d "${NGINX_DOCROOT}" ]; then
        die "PUBLISH_NGINX=true but nginx docroot parent missing: ${NGINX_DOCROOT}"
    fi
    install -d -m 755 "${NGINX_DOCROOT}"
    log "publishing diagrams to ${NGINX_DOCROOT}"
    publish_nginx "${DOT_PATH}" "${NGINX_DOCROOT}"
    publish_nginx "${SVG_PATH}" "${NGINX_DOCROOT}"
    if [ "${INCLUDE_BOOT_PLOT}" = "true" ]; then
        publish_nginx "${BOOT_SVG_PATH}" "${NGINX_DOCROOT}"
    fi
    if [ -f /usr/share/systemd-diagrams/index.html ]; then
        install -D -m 644 /usr/share/systemd-diagrams/index.html \
            "${NGINX_DOCROOT}/index.html.tmp"
        mv -f "${NGINX_DOCROOT}/index.html.tmp" "${NGINX_DOCROOT}/index.html"
    fi
fi

log "done"
