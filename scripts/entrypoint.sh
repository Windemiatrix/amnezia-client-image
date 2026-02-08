#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# entrypoint.sh — AmneziaWG VPN client entrypoint
# =============================================================================

# --- Default environment variables -------------------------------------------
WG_CONFIG_FILE="${WG_CONFIG_FILE:-/config/wg0.conf}"
LOG_LEVEL="${LOG_LEVEL:-info}"
KILL_SWITCH="${KILL_SWITCH:-1}"
HEALTH_CHECK_HOST="${HEALTH_CHECK_HOST:-1.1.1.1}"

# --- Logging helpers ---------------------------------------------------------
log()   { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
debug() { if [[ "$LOG_LEVEL" == "debug" ]]; then log "[DEBUG] $*"; fi; }
info()  { log "[INFO]  $*"; }
warn()  { log "[WARN]  $*"; }
error() { log "[ERROR] $*"; }

# --- Enable trace mode for debug ---------------------------------------------
if [[ "$LOG_LEVEL" == "debug" ]]; then
    set -x
fi

# --- Validate configuration --------------------------------------------------
info "AmneziaWG client starting..."
debug "WG_CONFIG_FILE=$WG_CONFIG_FILE"
debug "LOG_LEVEL=$LOG_LEVEL"
debug "KILL_SWITCH=$KILL_SWITCH"
debug "HEALTH_CHECK_HOST=$HEALTH_CHECK_HOST"

if [[ ! -f "$WG_CONFIG_FILE" ]]; then
    error "Configuration file not found: $WG_CONFIG_FILE"
    error "Mount a volume with your .conf file to /config"
    exit 1
fi

# --- Validate config format ([Interface] + [Peer]) --------------------------
if ! grep -q '^\[Interface\]' "$WG_CONFIG_FILE"; then
    error "Invalid config: missing [Interface] section in $WG_CONFIG_FILE"
    exit 1
fi
if ! grep -q '^\[Peer\]' "$WG_CONFIG_FILE"; then
    error "Invalid config: missing [Peer] section in $WG_CONFIG_FILE"
    exit 1
fi
info "Config validated: [Interface] and [Peer] sections found"

# --- Derive interface name from config filename ------------------------------
CONFIG_BASENAME="$(basename "$WG_CONFIG_FILE")"
WG_INTERFACE="${CONFIG_BASENAME%.conf}"
debug "Interface name: $WG_INTERFACE"

# --- Copy config to tmp with secure permissions ------------------------------
TEMP_CONFIG="/tmp/${CONFIG_BASENAME}"
cp "$WG_CONFIG_FILE" "$TEMP_CONFIG"
chmod 600 "$TEMP_CONFIG"
info "Config copied to $TEMP_CONFIG (mode 600)"

# --- Write interface name for healthcheck ------------------------------------
echo "$WG_INTERFACE" > /run/wg_interface

# --- Parse Endpoint IP/host and port from config -----------------------------
ENDPOINT_LINE="$(grep -i '^\s*Endpoint\s*=' "$TEMP_CONFIG" | head -1 | sed 's/.*=\s*//')"
debug "Endpoint line: $ENDPOINT_LINE"

ENDPOINT_HOST=""
ENDPOINT_PORT=""
if [[ -n "$ENDPOINT_LINE" ]]; then
    # Handle [IPv6]:port or host:port
    if [[ "$ENDPOINT_LINE" =~ ^\[(.+)\]:([0-9]+)$ ]]; then
        ENDPOINT_HOST="${BASH_REMATCH[1]}"
        ENDPOINT_PORT="${BASH_REMATCH[2]}"
    elif [[ "$ENDPOINT_LINE" =~ ^(.+):([0-9]+)$ ]]; then
        ENDPOINT_HOST="${BASH_REMATCH[1]}"
        ENDPOINT_PORT="${BASH_REMATCH[2]}"
    fi
fi

# Detect whether endpoint is IPv4, IPv6, or hostname and resolve if needed
ENDPOINT_IP="$ENDPOINT_HOST"
ENDPOINT_IS_IPV6=false
if [[ -n "$ENDPOINT_HOST" ]]; then
    if echo "$ENDPOINT_HOST" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        debug "Endpoint is IPv4 address: $ENDPOINT_HOST"
    elif echo "$ENDPOINT_HOST" | grep -qE '^[0-9a-fA-F:]+$'; then
        debug "Endpoint is IPv6 address: $ENDPOINT_HOST"
        ENDPOINT_IS_IPV6=true
    else
        # Hostname — resolve to IP
        debug "Resolving hostname: $ENDPOINT_HOST"
        RESOLVED_IP="$(getent hosts "$ENDPOINT_HOST" 2>/dev/null | awk '{print $1; exit}')" || true
        if [[ -n "$RESOLVED_IP" ]]; then
            ENDPOINT_IP="$RESOLVED_IP"
            info "Resolved $ENDPOINT_HOST → $ENDPOINT_IP"
            # Check if resolved to IPv6
            if echo "$RESOLVED_IP" | grep -qE ':'; then
                ENDPOINT_IS_IPV6=true
            fi
        else
            warn "Could not resolve $ENDPOINT_HOST, using as-is"
        fi
    fi
fi
debug "Endpoint: $ENDPOINT_IP:$ENDPOINT_PORT (IPv6=$ENDPOINT_IS_IPV6)"

# --- Parse DNS from config ---------------------------------------------------
DNS_SERVERS=""
DNS_LINE="$(grep -i '^\s*DNS\s*=' "$TEMP_CONFIG" | head -1 | sed 's/.*=\s*//' | tr -d ' ')" || true
if [[ -n "$DNS_LINE" ]]; then
    DNS_SERVERS="$DNS_LINE"
    debug "DNS servers: $DNS_SERVERS"
fi

# --- Kill Switch (iptables + ip6tables rules) --------------------------------
setup_kill_switch() {
    info "Setting up kill switch..."

    # Flush existing IPv4 rules
    iptables -F OUTPUT 2>/dev/null || true
    iptables -F INPUT 2>/dev/null || true

    # Flush existing IPv6 rules
    ip6tables -F OUTPUT 2>/dev/null || true
    ip6tables -F INPUT 2>/dev/null || true

    # 1. Allow loopback (IPv4 + IPv6)
    iptables -A OUTPUT -o lo -j ACCEPT
    iptables -A INPUT -i lo -j ACCEPT
    ip6tables -A OUTPUT -o lo -j ACCEPT
    ip6tables -A INPUT -i lo -j ACCEPT
    debug "Kill switch: loopback allowed (IPv4+IPv6)"

    # 2. Allow traffic to AmneziaWG endpoint
    if [[ -n "$ENDPOINT_IP" && -n "$ENDPOINT_PORT" ]]; then
        if [[ "$ENDPOINT_IS_IPV6" == "true" ]]; then
            ip6tables -A OUTPUT -d "$ENDPOINT_IP" -p udp --dport "$ENDPOINT_PORT" -j ACCEPT
            ip6tables -A INPUT -s "$ENDPOINT_IP" -p udp --sport "$ENDPOINT_PORT" -j ACCEPT
        else
            iptables -A OUTPUT -d "$ENDPOINT_IP" -p udp --dport "$ENDPOINT_PORT" -j ACCEPT
            iptables -A INPUT -s "$ENDPOINT_IP" -p udp --sport "$ENDPOINT_PORT" -j ACCEPT
        fi
        debug "Kill switch: endpoint $ENDPOINT_IP:$ENDPOINT_PORT allowed"
    fi

    # 3. Allow traffic through VPN interface (IPv4 + IPv6)
    iptables -A OUTPUT -o "$WG_INTERFACE" -j ACCEPT
    iptables -A INPUT -i "$WG_INTERFACE" -j ACCEPT
    ip6tables -A OUTPUT -o "$WG_INTERFACE" -j ACCEPT
    ip6tables -A INPUT -i "$WG_INTERFACE" -j ACCEPT
    debug "Kill switch: VPN interface $WG_INTERFACE allowed (IPv4+IPv6)"

    # 4. Allow ICMPv6 essential messages (neighbor discovery, etc.)
    ip6tables -A OUTPUT -p icmpv6 --icmpv6-type neighbor-solicitation -j ACCEPT
    ip6tables -A OUTPUT -p icmpv6 --icmpv6-type neighbor-advertisement -j ACCEPT
    ip6tables -A OUTPUT -p icmpv6 --icmpv6-type router-solicitation -j ACCEPT
    ip6tables -A INPUT -p icmpv6 --icmpv6-type neighbor-solicitation -j ACCEPT
    ip6tables -A INPUT -p icmpv6 --icmpv6-type neighbor-advertisement -j ACCEPT
    ip6tables -A INPUT -p icmpv6 --icmpv6-type router-advertisement -j ACCEPT
    debug "Kill switch: ICMPv6 neighbor discovery allowed"

    # 5. Allow DNS traffic to configured DNS servers (IPv4 + IPv6)
    if [[ -n "$DNS_SERVERS" ]]; then
        IFS=',' read -ra DNS_ARRAY <<< "$DNS_SERVERS"
        for dns in "${DNS_ARRAY[@]}"; do
            dns="$(echo "$dns" | tr -d ' ')"
            if echo "$dns" | grep -qE ':'; then
                # IPv6 DNS server
                ip6tables -A OUTPUT -d "$dns" -p udp --dport 53 -j ACCEPT
                ip6tables -A OUTPUT -d "$dns" -p tcp --dport 53 -j ACCEPT
                ip6tables -A INPUT -s "$dns" -p udp --sport 53 -j ACCEPT
                ip6tables -A INPUT -s "$dns" -p tcp --sport 53 -j ACCEPT
            else
                # IPv4 DNS server
                iptables -A OUTPUT -d "$dns" -p udp --dport 53 -j ACCEPT
                iptables -A OUTPUT -d "$dns" -p tcp --dport 53 -j ACCEPT
                iptables -A INPUT -s "$dns" -p udp --sport 53 -j ACCEPT
                iptables -A INPUT -s "$dns" -p tcp --sport 53 -j ACCEPT
            fi
            debug "Kill switch: DNS $dns allowed"
        done
    fi

    # 6. Allow established/related connections (IPv4 + IPv6)
    iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    ip6tables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    ip6tables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    debug "Kill switch: established/related allowed (IPv4+IPv6)"

    # 7. Drop everything else (IPv4 + IPv6)
    iptables -A OUTPUT -j DROP
    iptables -A INPUT -j DROP
    ip6tables -A OUTPUT -j DROP
    ip6tables -A INPUT -j DROP
    info "Kill switch enabled — all non-VPN traffic will be blocked (IPv4+IPv6)"
}

# --- Graceful shutdown -------------------------------------------------------
shutdown() {
    info "Shutting down..."
    awg-quick down "$WG_INTERFACE" 2>/dev/null || true
    info "AmneziaWG interface $WG_INTERFACE removed"
    exit 0
}
trap shutdown SIGTERM SIGINT

# --- Apply kill switch before bringing up VPN --------------------------------
if [[ "$KILL_SWITCH" == "1" ]]; then
    setup_kill_switch
else
    info "Kill switch disabled"
fi

# --- Bring up AmneziaWG interface --------------------------------------------
info "Bringing up interface $WG_INTERFACE..."
WG_QUICK_USERSPACE_IMPLEMENTATION=amneziawg-go awg-quick up "$TEMP_CONFIG"
info "Interface $WG_INTERFACE is up"

# --- Setup NAT MASQUERADE for gateway mode (IPv4 + IPv6) --------------------
iptables -t nat -A POSTROUTING -o "$WG_INTERFACE" -j MASQUERADE
ip6tables -t nat -A POSTROUTING -o "$WG_INTERFACE" -j MASQUERADE 2>/dev/null || true
debug "NAT MASQUERADE enabled on $WG_INTERFACE (IPv4+IPv6)"

# --- Log status --------------------------------------------------------------
info "AmneziaWG client is running"
if [[ "$LOG_LEVEL" == "debug" ]]; then
    debug "--- Interface info ---"
    awg show "$WG_INTERFACE" || true
    ip addr show "$WG_INTERFACE" || true
    debug "--- Routing table ---"
    ip route show || true
    ip -6 route show 2>/dev/null || true
    debug "--- iptables rules ---"
    iptables -L -n -v 2>/dev/null || true
    debug "--- ip6tables rules ---"
    ip6tables -L -n -v 2>/dev/null || true
    debug "--- NAT rules ---"
    iptables -t nat -L -n -v 2>/dev/null || true
    ip6tables -t nat -L -n -v 2>/dev/null || true
fi

# --- Wait forever (handle signals) -------------------------------------------
sleep infinity &
wait $!
