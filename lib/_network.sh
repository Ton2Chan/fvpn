#!/bin/bash
# ==============================================================================
# FVPN - Physical Network Layer (Pure Command Routines Only)
# ==============================================================================

# ------------------------------------------------------------------------------
# 0. Physical Mode Getter & Internal Cleanup Routines
# ------------------------------------------------------------------------------
get_phy_mode() {
    if [ -f "$_PHY_STATE_FILE" ]; then
        cat "$_PHY_STATE_FILE" | tr -d '\r\n'
    else
        echo "DISCONNECTED"
    fi
}

# Internal: Forcefully delete all 3 physical state files at once
_phy_cleanup_temp_files() {
    sudo rm -f "$_PHY_STATE_FILE" "$_PHY_CONNECTED_SERVER_FILE" "$_PHY_PID_FILE"
    rm -f "$_PHY_STATE_FILE" "$_PHY_CONNECTED_SERVER_FILE" "$_PHY_PID_FILE"
}

# For intermediate layers/external use: Safely clean up state files only if disconnected
phy_cleanup_if_disconnected() {
    if [ "$(get_phy_mode)" = "DISCONNECTED" ]; then
        _phy_cleanup_temp_files
    fi
}

# ------------------------------------------------------------------------------
# 1. DNS Apply & Backup/Restore Routines (Fail-Safe DNS Protection)
# ------------------------------------------------------------------------------

# Apply DNS (When connection is established)
_phy_dns_apply() {
    local resolv_conf="$FILE_RESOLV_CONF"
    local resolv_bak="$FILE_RESOLV_BACKUP"
    local dns_server="$FVPN_DNS_SERVER"

    # Save latest resolv.conf to backup only when in raw IP state
    if [ -f "$resolv_conf" ] && ! grep -q "$dns_server" "$resolv_conf"; then
        sudo cp -f "$resolv_conf" "$resolv_bak"
    fi

    # Overwrite with VPN DNS
    echo "nameserver $dns_server" | sudo tee "$resolv_conf" >/dev/null
}

# Restore DNS (Upon disconnection & boot-time cleanup)
_phy_dns_restore() {
    local resolv_conf="$FILE_RESOLV_CONF"
    local resolv_bak="$FILE_RESOLV_BACKUP"

    if [ -f "$resolv_bak" ]; then
        sudo cp -f "$resolv_bak" "$resolv_conf"
    elif grep -q "$FVPN_DNS_SERVER" "$resolv_conf"; then
        printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\n" | sudo tee "$resolv_conf" >/dev/null
    fi
}

# ------------------------------------------------------------------------------
# 2. Safe OpenVPN Termination & PID File Removal
# ------------------------------------------------------------------------------
_phy_openvpn_kill() {
    if [ -f "$_PHY_PID_FILE" ]; then
        local pid
        pid=$(cat "$_PHY_PID_FILE" 2>/dev/null | tr -d '\r\n')

        # Check if PID is numeric and the process exists
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            # Terminate specific OpenVPN process started by fvpn
            sudo kill -9 "$pid" >/dev/null 2>&1
        fi
    fi

    # Delete PID file
    sudo rm -f "$_PHY_PID_FILE"
    rm -f "$_PHY_PID_FILE"
    return 0
}

# ------------------------------------------------------------------------------
# 3. Immediate Removal of All tun Devices
# ------------------------------------------------------------------------------
_phy_tun_clear() {
    local tun_dev
    for tun_dev in $(ip link show | grep -o 'tun[0-9]*'); do
        sudo ip link set dev "$tun_dev" down
        sudo ip link delete dev "$tun_dev"
    done
    return 0
}

# ------------------------------------------------------------------------------
# 4. Check Connectivity and IP Existence on tun Interfaces
# ------------------------------------------------------------------------------
_phy_tun_check() {
    if ip -4 addr show | grep -q 'inet .* tun[0-9]*'; then
        return 0
    fi
    return 1
}

# ------------------------------------------------------------------------------
# 5. Physical Layer Firewall Flush (Flush All Rules)
# ------------------------------------------------------------------------------
_phy_fw_flush() {
    sudo iptables -P INPUT ACCEPT
    sudo iptables -P FORWARD ACCEPT
    sudo iptables -P OUTPUT ACCEPT
    sudo iptables -F
    sudo iptables -X
    sudo iptables -t nat -F
    sudo iptables -t nat -X

    sudo ip6tables -P INPUT ACCEPT
    sudo ip6tables -P FORWARD ACCEPT
    sudo ip6tables -P OUTPUT ACCEPT
    sudo ip6tables -F
    sudo ip6tables -X
    sudo ip6tables -t nat -F
    sudo ip6tables -t nat -X
}

