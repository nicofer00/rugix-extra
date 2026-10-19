#!/usr/bin/env bash
# Probe Cloudflare Tunnel edge connectivity and write an ephemeral protocol
# preference for this start only:
#   /run/cloudflared/protocol.env  →  PROTOCOL=quic|http2|auto
#
# Re-run on every cloudflared.service start (ExecStartPre). /run is tmpfs, so
# a reboot never traps a device on http2. A later restart re-probes and can
# switch back to quic when UDP/7844 becomes available.
#
# Decision (Cloudflare precheck semantics, port 7844):
#   UDP ok           → quic
#   UDP fail, TCP ok → http2  (skip multi-minute QUIC retry backoff)
#   both fail        → auto   (let cloudflared retry; do not fail this script)

set -euo pipefail

RUN_DIR="/run/cloudflared"
ENV_FILE="${RUN_DIR}/protocol.env"
EDGE_HOST="region1.v2.argotunnel.com"
EDGE_FALLBACK_IP="198.41.192.167"
EDGE_PORT=7844
PROBE_TIMEOUT=3

mkdir -p "${RUN_DIR}"

resolve_edge_ip() {
    local ip=""
    if command -v getent >/dev/null 2>&1; then
        ip="$(getent ahostsv4 "${EDGE_HOST}" 2>/dev/null | awk '{print $1; exit}' || true)"
    fi
    if [ -z "${ip}" ] && command -v dig >/dev/null 2>&1; then
        ip="$(dig +short A "${EDGE_HOST}" 2>/dev/null | awk '/^[0-9]+\./ {print; exit}' || true)"
    fi
    if [ -z "${ip}" ]; then
        ip="${EDGE_FALLBACK_IP}"
        echo "cloudflared-select-protocol: DNS for ${EDGE_HOST} failed; using ${ip}"
    else
        echo "cloudflared-select-protocol: edge ${EDGE_HOST} -> ${ip}"
    fi
    printf '%s\n' "${ip}"
}

# TCP connect to edge:7844. Returns 0 on success.
probe_tcp() {
    local ip="$1"
    if command -v timeout >/dev/null 2>&1; then
        timeout "${PROBE_TIMEOUT}" bash -c "echo >/dev/tcp/${ip}/${EDGE_PORT}" 2>/dev/null
        return $?
    fi
    bash -c "echo >/dev/tcp/${ip}/${EDGE_PORT}" 2>/dev/null
}

# UDP reachability to edge:7844. Prefer a real datagram send (python3) over
# nc -u -z, which can report success without proving the path works.
probe_udp() {
    local ip="$1"
    if command -v python3 >/dev/null 2>&1; then
        python3 - "${ip}" "${EDGE_PORT}" "${PROBE_TIMEOUT}" <<'PY'
import socket, sys
ip, port, timeout = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.settimeout(timeout)
try:
    # Minimal payload; edge may not reply. Success = send without local error
    # (e.g. ICMP unreachable). Silent drops still look like success — same
    # limitation as Cloudflare's nc -uvz precheck; Type=notify covers that.
    sock.sendto(b"\x00", (ip, port))
    try:
        sock.recvfrom(64)
    except socket.timeout:
        pass
    sys.exit(0)
except OSError:
    sys.exit(1)
finally:
    sock.close()
PY
        return $?
    fi
    if command -v nc >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1; then
        timeout "${PROBE_TIMEOUT}" nc -u -z -w "${PROBE_TIMEOUT}" "${ip}" "${EDGE_PORT}" >/dev/null 2>&1
        return $?
    fi
    # No usable UDP probe — treat as unknown failure so we do not force quic.
    return 1
}

write_protocol() {
    local protocol="$1"
    umask 022
    printf 'PROTOCOL=%s\n' "${protocol}" > "${ENV_FILE}"
    echo "cloudflared-select-protocol: selected PROTOCOL=${protocol} (-> ${ENV_FILE})"
}

EDGE_IP="$(resolve_edge_ip)"

UDP_OK=0
TCP_OK=0
if probe_udp "${EDGE_IP}"; then
    UDP_OK=1
fi
if probe_tcp "${EDGE_IP}"; then
    TCP_OK=1
fi

echo "cloudflared-select-protocol: probe udp=$UDP_OK tcp=$TCP_OK host=${EDGE_IP}:${EDGE_PORT}"

if [ "${UDP_OK}" -eq 1 ]; then
    write_protocol "quic"
elif [ "${TCP_OK}" -eq 1 ]; then
    write_protocol "http2"
else
    write_protocol "auto"
fi
