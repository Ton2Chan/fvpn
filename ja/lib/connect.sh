#!/bin/bash
# ==============================================================================
# FVPN - Connection Engine & Buffer Logic (Non-UI Core Operations)
# ==============================================================================

# トラップコード用、フィルタ通過サーバ一覧セーブ
# printf "%s" "$ACTIVE_SERVERS_BUFFER" > "${FILE_ACTIVE_SERVERS:-./data/.active_servers_fixed.txt}"

# ネットワーク疎通確認 (サイレント・ブール判定関数)
is_network_online() {
    ip route show default 2>/dev/null | grep -q "default via"
    return $?  # 0: ONLINE, 1: OFFLINE
}

# ==============================================================================
# 中間層トンネル関数 (純粋ブリッジ)
# ==============================================================================

phy_connect() {
    local target_path="$1"
    # 追加: 2〜4番目の引数（IP, Port, Proto）を受け取る
    local s_ip="$2"
    local s_port="$3"
    local s_proto="$4"

    local auth_file="${FVPN_DATA:-./data}/auth.conf"
    local state_file="${FVPN_DATA:-./data}/_phy_mode"
    local conn_file="${FVPN_DATA:-./data}/_phy_connected_server"
    local pid_file="${FVPN_DATA:-./data}/_fvpn.pid"
    local log_file="${FVPN_LOGDIR:-./logs}/openvpn.log"
    local timeout="${TIMEOUT_VPN_CONNECT:-30}"

    [ ! -f "$auth_file" ] && auth_file="./data/auth.conf"

    _phy_openvpn_kill
    _phy_tun_clear

    # 修正: 引数（$s_ip $s_port $s_proto）を正しく伝達
    _phy_fw_killswitch "$s_ip" "$s_port" "$s_proto"

    # 起動前に過去のログをクリア（誤検知防止）
    > "$log_file" 2>/dev/null

    # 修正: 引数（$s_ip $s_port $s_proto）を正しく伝達
    _phy_openvpn_start "$target_path" "$auth_file" "$s_ip" "$s_port" "$s_proto"
    if [ $? -ne 0 ]; then
        echo "LOCKDOWN" > "$state_file" 2>/dev/null
        rm -f "$conn_file" "$pid_file" 2>/dev/null
        return 1
    fi

    local i
    local ret_code=1  # デフォルトはタイムアウト/一般接続失敗(1)

    for (( i=1; i<=timeout; i++ )); do
        # 1. 接続成功のチェック
        if _phy_tun_check; then
            echo "CONNECTED" > "$state_file" 2>/dev/null
            echo "$target_path" > "$conn_file" 2>/dev/null
            
            # ★ 接続成功：VPN用DNS(10.8.8.8)の適用 & 生IP用DNSのバックアップ保存
            _phy_dns_apply

            export AUTH_STATE=1
            return 0
        fi

        # 2. ログから認証失敗 (AUTH_FAILED) をリアルタイム検知
        if [ -f "$log_file" ] && grep -q "AUTH_FAILED" "$log_file"; then
            export AUTH_STATE=-1
            ret_code=2  # 拡張エラーコード：認証失敗(2)
            break
        fi

        echo -n "."
        sleep 1
    done

    echo ""
    _phy_openvpn_kill
    _phy_tun_clear
    _phy_fw_killswitch
    echo "LOCKDOWN" > "$state_file" 2>/dev/null
    rm -f "$conn_file" "$pid_file" 2>/dev/null

    return $ret_code
}

# ==============================================================================
# 0スタートサーバー番号（マスターインデックス）関連の汎用ユーティリティ
# ==============================================================================

# ------------------------------------------------------------------------------
# プロトコル種別とプロトコル内番号から 0スタートマスターインデックス を算出
# 引数: $1 = プロトコル種別 ("u" or "t"), $2 = プロトコル内番号 (1〜)
# 出力: 0スタートのマスターインデックス
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
# 注目サーバー(TARGET_INDEX) から 0スタートマスターインデックス を取得
# 出力: マスターインデックス (0 以上), エラー時 -1
# ------------------------------------------------------------------------------
get_target_master_index() {
    local target_idx="${TARGET_INDEX}"
    local total="${ACTIVE_TOTAL_COUNT}"

    if [ "$total" -le 0 ] || [ "$target_idx" -lt 0 ] || [ "$target_idx" -ge "$total" ]; then
        echo "-1"
        return 1
    fi

    # 1レコード（RECORD_BYTE_SIZE = 128バイト）の切り出し
    local rec_size="${RECORD_BYTE_SIZE}"
    local offset=$(( target_idx * rec_size ))
    local rec="${ACTIVE_SERVERS_BUFFER:$offset:$rec_size}"

    # 定数に基づく切り出し
    local p_type="${rec:$OFFSET_PROTO:$LENGTH_PROTO}"
    local num_str="${rec:$OFFSET_INDEX:$LENGTH_INDEX}"
    num_str=$(echo "$num_str" | xargs) # 空白除去

    # マスターインデックスの算出へ委譲
    get_master_index "$p_type" "$num_str"
}

