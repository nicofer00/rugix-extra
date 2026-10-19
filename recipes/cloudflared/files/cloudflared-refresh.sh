#!/usr/bin/env bash
# Re-provision the tunnel and bring cloudflared back up.
#
# Use when another unit has rewritten /var/lib/cloudflared/device.env
# (e.g. TUNNEL_SUBDOMAIN) or when operators need a full refresh:
#   systemctl start cloudflared-refresh.service
#
# Stops the connector first so a subdomain change cannot leave the old
# tunnel connected while provision writes a new token.

set -euo pipefail

TOKEN_FILE="/var/lib/cloudflared/tunnel.token"

echo "cloudflared-refresh: stopping cloudflared (if running)"
systemctl stop cloudflared.service 2>/dev/null || true

echo "cloudflared-refresh: re-running cloudflared-provision"
systemctl restart cloudflared-provision.service

if [ -s "${TOKEN_FILE}" ]; then
    echo "cloudflared-refresh: starting cloudflared"
    systemctl start cloudflared.service
else
    echo "cloudflared-refresh: no tunnel token; leaving cloudflared stopped"
fi
