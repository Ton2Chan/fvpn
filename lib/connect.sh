#!/bin/bash
# ==============================================================================
# FVPN - Connection Engine & Buffer Logic (Non-UI Core Operations)
# FVPN - 接続エンジン & バッファロジック (非UIコア操作)
# Version : 1.1.0
# ==============================================================================

# Network connectivity check (Silent boolean test function)
# ネットワーク疎通確認 (サイレント・ブール判定関数)
is_network_online() {
    ip route show default 2>/dev/null | grep -q "default via"
    return $?  # 0: ONLINE, 1: OFFLINE
}

# ==============================================================================
# Intermediate Tunnel Function (Pure Bridge)
# 中間層トンネル関数 (純粋ブリッジ)
# ==============================================================================

phy_connect() {
    local target_path="$1"
    local s_ip="$2"
    local s_port="$3"
    local s_proto="$4"

    local auth_file="${FVPN_AUTH:-${FVPN_DATA}/auth.conf}"
    local state_file="${_PHY_STATE_FILE:-${FVPN_DATA}/_phy_mode}"
    local conn_file="${_PHY_CONNECTED_SERVER_FILE:-${FVPN_DATA}/_phy_connected_server}"
    local pid_file="${FVPN_PID:-${FVPN_DATA}/fvpn.pid}"
    local log_file="${FVPN_LOGDIR}/openvpn.log"
    local timeout="${TIMEOUT_VPN_CONNECT:-30}"

    [ ! -f "$auth_file" ] && auth_file="${FVPN_DATA}/auth.conf"

    # Ensure clean state by resetting existing OpenVPN processes and TUN interfaces
    # 既存のOpenVPNとTUNを確実に整理
    _phy_openvpn_kill
    _phy_tun_clear

    # Apply kill switch before connection launch / 起動前のキルスイッチ適用
    _phy_fw_killswitch "$s_ip" "$s_port" "$s_proto"

    # Start OpenVPN daemon / OpenVPN起動
    _phy_openvpn_start \
        "$target_path" \
        "$auth_file" \
        "$s_ip" \
        "$s_port" \
        "$s_proto"

    if [ $? -ne 0 ]; then
        echo "LOCKDOWN" > "$state_file" 2>/dev/null
        rm -f "$conn_file" "$pid_file" 2>/dev/null
        return 1
    fi

    local i
    local ret_code=1

    for (( i=1; i<=timeout; i++ )); do

        # 1. Successful VPN connection / VPN接続成功
        if _phy_tun_check; then
            echo "CONNECTED" > "$state_file" 2>/dev/null
            echo "$target_path" > "$conn_file" 2>/dev/null

            _phy_dns_apply

            export AUTH_STATE=1
            return 0
        fi

        # 2. Process vitality monitoring for OpenVPN / OpenVPNプロセスの死活監視
        # Skip monitoring if PID file is empty right after launch
        # _phy_openvpn_start() はPIDファイルを先に作成するため、起動直後などPIDの中身がまだ空の場合は監視をスキップする。
        if [ -s "$pid_file" ]; then
            local openvpn_pid
            openvpn_pid=$(cat "$pid_file" 2>/dev/null)

            if [[ "$openvpn_pid" =~ ^[0-9]+$ ]] &&
               [ "$openvpn_pid" -gt 0 ]; then

                local proc_cmdline
                proc_cmdline=$(tr '\0' ' ' < "/proc/$openvpn_pid/cmdline" 2>/dev/null)

                # If process corresponding to PID does not exist or PID was reused
                # PIDに対応するプロセスが存在しない、または別プロセスにPIDが再利用されている場合
                if [ -z "$proc_cmdline" ] ||
                   [[ "$proc_cmdline" != *openvpn* ]]; then

                    ret_code=1
                    break
                fi
            fi
        fi

        # 3. Authentication failure detection / 認証失敗の検知
        # Avoid -q with grep to prevent SIGPIPE in tail when pipefail is enabled
        # grep -q は pipefail 有効時に tail のSIGPIPEを誘発する可能性があるため、-qを使用せず /dev/null に捨てる。
        if [ -s "$log_file" ] &&
           tail -c 8192 "$log_file" 2>/dev/null |
           grep -a "AUTH_FAILED" >/dev/null 2>&1; then

            export AUTH_STATE=-1
            ret_code=2
            break
        fi

        echo -n "."
        sleep 1
    done

    echo ""

    # Cleanup operations on connection failure or abnormal exit
    # 接続失敗・異常終了時の共通後始末
    _phy_openvpn_kill
    _phy_tun_clear

    # Reset kill switch state safely / キルスイッチ状態を安全側へ戻す
    _phy_fw_killswitch "$s_ip" "$s_port" "$s_proto"

    echo "LOCKDOWN" > "$state_file" 2>/dev/null
    rm -f "$conn_file" "$pid_file" 2>/dev/null

    return "$ret_code"
}