# ------------------------------------------------------------------------------
# マスターインデックス指定での評価一元変更処理
# 引数: $1 = master_index, $2 = new_rating (0-4)
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

    # マスターバッファの該当位置（評価値1文字）を直接ピンポイント書き換え
    MASTER_SERVERS_BUFFER="${MASTER_SERVERS_BUFFER:0:$target_off}${new_rate}${MASTER_SERVERS_BUFFER:$((target_off + 1))}"

    # フィルター通過サーバー一覧の再構築
    build_active_servers
    sync_target_index_by_server

    return 0
}

# ==============================================================================
# VPN接続バックエンド関数（画面表示を行わない非対話の接続処理）
# ==============================================================================

# ------------------------------------------------------------------------------
# 0スタートマスターインデックス指定による一元接続関数（唯一の接続ルート）
# 引数: $1 = master_index (0スタート)
# 戻り値: 0 = 接続成功 / -1 = 接続失敗
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

    # プロトコル文字列の明示的判定
    local s_proto="udp"
    local target_server=""
    if [ "$p_type" = "t" ]; then
        s_proto="tcp"
        target_server="${FVPN_TCP_DIR:-./tcp_files}/${fname}"
    else
        s_proto="udp"
        target_server="${FVPN_UDP_DIR:-./udp_files}/${fname}"
    fi

    # 物理層接続処理の呼び出し
    phy_connect "$target_server" "$s_ip" "$s_port" "$s_proto"
    local phy_ret=$?

    local status=0
    [ "$phy_ret" -ne 0 ] && status=-1

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
# 機能: MASTER_SERVERS_BUFFER から指定された0スタートマスターインデックスの
#       サーバー情報行を取得し、末尾の空白をトリムして出力する (値検証なし)。
# ------------------------------------------------------------------------------
get_master_server_info_line() {
    local m_idx="$1"
    local line="${MASTER_SERVERS_BUFFER:$(( m_idx * RECORD_BYTE_SIZE )):$RECORD_BYTE_SIZE}"

    line="${line%$'\n'}"
    line="${line%"${line##*[^ ]}"}"

    printf "%s" "$line"
}

# フィルター通過後のサーバー情報（ACTIVE_SERVERS_BUFFER）から、指定されたインデックス（行番号）のサーバー情報（128バイトの固定長データ）を切り出し、末尾の余計な改行や空白を除去して出力する関数です。  
get_server_info_line() {
    local line
    local target_idx="${1:-${TARGET_INDEX:--1}}"

    local offset=$((target_idx * RECORD_BYTE_SIZE))
    if (( target_idx >= 0 )); then
        line="${ACTIVE_SERVERS_BUFFER:$offset:RECORD_BYTE_SIZE}"
    else
        line="未選択"
    fi

    line="${line%$'\n'}"
    line="${line%"${line##*[^ ]}"}"

    printf "%s" "$line"
}

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

save_master_servers_buffer() {
    # 0件ガード: サーバー総数が0以下（未構築・取得失敗時）はファイル出力を絶対に行わない
    [ "${FVPN_TOTAL_COUNT:-0}" -le 0 ] && return 0

    local target_file="${FILE_MASTER_SERVERS}"
    LC_ALL=C printf "%s" "$MASTER_SERVERS_BUFFER" > "$target_file"
}

# ==============================================================================
# 注目サーバー名前管理ユーティリティ (TARGET_SERVER / TARGET_INDEX 同期)
# ==============================================================================

# ------------------------------------------------------------------------------
# update_target_server_by_index
# 機能: TARGET_INDEX から「u/ファイル名」を抽出し TARGET_SERVER にセットする。
# ------------------------------------------------------------------------------
update_target_server_by_index() {
    [ "${TARGET_INDEX:--1}" -lt 0 ] && TARGET_SERVER="" && return 0

    # OFFSET_PROTOの位置から行末までの固定幅を切り出し、末尾の空白をトリム
    TARGET_SERVER="${ACTIVE_SERVERS_BUFFER:$(( TARGET_INDEX * RECORD_BYTE_SIZE + OFFSET_PROTO )):$(( RECORD_BYTE_SIZE - OFFSET_PROTO ))}"
    TARGET_SERVER="$(echo "$TARGET_SERVER" | xargs)"
}

# ------------------------------------------------------------------------------
# sync_target_index_by_server
# 機能: ACTIVE_SERVERS_BUFFER 内から TARGET_SERVER を検索し TARGET_INDEX を復元する。
# ------------------------------------------------------------------------------
sync_target_index_by_server() {
    [ -z "$TARGET_SERVER" ] && TARGET_INDEX=-1 && return 0

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
