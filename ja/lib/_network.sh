#!/bin/bash
# ==============================================================================
# FVPN - Physical Network Layer (Pure Command Routines Only)
# ==============================================================================

# ------------------------------------------------------------------------------
# 0. 物理層モードゲッター & 内部クリーンアップルーチン
# ------------------------------------------------------------------------------
get_phy_mode() {
    if [ -f "$_PHY_STATE_FILE" ]; then
        cat "$_PHY_STATE_FILE" | tr -d '\r\n'
    else
        echo "DISCONNECTED"
    fi
}

# 内部用：物理ステートファイル3種を一括強制削除
_phy_cleanup_temp_files() {
    sudo rm -f "$_PHY_STATE_FILE" "$_PHY_CONNECTED_SERVER_FILE" "$_PHY_PID_FILE"
    rm -f "$_PHY_STATE_FILE" "$_PHY_CONNECTED_SERVER_FILE" "$_PHY_PID_FILE"
}

# 中間層/外部提供用：未接続状態の場合のみ安全にファイル群を掃除
phy_cleanup_if_disconnected() {
    if [ "$(get_phy_mode)" = "DISCONNECTED" ]; then
        _phy_cleanup_temp_files
    fi
}

# ------------------------------------------------------------------------------
# 1. DNS 適用 & バックアップ・復元ルーチン (Fail-Safe DNS Protection)
# ------------------------------------------------------------------------------

# DNS適用 (接続確立時)
_phy_dns_apply() {
    local resolv_conf="$FILE_RESOLV_CONF"
    local resolv_bak="$FILE_RESOLV_BACKUP"
    local dns_server="$FVPN_DNS_SERVER"

    # 生IP状態の場合のみ最新のresolv.confをバックアップへ保存
    if [ -f "$resolv_conf" ] && ! grep -q "$dns_server" "$resolv_conf"; then
        sudo cp -f "$resolv_conf" "$resolv_bak"
    fi

    # VPN用DNSに書き換え
    echo "nameserver $dns_server" | sudo tee "$resolv_conf" >/dev/null
}

# DNS復元 (切断時 & 起動時クリーンアップ)
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
# 2. OpenVPN プロセスの安全な終了 & PIDファイル削除
# ------------------------------------------------------------------------------
_phy_openvpn_kill() {
    if [ -f "$_PHY_PID_FILE" ]; then
        local pid
        pid=$(cat "$_PHY_PID_FILE" 2>/dev/null | tr -d '\r\n')

        # PIDが数値であり、かつそのプロセスが存在しているかチェック
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            # fvpn が起動した特定の OpenVPN プロセスのみを終了
            sudo kill -9 "$pid" >/dev/null 2>&1
        fi
    fi

    # PID ファイルの削除
    sudo rm -f "$_PHY_PID_FILE"
    rm -f "$_PHY_PID_FILE"
    return 0
}

# ------------------------------------------------------------------------------
# 3. tun デバイスの即時全削除
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
# 4. tunインターフェースの疎通・IP存在チェック
# ------------------------------------------------------------------------------
_phy_tun_check() {
    if ip -4 addr show | grep -q 'inet .* tun[0-9]*'; then
        return 0
    fi
    return 1
}

# ------------------------------------------------------------------------------
# 5. 物理層 ファイアウォール完全全開放
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
# 6. キルスイッチ (接続先VPNサーバー以外の通信を全遮断)
# 引数: $1 = target_ip, $2 = target_port, $3 = target_proto
# ------------------------------------------------------------------------------
_phy_fw_killswitch() {
    local r_ip="$1"
    local r_port="$2"
    local r_proto="$3"

    # 1. IPv4 / IPv6 テーブルの初期化
    sudo iptables -F
    sudo ip6tables -F

    # 2. IPv4 / IPv6 全ポリシーを DROP（完全遮断）
    sudo iptables -P INPUT DROP
    sudo iptables -P FORWARD DROP
    sudo iptables -P OUTPUT DROP

    sudo ip6tables -P INPUT DROP
    sudo ip6tables -P FORWARD DROP
    sudo ip6tables -P OUTPUT DROP

    # 3. ローカルループバック（lo）の許可
    sudo iptables -A INPUT -i lo -j ACCEPT
    sudo iptables -A OUTPUT -o lo -j ACCEPT
    sudo ip6tables -A INPUT -i lo -j ACCEPT
    sudo ip6tables -A OUTPUT -o lo -j ACCEPT

    # ❌ [DNS漏洩防止] 旧版にあった Port 53 (DNS) の直通許可 4行はここから削除 ❌

    # 4. 指定された生IPのVPNサーバーとの通信（往復）のみを許可
    if [ -n "$r_ip" ] && [ -n "$r_port" ] && [ -n "$r_proto" ]; then
        sudo iptables -A OUTPUT -p "$r_proto" -d "$r_ip" --dport "$r_port" -j ACCEPT
        sudo iptables -A INPUT  -p "$r_proto" -s "$r_ip" --sport "$r_port" -j ACCEPT
    fi

    # 5. VPN仮想インターフェース（tun+）を通る暗号化通信は全許可
    sudo iptables -A INPUT  -i tun+ -j ACCEPT
    sudo iptables -A OUTPUT -o tun+ -j ACCEPT

    return 0
}

# ------------------------------------------------------------------------------
# 7. OpenVPN デーモン起動 (--remote でバッファの数値IPを直渡し)
# 引数: $1 = ovpn_file, $2 = auth_file, $3 = ip, $4 = port, $5 = proto
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
    # 判定閾値: 8192 (8KB / 2ブロック) - 256 (1行の想定最大長) = 7936 バイト (0x1F00)
    local max_size=7936

    if [ ! -f "$ovpn_file" ] || [ ! -f "$auth_file" ]; then
        return 1
    fi

    # ログ2世代ローテーション: ディスク占有量を確実に 8KB(2ブロック) 以内に収める処理
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

    # IPとポートのみを --remote に渡し、プロトコル指定エラーを回避
    # 全体をサブシェル () で括り 画面のWARNINGを100%透明化
    ( sudo openvpn \
        --config "$ovpn_file" \
        --remote "$r_ip" "$r_port" \
        --auth-user-pass "$auth_file" \
        --allow-compression asym \
        --connect-timeout 15 \
        --daemon \
        --writepid "$_PHY_PID_FILE" \
        --log "$log_file" ) >/dev/null 2>&1

    return $?
}

# ------------------------------------------------------------------------------
# 8. 物理層 VPN切断処理
# ------------------------------------------------------------------------------
phy_disconnect() {
    killall vpn_monitor.sh >/dev/null 2>&1
    
    # 切断前にPIDを取得しておく
    local pid=""
    if [ -f "$_PHY_PID_FILE" ]; then
        pid=$(cat "$_PHY_PID_FILE" 2>/dev/null | tr -d '\r\n')
    fi

    _phy_openvpn_kill
    _phy_tun_clear

    # fvpn のプロセスがまだ残っていないかチェック
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        return 1
    fi

    _phy_fw_flush
    _phy_dns_restore
    _phy_cleanup_temp_files

    return 0
}

# ------------------------------------------------------------------------------
# 9. アプリ起動時専用 物理初期化
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
