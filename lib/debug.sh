#!/bin/bash
# ==============================================================================
# FVPN - Debug Inspector Module (Logical & Physical Diagnostics)
# FVPN - デバッグ・インスペクターモジュール (論理＆物理診断)
# Version : 1.2.0 (Dispatch Architecture)
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. Inspect Physical System State (_phy_inspect_system_state)
# 1. 物理層システム状態のインスペクト (_phy_inspect_system_state)
# ------------------------------------------------------------------------------
_phy_inspect_system_state() {
    local tag="${1:-INSPECT}"

    echo -e "\033[33m=========== [ PHYSICAL SYSTEM STATE : ${tag} ] ===========\033[0m"
    
    # 1. Check physical NIC / VPN tunnel (tun) existence / 物理NIC / VPNトンネル(tun) の存在確認
    echo -e "\033[1m[NET INTERFACES]\033[0m"
    ip -br link 2>/dev/null | sed 's/^/  /'

    # 2. Actual routing table (IPv4 / IPv6) / 実際のルーティングテーブル (IPv4 / IPv6)
    echo -e "\033[1m[IPv4 DEFAULT ROUTE]\033[0m"
    ip route list default 2>/dev/null | sed 's/^/  /'
    echo -e "\033[1m[IPv6 DEFAULT ROUTE]\033[0m"
    ip -6 route list default 2>/dev/null | sed 's/^/  /'

    # 3. iptables / ip6tables default policies / iptables / ip6tables デフォルトポリシー
    echo -e "\033[1m[FIREWALL POLICIES]\033[0m"
    echo "  v4 INPUT  : $(sudo iptables -L INPUT -n 2>/dev/null | head -n 1)"
    echo "  v4 OUTPUT : $(sudo iptables -L OUTPUT -n 2>/dev/null | head -n 1)"
    echo "  v6 INPUT  : $(sudo ip6tables -L INPUT -n 2>/dev/null | head -n 1)"
    echo "  v6 OUTPUT : $(sudo ip6tables -L OUTPUT -n 2>/dev/null | head -n 1)"

    # 4. OpenVPN process status / OpenVPNプロセスの実態
    local ovpn_pids
    ovpn_pids=$(pgrep -x openvpn 2>/dev/null | tr '\n' ' ')
    echo -e "\033[1m[OPENVPN PROCESSES]\033[0m"
    echo "  Active PIDs: ${ovpn_pids:-None}"

    echo -e "\033[33m==========================================================================\033[0m"
}

