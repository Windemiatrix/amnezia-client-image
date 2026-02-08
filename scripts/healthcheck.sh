#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# healthcheck.sh — AmneziaWG VPN health check
# =============================================================================

HEALTH_CHECK_HOST="${HEALTH_CHECK_HOST:-1.1.1.1}"

# --- Read interface name written by entrypoint -------------------------------
if [[ ! -f /run/wg_interface ]]; then
    echo "UNHEALTHY: /run/wg_interface not found"
    exit 1
fi
WG_INTERFACE="$(cat /run/wg_interface)"

# --- Check 1: VPN interface exists -------------------------------------------
if ! ip link show "$WG_INTERFACE" >/dev/null 2>&1; then
    echo "UNHEALTHY: interface $WG_INTERFACE does not exist"
    exit 1
fi

# --- Check 2: Latest handshake present --------------------------------------
HANDSHAKE="$(awg show "$WG_INTERFACE" latest-handshakes 2>/dev/null)" || true
if [[ -z "$HANDSHAKE" ]]; then
    echo "UNHEALTHY: no handshake data for $WG_INTERFACE"
    exit 1
fi

# Verify at least one peer has a non-zero handshake timestamp
HAS_HANDSHAKE=false
while IFS=$'\t' read -r _ timestamp; do
    if [[ -n "$timestamp" && "$timestamp" != "0" ]]; then
        HAS_HANDSHAKE=true
        break
    fi
done <<< "$HANDSHAKE"

if [[ "$HAS_HANDSHAKE" != "true" ]]; then
    echo "UNHEALTHY: no recent handshake on $WG_INTERFACE"
    exit 1
fi

# --- Check 3: Ping through VPN interface -------------------------------------
if ! ping -c 1 -W 5 -I "$WG_INTERFACE" "$HEALTH_CHECK_HOST" >/dev/null 2>&1; then
    echo "UNHEALTHY: ping to $HEALTH_CHECK_HOST via $WG_INTERFACE failed"
    exit 1
fi

echo "HEALTHY"
exit 0