# ------------------------------------------------------------------------------
# 6. Kill Switch (Block all traffic except to the target VPN server)
# Arguments: $1 = target_ip, $2 = target_port, $3 = target_proto
# ------------------------------------------------------------------------------
_phy_fw_killswitch() {
    local r_ip="$1"
    local r_port="$2"
    local r_proto="$3"

    # 1. Clear IPv4 / IPv6 tables
    sudo iptables -F
    sudo ip6tables -F

    # 2. Set default policy to DROP (Total Block)
    sudo iptables -P INPUT DROP
    sudo iptables -P FORWARD DROP
    sudo iptables -P OUTPUT DROP

    sudo ip6tables -P INPUT DROP
    sudo ip6tables -P FORWARD DROP
    sudo ip6tables -P OUTPUT DROP

    # 3. Allow local loopback (lo)
    sudo iptables -A INPUT -i lo -j ACCEPT
    sudo iptables -A OUTPUT -o lo -j ACCEPT
    sudo ip6tables -A INPUT -i lo -j ACCEPT
    sudo ip6tables -A OUTPUT -o lo -j ACCEPT

    # 4. Allow round-trip traffic ONLY with the designated VPN server IP
    if [ -n "$r_ip" ] && [ -n "$r_port" ] && [ -n "$r_proto" ]; then
        sudo iptables -A OUTPUT -p "$r_proto" -d "$r_ip" --dport "$r_port" -j ACCEPT
        sudo iptables -A INPUT  -p "$r_proto" -s "$r_ip" --sport "$r_port" -j ACCEPT
    fi

    # 5. Allow all encrypted traffic through the VPN virtual interface (tun+)
    sudo iptables -A INPUT  -i tun+ -j ACCEPT
    sudo iptables -A OUTPUT -o tun+ -j ACCEPT

    return 0
}

# ------------------------------------------------------------------------------
# 7. Start OpenVPN Daemon (Pass numerical IP to --remote)
# Arguments: $1 = ovpn_file, $2 = auth_file, $3 = ip, $4 = port, $5 = proto
# ------------------------------------------------------------------------------
_phy_openvpn_start() {
    local ovpn_file="$1"
    local auth_file="$2"
    local r_ip="$3"
    local r_port="$4"
    local r_proto="$5"
    local log_dir="${FVPN_LOGDIR:-./logs}"
    local log_file="${log_dir}/openvpn.log"
    local log_old="${log_file}.old"
    # Max size threshold: 8192 (8KB / 2 blocks) - 256 (max expected line length) = 7936 bytes
    local max_size=7936

    if [ ! -f "$ovpn_file" ] || [ ! -f "$auth_file" ]; then
        return 1
    fi

    # 2-Generation log rotation: Ensure disk usage stays within 8KB (2 blocks)
    if [ -f "$log_file" ]; then
        local current_size
        current_size=$(stat -c%s "$log_file" 2>/dev/null || echo 0)
        if [ "$current_size" -gt "$max_size" ]; then
            rm -f "$log_old"
            mv "$log_file" "$log_old"
        fi
    fi

    sudo touch "$log_file" "$_PHY_PID_FILE" 2>/dev/null
    sudo chmod 666 "$log_file" "$_PHY_PID_FILE" 2>/dev/null

    # Pass IP and Port to --remote to avoid protocol specification errors
    # Added --verb 3 and --mute 10 to completely protect against log growth during error loops
    ( sudo openvpn \
        --config "$ovpn_file" \
        --remote "$r_ip" "$r_port" \
        --auth-user-pass "$auth_file" \
        --allow-compression asym \
        --connect-timeout 15 \
        --verb 3 \
        --mute 10 \
        --daemon \
        --writepid "$_PHY_PID_FILE" \
        --log "$log_file" ) >/dev/null 2>&1

    return $?
}

# ------------------------------------------------------------------------------
# 8. Physical Layer Disconnect Routine
# ------------------------------------------------------------------------------
phy_disconnect() {
    killall vpn_monitor.sh >/dev/null 2>&1
    
    # Store PID before killing
    local pid=""
    if [ -f "$_PHY_PID_FILE" ]; then
        pid=$(cat "$_PHY_PID_FILE" 2>/dev/null | tr -d '\r\n')
    fi

    _phy_openvpn_kill
    
    # [Safety Net] Forcefully kill any lingering/runaway OpenVPN processes
    sudo killall -9 openvpn >/dev/null 2>&1

    _phy_tun_clear

    # Check if fvpn process is still remaining
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        return 1
    fi

    _phy_fw_flush
    _phy_dns_restore
    _phy_cleanup_temp_files

    return 0
}

# ------------------------------------------------------------------------------
# 9. App Boot-Time Physical Initialization
# ------------------------------------------------------------------------------
_phy_boot() {
    local resolv_conf="$FILE_RESOLV_CONF"
    local resolv_bak="$FILE_RESOLV_BACKUP"

    if [ ! -f "$resolv_bak" ] && [ -f "$resolv_conf" ]; then
        sudo cp -f "$resolv_conf" "$resolv_bak"
    fi

    local last_mode
    last_mode=$(get_phy_mode)

    if [ "$last_mode" = "DISCONNECTED" ]; then
        _phy_openvpn_kill
        _phy_tun_clear
        _phy_fw_flush
        _phy_dns_restore
        _phy_cleanup_temp_files
        return 0
    fi

    if [ "$last_mode" = "CONNECTED" ]; then
        if pgrep -x openvpn >/dev/null && _phy_tun_check; then
            return 0
        fi
        _phy_fw_killswitch
        echo "LOCKDOWN" > "$_PHY_STATE_FILE"
        return 0
    fi

    if [ "$last_mode" = "LOCKDOWN" ]; then
        _phy_fw_killswitch
        return 0
    fi

    _phy_openvpn_kill
    _phy_tun_clear
    _phy_fw_flush
    _phy_dns_restore
    _phy_cleanup_temp_files
    return 0
}