# ------------------------------------------------------------------------------
# 2. Internal Logical Register Dump (dump_debug_registers_internal)
# 2. 論理層レジスタダンプ内部処理 (dump_debug_registers_internal)
# ------------------------------------------------------------------------------
dump_debug_registers_internal() {
    local data_dir="${FVPN_DATA:-./data}"

    # --- [Direct retrieval of target server string (On-memory buffer reference)] ---
    # --- [注目サーバー文字列のダイレクト取得 (オンメモリバッファ参照)] ---
    local current_target_str="None"
    
    # Retrieve only if TARGET_INDEX >= 0 and ACTIVE_SERVERS_BUFFER is not empty
    # TARGET_INDEX が 0 以上かつ ACTIVE_SERVERS_BUFFER にデータが存在する場合のみ取得
    if [ "${TARGET_INDEX:--1}" -ge 0 ] && [ -n "$ACTIVE_SERVERS_BUFFER" ]; then
        local rec_size="${RECORD_BYTE_SIZE:-128}"
        local offset=$((TARGET_INDEX * rec_size))
        if [ "$offset" -lt "${#ACTIVE_SERVERS_BUFFER}" ]; then
            local line
            line="${ACTIVE_SERVERS_BUFFER:$offset:$rec_size}"
            line=$(echo "$line" | tr -d '\r\n')
            [ -n "$line" ] && current_target_str=$(echo "$line" | sed 's/[[:space:]]*$//')
        fi
    fi

    # --- [Physical layer status retrieval (Pure Read-Only)] ---
    # --- [物理層状態取得 (純粋Read-Only)] ---
    local conn_phy phy_mode pid_val auth_exist
    phy_mode=$(get_phy_mode 2>/dev/null)
    [ -z "$phy_mode" ] && phy_mode="DISCONNECTED"
    conn_phy=$(cat "${data_dir}/_phy_connected_server" 2>/dev/null | tr -d '\r\n')
    pid_val=$(cat "${FVPN_PID:-${data_dir}/fvpn.pid}" 2>/dev/null | tr -d '\r\n')
    [ -z "$pid_val" ] && pid_val="None"

    # PIDが数値で存在していても、該当PIDがOpenVPNでなければ異常と判定
    if [ "$pid_val" != "None" ]; then
        if [[ "$pid_val" =~ ^[0-9]+$ ]]; then
            # 1. まずプロセスが存在するか確認 (kill -0)
            if ! kill -0 "$pid_val" 2>/dev/null; then
                pid_val="${pid_val} (Stale)"
            else
                # 2. 読み取り可能な場合のみ cmdline から OpenVPN かどうか確認
                if [ -r "/proc/$pid_val/cmdline" ]; then
                    local proc_cmdline
                    proc_cmdline=$(tr '\0' ' ' < "/proc/$pid_val/cmdline" 2>/dev/null)
                    if [[ -n "$proc_cmdline" && "$proc_cmdline" != *openvpn* ]]; then
                        pid_val="${pid_val} (PID reused)"
                    fi
                fi
            fi
        else
            pid_val="${pid_val} (Invalid PID)"
        fi
    fi

    auth_exist="NO"
    [ -e "${data_dir}/auth.conf" ] && auth_exist="YES"

    # --- [Screen Output] ---
    # --- [画面出力] ---
    echo "=================== [ DEBUG REGISTERS DUMP ] ==================="
    echo " [LOGICAL LAYER (SETTINGS & REGISTERS)]"
    echo "  * TARGET_INDEX          : ${TARGET_INDEX:-None}"
    echo "  * TARGET_SERVER         : '${TARGET_SERVER:-None}'"
    echo "  * CURRENT TARGET SERVER : '$current_target_str'"
    echo "  * CONNECT_MODE          : ${CONNECT_MODE:-None} (1:FIX, 2:SEQ, 3:RAND)"
    echo "  * PROTOCOL_MODE         : ${PROTOCOL_MODE:-None}"
    echo "  * FILTER_LEVEL          : ${FILTER_LEVEL:-None}"
    echo "  * TIMEOUT_VPN_CONNECT   : ${TIMEOUT_VPN_CONNECT:-30}s"
    echo " [PHYSICAL LAYER (REALTIME)]"
    echo "  * PHY_MODE              : $phy_mode"
    echo "  * CONNECTED SERVER      : '${conn_phy:-None}'"
    echo "  * OpenVPN PID / AuthConf: PID=$pid_val / auth.conf Exists=$auth_exist"
    echo " [DATA FILE COUNTS]"
    echo "  * MASTER COUNT (U / T / Sum): UDP=${FVPN_UDP_COUNT:-0} / TCP=${FVPN_TCP_COUNT:-0} / TOTAL=${FVPN_TOTAL_COUNT:-0}"
    echo "  * PASS COUNT (U / T / Sum)  : UDP=${ACTIVE_UDP_COUNT:-0} / TCP=${ACTIVE_TCP_COUNT:-0} / TOTAL=${ACTIVE_TOTAL_COUNT:-0}"
    echo "================================================================"
}

# ------------------------------------------------------------------------------
# 3. Main Dispatcher Entry Point (show_debug_registers)
# 3. メインディスパッチャー・エントリーポイント (show_debug_registers)
# ------------------------------------------------------------------------------
show_debug_registers() {
    local debug_lvl="${DEBUG:-0}"

    # DEBUG=0 なら何もせず即リターン
    [ "$debug_lvl" -eq 0 ] && return 0

    # DEBUG >= 1 : 論理レジスタダンプの実行
    if [ "$debug_lvl" -ge 1 ]; then
        dump_debug_registers_internal
    fi

    # DEBUG >= 2 : 物理層システム状態インスペクトの追加実行
    if [ "$debug_lvl" -ge 2 ]; then
        _phy_inspect_system_state "REG_DUMP"
    fi

    return 0
}
