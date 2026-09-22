#!/bin/bash
# ==============================================================================
# FVPN - Debug Inspector Module (Logical & Physical Diagnostics)
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. 物理層システム状態のインスペクト (_phy_inspect_system_state)
# ------------------------------------------------------------------------------
_phy_inspect_system_state() {
    local tag="${1:-INSPECT}"
    
    # DEBUGが2未満の場合は何もせず即リターン
    [ "${DEBUG}" -ge 2 ] || return 0

    echo -e "\033[33m=========== [ PHYSICAL SYSTEM STATE : ${tag} ] ===========\033[0m"
    
    # 1. 物理NIC / VPNトンネル(tun) の存在確認
    echo -e "\033[1m[NET INTERFACES]\033[0m"
    ip -br link 2>/dev/null | sed 's/^/  /'

    # 2. 実際のルーティングテーブル (IPv4 / IPv6)
    echo -e "\033[1m[IPv4 DEFAULT ROUTE]\033[0m"
    ip route list default 2>/dev/null | sed 's/^/  /'
    echo -e "\033[1m[IPv6 DEFAULT ROUTE]\033[0m"
    ip -6 route list default 2>/dev/null | sed 's/^/  /'

    # 3. iptables / ip6tables デフォルトポリシー
    echo -e "\033[1m[FIREWALL POLICIES]\033[0m"
    echo "  v4 INPUT  : $(sudo iptables -L INPUT -n 2>/dev/null | head -n 1)"
    echo "  v4 OUTPUT : $(sudo iptables -L OUTPUT -n 2>/dev/null | head -n 1)"
    echo "  v6 INPUT  : $(sudo ip6tables -L INPUT -n 2>/dev/null | head -n 1)"
    echo "  v6 OUTPUT : $(sudo ip6tables -L OUTPUT -n 2>/dev/null | head -n 1)"

    # 4. OpenVPNプロセスの実態
    local ovpn_pids
    ovpn_pids=$(pgrep -f openvpn 2>/dev/null | tr '\n' ' ')
    echo -e "\033[1m[OPENVPN PROCESSES]\033[0m"
    echo "  Active PIDs: ${ovpn_pids:-None}"

    echo -e "\033[33m==========================================================================\033[0m"
}

# ------------------------------------------------------------------------------
# 2. 論理層・物理層レジスタダンプ (show_debug_registers)
# ------------------------------------------------------------------------------
show_debug_registers() {
    # DEBUG=0 なら何もせず即リターン
    [ "${DEBUG}" -eq 0 ] && return 0

    local data_dir="${FVPN_DATA:-./data}"

    # --- [注目サーバー文字列のダイレクト取得 (オンメモリバッファ参照)] ---
    local current_target_str="None"
    
    # TARGET_INDEX が 0 以上かつ ACTIVE_SERVERS_BUFFER にデータが存在する場合のみ取得
    if [ "${TARGET_INDEX:--1}" -ge 0 ] && [ -n "$ACTIVE_SERVERS_BUFFER" ]; then
        local offset=$((TARGET_INDEX * RECORD_BYTE_SIZE))
        if [ "$offset" -lt "${#ACTIVE_SERVERS_BUFFER}" ]; then
            local line
            line="${ACTIVE_SERVERS_BUFFER:$offset:128}"
            line=$(echo "$line" | tr -d '\r\n')
            [ -n "$line" ] && current_target_str=$(echo "$line" | sed 's/[[:space:]]*$//')
        fi
    fi

    # --- [物理層状態取得 (純粋Read-Only)] ---
    local conn_phy phy_mode pid_val auth_exist
    phy_mode=$(get_phy_mode)
    [ -z "$phy_mode" ] && phy_mode="DISCONNECTED"
    conn_phy=$(cat "${data_dir}/_phy_connected_server" 2>/dev/null | tr -d '\r\n')
    pid_val=$(cat "${data_dir}/_fvpn.pid" 2>/dev/null || echo "None")

    # PIDが存在しても実際にプロセスが動いていなければ None とみなす
    if [ "$pid_val" != "None" ] && ! pgrep -x openvpn >/dev/null 2>&1; then
        pid_val="None (Stale)"
    fi

    auth_exist="NO"
    [ -e "${data_dir}/auth.conf" ] && auth_exist="YES"

    # --- [画面出力] ---
    echo "=================== [ DEBUG REGISTERS DUMP ] ==================="
    echo " [LOGICAL LAYER (SETTINGS & REGISTERS)]"
    echo "  * TARGET_INDEX          : ${TARGET_INDEX}"
    echo "  * TARGET_SERVER         : '$TARGET_SERVER'"
    echo "  * CURRENT TARGET SERVER : '$current_target_str'"
    echo "  * CONNECT_MODE          : ${CONNECT_MODE} (1:FIX, 2:SEQ, 3:RAND)"
    echo "  * PROTOCOL_MODE         : ${PROTOCOL_MODE} (0:MIX, 1:UDP, -1:TCP)"
    echo "  * FILTER_LEVEL          : ${FILTER_LEVEL}"
    echo "  * TIMEOUT_VPN_CONNECT   : ${TIMEOUT_VPN_CONNECT:-30}s" # ★追記: VPN接続タイムアウト秒数
    echo " [PHYSICAL LAYER (REALTIME)]"
    echo "  * PHY_MODE              : $phy_mode"
    echo "  * CONNECTED SERVER      : '${conn_phy:-None}'"
    echo "  * OpenVPN PID / AuthConf: PID=$pid_val / auth.conf Exists=$auth_exist"
    echo " [DATA FILE COUNTS]"
    echo "  * MASTER COUNT (U / T / Sum): UDP=${FVPN_UDP_COUNT} / TCP=${FVPN_TCP_COUNT:-0} / TOTAL=${FVPN_TOTAL_COUNT}"
    echo "  * PASS COUNT (U / T / Sum)  : UDP=${ACTIVE_UDP_COUNT} / TCP=${ACTIVE_TCP_COUNT} / TOTAL=${ACTIVE_TOTAL_COUNT}"
    echo "================================================================"
}