# ==============================================================================
# General Utilities for 0-based Server Index (Master Index)
# 0スタートサーバー番号（マスターインデックス）関連の汎用ユーティリティ
# ==============================================================================

# ------------------------------------------------------------------------------
# Calculate 0-based master index from protocol type and internal protocol index
# プロトコル種別とプロトコル内番号から 0スタートマスターインデックス を算出
# Arguments / 引数: $1 = Protocol type ("u" or "t"), $2 = Protocol number (1~)
# Output / 出力: 0-based master index / 0スタートのマスターインデックス
# ------------------------------------------------------------------------------
get_master_index() {
    local p_type="$1"
    local p_num="$2"
    local udp_cnt="${FVPN_UDP_COUNT}"

    if [ "$p_type" = "u" ]; then
        echo $(( p_num - 1 ))
    elif [ "$p_type" = "t" ]; then
        echo $(( udp_cnt + p_num - 1 ))
    else
        echo "-1"
    fi
}

# ------------------------------------------------------------------------------
# Get 0-based master index from target server (TARGET_INDEX)
# 注目サーバー(TARGET_INDEX) から 0スタートマスターインデックス を取得
# Output / 出力: Master index (>= 0), Error: -1 / マスターインデックス (0 以上), エラー時 -1
# ------------------------------------------------------------------------------
get_target_master_index() {
    local target_idx="${TARGET_INDEX}"
    local total="${ACTIVE_TOTAL_COUNT}"

    if [ "$total" -le 0 ] || [ "$target_idx" -lt 0 ] || [ "$target_idx" -ge "$total" ]; then
        echo "-1"
        return 1
    fi

    # Extract 1 record (RECORD_BYTE_SIZE = 128 bytes)
    # 1レコード（RECORD_BYTE_SIZE = 128バイト）の切り出し
    local rec_size="${RECORD_BYTE_SIZE}"
    local offset=$(( target_idx * rec_size ))
    local rec="${ACTIVE_SERVERS_BUFFER:$offset:$rec_size}"

    # Extract fields based on constants / 定数に基づく切り出し
    local p_type="${rec:$OFFSET_PROTO:$LENGTH_PROTO}"
    local num_str="${rec:$OFFSET_INDEX:$LENGTH_INDEX}"
    num_str=$(echo "$num_str" | xargs) # Remove spaces / 空白除去

    # Delegate to master index calculation / マスターインデックスの算出へ委譲
    get_master_index "$p_type" "$num_str"
}

# ------------------------------------------------------------------------------
# Unified server rating update by master index
# マスターインデックス指定での評価一元変更処理
# Arguments / 引数: $1 = master_index, $2 = new_rating (0-4)
# ------------------------------------------------------------------------------
update_server_rating_by_master_index() {
    local m_idx="$1"
    local new_rate="$2"

    local total_cnt="${FVPN_TOTAL_COUNT}"
    if [ "$m_idx" -lt 0 ] || [ "$m_idx" -ge "$total_cnt" ]; then
        return 1
    fi
    if [[ ! "$new_rate" =~ ^[0-4]$ ]]; then
        return 1
    fi

    local record_size=${RECORD_BYTE_SIZE}
    local rate_off=${OFFSET_RATING}
    local target_off=$(( m_idx * record_size + rate_off ))

    # Pinpoint overwrite of rating value (1 character) in master buffer
    # マスターバッファの該当位置（評価値1文字）を直接ピンポイント書き換え
    MASTER_SERVERS_BUFFER="${MASTER_SERVERS_BUFFER:0:$target_off}${new_rate}${MASTER_SERVERS_BUFFER:$((target_off + 1))}"

    # Rebuild active server list / フィルター通過サーバー一覧の再構築
    build_active_servers
    sync_target_index_by_server

    return 0
}

# ==============================================================================
# VPN Connection Backend Function (Non-interactive execution without UI display)
# VPN接続バックエンド関数（画面表示を行わない非対話の接続処理）
# ==============================================================================

