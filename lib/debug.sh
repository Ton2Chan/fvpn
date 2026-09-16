#!/bin/bash
# ==============================================================================
# FVPN - Debug Inspector Module (Logical & Physical Diagnostics)
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. Physical System State Inspector (_phy_inspect_system_state)
# ------------------------------------------------------------------------------
_phy_inspect_system_state() {
    local tag="${1:-INSPECT}"
    
    # Return immediately if DEBUG is less than 2
    [ "${DEBUG}" -ge 2 ] || return 0

    echo -e "\033[33m=========== [ PHYSICAL SYSTEM STATE : ${tag} ] ===========\033[0m"
    
    # 1. Check physical NIC / VPN tunnel (tun) existence
    echo -e "\033[1m[NET INTERFACES]\033[0m"
    ip -br link 2>/dev/null | sed 's/^/  /'

    # 2. Check actual routing table (IPv4 / IPv6)
    echo -e "\033[1m[IPv4 DEFAULT ROUTE]\033[0m"
    ip route list default 2>/dev/null | sed 's/^/  /'
    echo -e "\033[1m[IPv6 DEFAULT ROUTE]\033[0m"
    ip -6 route list default 2>/dev/null | sed 's/^/  /'

    # 3. Check iptables / ip6tables default policies
    echo -e "\033[1m[FIREWALL POLICIES]\033[0m"
    echo "  v4 INPUT  : $(sudo iptables -L INPUT -n 2>/dev/null | head -n 1)"
    echo "  v4 OUTPUT : $(sudo iptables -L OUTPUT -n 2>/dev/null | head -n 1)"
    echo "  v6 INPUT  : $(sudo ip6tables -L INPUT -n 2>/dev/null | head -n 1)"
    echo "  v6 OUTPUT : $(sudo ip6tables -L OUTPUT -n 2>/dev/null | head -n 1)"

    # 4. Check OpenVPN process status
    local ovpn_pids
    ovpn_pids=$(pgrep -f openvpn 2>/dev/null | tr '\n' ' ')
    echo -e "\033[1m[OPENVPN PROCESSES]\033[0m"
    echo "  Active PIDs: ${ovpn_pids:-None}"

    echo -e "\033[33m==========================================================================\033[0m"
}

# ------------------------------------------------------------------------------
# 2. Logical & Physical Layer Register Dump (show_debug_registers)
# ------------------------------------------------------------------------------
show_debug_registers() {
    # Return immediately if DEBUG=0
    [ "${DEBUG}" -eq 0 ] && return 0

    local data_dir="${FVPN_DATA:-./data}"

    # --- [ Direct retrieval of target server string (from in-memory buffer) ] ---
    local current_target_str="None"
    
    # Retrieve only if TARGET_INDEX >= 0 and ACTIVE_SERVERS_BUFFER contains data
    if [ "${TARGET_INDEX:--1}" -ge 0 ] && [ -n "$ACTIVE_SERVERS_BUFFER" ]; then
        local offset=$((TARGET_INDEX * RECORD_BYTE_SIZE))
        if [ "$offset" -lt "${#ACTIVE_SERVERS_BUFFER}" ]; then
            local line
            line="${ACTIVE_SERVERS_BUFFER:$offset:128}"
            line=$(echo "$line" | tr -d '\r\n')
            [ -n "$line" ] && current_target_str=$(echo "$line" | sed 's/[[:space:]]*$//')
        fi
    fi

    # --- [ Physical layer state retrieval (Read-Only) ] ---
    local conn_phy phy_mode pid_val auth_exist
    phy_mode=$(get_phy_mode)
    [ -z "$phy_mode" ] && phy_mode="DISCONNECTED"
    conn_phy=$(cat "${data_dir}/_phy_connected_server" 2>/dev/null | tr -d '\r\n')
    pid_val=$(cat "${data_dir}/_fvpn.pid" 2>/dev/null || echo "None")

    # If PID exists but process is not running, treat as None (Stale)
    if [ "$pid_val" != "None" ] && ! pgrep -x openvpn >/dev/null 2>&1; then
        pid_val="None (Stale)"
    fi

    auth_exist="NO"
    [ -e "${data_dir}/auth.conf" ] && auth_exist="YES"

    # --- [ Screen Output ] ---
    echo "=================== [ DEBUG REGISTERS DUMP ] ==================="
    echo " [LOGICAL LAYER (SETTINGS & REGISTERS)]"
    echo "  * TARGET_INDEX          : ${TARGET_INDEX}"
    echo "  * TARGET_SERVER         : '$TARGET_SERVER'"
    echo "  * CURRENT TARGET SERVER : '$current_target_str'"
    echo "  * CONNECT_MODE          : ${CONNECT_MODE} (1:FIX, 2:SEQ, 3:RAND)"
    echo "  * PROTOCOL_MODE         : ${PROTOCOL_MODE} (0:MIX, 1:UDP, -1:TCP)"
    echo "  * FILTER_LEVEL          : ${FILTER_LEVEL}"
    echo "  * TIMEOUT_VPN_CONNECT   : ${TIMEOUT_VPN_CONNECT:-30}s" # VPN Connection Timeout in seconds
    echo " [PHYSICAL LAYER (REALTIME)]"
    echo "  * PHY_MODE              : $phy_mode"
    echo "  * CONNECTED SERVER      : '${conn_phy:-None}'"
    echo "  * OpenVPN PID / AuthConf: PID=$pid_val / auth.conf Exists=$auth_exist"
    echo " [DATA FILE COUNTS]"
    echo "  * MASTER COUNT (U / T / Sum): UDP=${FVPN_UDP_COUNT} / TCP=${FVPN_TCP_COUNT:-0} / TOTAL=${FVPN_TOTAL_COUNT}"
    echo "  * PASS COUNT (U / T / Sum)  : UDP=${ACTIVE_UDP_COUNT} / TCP=${ACTIVE_TCP_COUNT} / TOTAL=${ACTIVE_TOTAL_COUNT}"
    echo "================================================================"
}