# ------------------------------------------------------------------------------
# Unified connection routing via 0-based master index (Single connection entry point)
# 0スタートマスターインデックス指定による一元接続関数（唯一の接続ルート）
# Arguments / 引数: $1 = master_index (0-based)
# Return / 戻り値: 0 = Success / 接続成功, -1 = Failed / 接続失敗
# ------------------------------------------------------------------------------
connect_by_master_index() {
    is_network_online || return -1

    local m_idx="$1"
    local record_size=${RECORD_BYTE_SIZE}

    local block="${MASTER_SERVERS_BUFFER:$(( m_idx * record_size )):$record_size}"
    [ ${#block} -lt $(( record_size - 8 )) ] && return -1

    local s_ip="${block:$OFFSET_IP:$LENGTH_IP}"
    local s_port="${block:$OFFSET_PORT:$LENGTH_PORT}"
    local p_type="${block:$OFFSET_PROTO:$LENGTH_PROTO}"
    local fname="${block:$OFFSET_FNAME}"

    s_ip="$(echo "$s_ip" | xargs)"
    s_port="$(echo "$s_port" | xargs)"
    p_type="$(echo "$p_type" | xargs)"
    fname="$(echo "$fname" | xargs)"

    # Explicit protocol type evaluation / プロトコル文字列の明示的判定
    local s_proto="udp"
    local target_server=""
    if [ "$p_type" = "t" ]; then
        s_proto="tcp"
        target_server="${FVPN_TCP_DIR:-${FVPN_HOME}/tcp_files}/${fname}"
    else
        s_proto="udp"
        target_server="${FVPN_UDP_DIR:-${FVPN_HOME}/udp_files}/${fname}"
    fi

    # Invoke physical layer connection / 物理層接続処理の呼び出し
    phy_connect "$target_server" "$s_ip" "$s_port" "$s_proto"
    local phy_ret=$?

    local status=0
    [ "$phy_ret" -ne 0 ] && status=-1

    # Automatic update for unrated servers (Default rate "2")
    # 評価値（未評価「2」）の自動更新
    local rate_off=${OFFSET_RATING}
    local target_off=$(( m_idx * record_size + rate_off ))
    local current_rate="${MASTER_SERVERS_BUFFER:$target_off:1}"

    if [ "$current_rate" -eq 2 ]; then
        local new_rate=3
        [ "$status" -ne 0 ] && new_rate=1
        update_server_rating_by_master_index "$m_idx" "$new_rate"
    fi

    return $status
}

# ==============================================================================
# Generate Active (Pass) Server Buffer
# アクティブ（PASS）サーバーバッファ生成
# ==============================================================================
build_active_servers() {
    local mode="${PROTOCOL_MODE}"
    local filter="${FILTER_LEVEL}"

    local buf_len=${#MASTER_SERVERS_BUFFER}
    local offset=0
    local pass_buf=""
    local u_pass=0 t_pass=0
    local rec_sz=${RECORD_BYTE_SIZE}

    while [ "$offset" -lt "$buf_len" ]; do
        local block="${MASTER_SERVERS_BUFFER:$offset:$rec_sz}"
        [ ${#block} -lt $(( rec_sz - 8 )) ] && break

        local p_type="${block:$OFFSET_PROTO:$LENGTH_PROTO}"
        local r_val="${block:$OFFSET_RATING:$LENGTH_RATING}"

        local p_match=0
        if [ "$mode" -gt 0 ] && [ "$p_type" = "u" ]; then
            p_match=1
        elif [ "$mode" -lt 0 ] && [ "$p_type" = "t" ]; then
            p_match=1
        elif [ "$mode" -eq 0 ]; then
            p_match=1
        fi

        local f_match=0
        if [[ "$r_val" =~ ^[0-5]$ ]] && [ "$r_val" -ge "$filter" ]; then
            f_match=1
        fi

        if [ "$p_match" -eq 1 ] && [ "$f_match" -eq 1 ]; then
            pass_buf+="$block"
            if [ "$p_type" = "u" ]; then
                ((u_pass++))
            elif [ "$p_type" = "t" ]; then
                ((t_pass++))
            fi
        fi

        offset=$(( offset + rec_sz ))
    done

    ACTIVE_SERVERS_BUFFER="$pass_buf"
    ACTIVE_UDP_COUNT=$u_pass
    ACTIVE_TCP_COUNT=$t_pass
    ACTIVE_TOTAL_COUNT=$(( u_pass + t_pass ))

    return 0
}

# ------------------------------------------------------------------------------
# get_master_server_info_line
# Retrieve server info line for specified 0-based master index from MASTER_SERVERS_BUFFER
# (Trim trailing spaces, no value validation).
# MASTER_SERVERS_BUFFER から指定された0スタートマスターインデックスのサーバー情報行を取得し、
# 末尾の空白をトリムして出力する (値検証なし)。
# ------------------------------------------------------------------------------
get_master_server_info_line() {
    local m_idx="$1"
    local line="${MASTER_SERVERS_BUFFER:$(( m_idx * RECORD_BYTE_SIZE )):$RECORD_BYTE_SIZE}"

    line="${line%$'\n'}"
    line="${line%"${line##*[^ ]}"}"

    printf "%s" "$line"
}

# ------------------------------------------------------------------------------
# get_server_info_line
# Extract 128-byte fixed length record for specified active index from ACTIVE_SERVERS_BUFFER
# フィルター通過後のサーバー情報（ACTIVE_SERVERS_BUFFER）から指定インデックスの128バイト固定長データを切り出し出力する。
# ------------------------------------------------------------------------------
get_server_info_line() {
    local line
    local target_idx="${1:-${TARGET_INDEX:--1}}"

    local offset=$((target_idx * RECORD_BYTE_SIZE))
    if (( target_idx >= 0 )); then
        line="${ACTIVE_SERVERS_BUFFER:$offset:RECORD_BYTE_SIZE}"
    else
        line="Unselected / 未選択"
    fi

    line="${line%$'\n'}"
    line="${line%"${line##*[^ ]}"}"

    printf "%s" "$line"
}

# Reset server ratings / サーバー評価リセット
reset_server_ratings() {
    local total_cnt="${FVPN_TOTAL_COUNT}"
    [ "$total_cnt" -le 0 ] && return 1

    local record_size=${RECORD_BYTE_SIZE}
    local rate_off=${OFFSET_RATING}
    local offset=0
    local new_buf=""

    local i
    for (( i=0; i<total_cnt; i++ )); do
        local rec="${MASTER_SERVERS_BUFFER:$offset:$record_size}"
        new_buf+="${rec:0:$rate_off}2${rec:$((rate_off + 1))}"
        offset=$((offset + record_size))
    done

    MASTER_SERVERS_BUFFER="$new_buf"
    FILTER_LEVEL=0
    build_active_servers
    sync_target_index_by_server

    return 0
}

# Save master servers buffer / マスターサーバーバッファの保存
save_master_servers_buffer() {
    # Zero-count guard: Never write to file if total count is 0 or less
    # 0件ガード: サーバー総数が0以下（未構築・取得失敗時）はファイル出力を絶対に行わない
    [ "${FVPN_TOTAL_COUNT:-0}" -le 0 ] && return 0

    local target_file="${FILE_MASTER_SERVERS}"
    LC_ALL=C printf "%s" "$MASTER_SERVERS_BUFFER" > "$target_file"
}

# ==============================================================================
# Target Server Name Management Utilities (TARGET_SERVER / TARGET_INDEX Sync)
# 注目サーバー名前管理ユーティリティ (TARGET_SERVER / TARGET_INDEX 同期)
# ==============================================================================

# ------------------------------------------------------------------------------
# update_target_server_by_index
# Extract "proto/filename" from TARGET_INDEX and set to TARGET_SERVER.
# TARGET_INDEX から「u/ファイル名」を抽出し TARGET_SERVER にセットする。
# ------------------------------------------------------------------------------
update_target_server_by_index() {
    [ "${TARGET_INDEX:--1}" -lt 0 ] && TARGET_SERVER="" && return 0

    # Extract fixed-width block from OFFSET_PROTO to end of line, then trim trailing spaces
    # OFFSET_PROTOの位置から行末までの固定幅を切り出し、末尾の空白をトリム
    TARGET_SERVER="${ACTIVE_SERVERS_BUFFER:$(( TARGET_INDEX * RECORD_BYTE_SIZE + OFFSET_PROTO )):$(( RECORD_BYTE_SIZE - OFFSET_PROTO ))}"
    TARGET_SERVER="$(echo "$TARGET_SERVER" | xargs)"
}

# ------------------------------------------------------------------------------
# sync_target_index_by_server
# Search TARGET_SERVER within ACTIVE_SERVERS_BUFFER and restore TARGET_INDEX.
# ACTIVE_SERVERS_BUFFER 内から TARGET_SERVER を検索し TARGET_INDEX を復元する。
# ------------------------------------------------------------------------------
sync_target_index_by_server() {
    [ -z "$TARGET_SERVER" ] && TARGET_INDEX=-1 && return 0

    # Retrieve line number (1-based) using TARGET_SERVER (e.g. u/australia-stream-udp.ovpn)
    # TARGET_SERVER（例: u/australia-stream-udp.ovpn）で行番号を取得 (1スタート)
    local line_num
    line_num=$(echo -n "$ACTIVE_SERVERS_BUFFER" | grep -F -n -m 1 "$TARGET_SERVER" | cut -d: -f1)

    if [ -n "$line_num" ]; then
        TARGET_INDEX=$(( line_num - 1 ))
    else
        TARGET_INDEX=-1
        TARGET_SERVER=""
    fi
}
