#!/bin/bash
# ==============================================================================
# FVPN - Menu & User Interaction Module (UI & Interaction Layer)
# ==============================================================================

# ------------------------------------------------------------------------------
# Menu footer status display
# メニューフッター情報表示
# ------------------------------------------------------------------------------
show_status_header() {
    local phy_mode
    phy_mode=$(get_phy_mode)

    local m_tag="fix"
    case "${CONNECT_MODE}" in
        2|"2"|"SEQ")    m_tag="seq" ;;
        3|"3"|"RANDOM") m_tag="rnd" ;;
        1|"1"|"FIXED"|*) m_tag="fix" ;;
    esac

    # Fixed-width header display following the 123456 alignment rule
    # 123456ルールに基づく桁完全固定表示
    local fix_str=" $m_tag "
    local lock_str=" lock "
    local state_str=" off "

    case "$phy_mode" in
        "CONNECTED")
            fix_str="[$m_tag]"
            ;;
        "LOCKDOWN")
            lock_str="[lock]"
            ;;
        "DISCONNECTED"|*)
            state_str="[off]"
            ;;
    esac

# Determine authentication status
# 認証ステータス判定
local auth_status="${MSG["msg_show_status_header_auth_prefix"]}[--]"
local state="${AUTH_STATE:-0}"

if [ "$state" -gt 0 ]; then
    # Positive values: authentication OK (1, 2, ...)
    # 正の数: 認証OK (1, 2, ...)
    auth_status="${MSG["msg_show_status_header_auth_prefix"]}[OK]"
elif [ "$state" -lt 0 ]; then
    # Negative values: authentication failed (-1, -2, ...)
    # 負の数: 認証NG (-1, -2, ...)
    auth_status="${MSG["msg_show_status_header_auth_prefix"]}[NG]"
else
    # 0: not checked / initial state
    # 0: 未確認 / 初期状態
    auth_status="${MSG["msg_show_status_header_auth_prefix"]}[--]"
fi

    # Output the first header section (VPN  fix  lock [off] auth status)
    # 前半ヘッダー出力 (VPN  fix  lock [off] 認証:[NG] )
    printf "VPN %s%s%s %s" "$fix_str" "$lock_str" "$state_str" "$auth_status"
    echo ""

    # Output the second section (generic one-line server display: show the target server without arguments)
    # 後半部（汎用1行サーバー表示：引数なしで注目サーバーを出力）
    get_server_info_line

    echo ""
    echo "-------------------------------------------"
}

# ==============================================================================
# Connection processing with user messages (UI-integrated function)
# メッセージ表示付き接続処理 (UI要素を含む関数)
# ==============================================================================

# ------------------------------------------------------------------------------
# Master-index connection wrapper with result messages
# メッセージ表示付きマスターインデックス接続関数
# Argument: $1 = zero-based master index
# 引数: $1 = 0スタートのマスターインデックス
# Return: 0 success / non-zero failure
# 戻値: 0:成功 / 0以外:失敗
# ------------------------------------------------------------------------------
connect_by_master_index_wm() {
    local m_idx="$1"

    # Call the intermediate-layer connection function (delegate all processing)
    # 中間層接続関数の呼び出し（処理はすべて移譲）
    connect_by_master_index "$m_idx"
    local res=$?

    # Display the connection result message
    # --- 接続結果メッセージ表示 ---
    echo ""
    if [ "$res" -eq 0 ]; then
        echo "${MSG["msg_connect_by_master_index_wm_success"]}"
    else
        echo "${MSG["msg_connect_by_master_index_wm_fail"]}"
        echo "${MSG["msg_connect_by_master_index_wm_lockdown"]}"
    fi

    return $res
}

# ------------------------------------------------------------------------------
# 1) VPN disconnect processing (single, fixed sequence: menu item 2 command)
# 1) VPN切断処理 (単一・確定シーケンス : メニュー2のコマンド)
# ------------------------------------------------------------------------------
disconnect_vpn() {
    echo "${MSG["msg_disconnect_vpn_executing"]}"

    # Call the physical-layer disconnect and verification sequence
    # 物理層の切断・検証処理を一本道で呼び出し
    if phy_disconnect; then
        # On successful disconnect, confirm cleanup through the intermediate layer
        # 切断成功時、念のため中間層経由でクリーンアップを確定呼び出し
        phy_cleanup_if_disconnected
        echo "${MSG["msg_disconnect_vpn_restored"]}"
        return 0
    else
        echo "${MSG["msg_disconnect_vpn_failed"]}"
        return 1
    fi
}

# ------------------------------------------------------------------------------
# 2) Pre-exit phase control (confirmation dialog & VPN disconnect)
# 2) アプリ終了前フェーズ制御 (確認ダイアログ & VPN切断)
# ------------------------------------------------------------------------------
exit_fvpn() {
    local current_mode
    current_mode=$(get_phy_mode)

    # Show a confirmation dialog only while connected or protected by LOCKDOWN
    # 接続中、または保護ロック中(LOCKDOWN)の場合のみダイアログで確認
    if [ "$current_mode" != "DISCONNECTED" ]; then
        echo ""
        echo "${MSG["msg_exit_fvpn_warn"]}"
        read -rp "${MSG["msg_exit_fvpn_confirm"]}" ans

        case "$ans" in
            [yY]|[yY][eE][sS])
                disconnect_vpn
                ;;
            *)
                echo "${MSG["msg_exit_fvpn_keep_lock"]}"
                ;;
        esac
    else
        # Perform cleanup as a precaution when disconnected
        # 未接続状態の場合の念のためクリーンアップ
        phy_cleanup_if_disconnected
    fi
}

# ==============================================================================
# Quick-connect settings UI and submenu functions
# 簡易接続設定 UI・サブメニュー関数
# ==============================================================================

# 1) Connection mode change processing
# 1) 接続モード変更処理
configure_connect_mode() {
    local m_opt
    echo
    echo "${MSG["msg_configure_connect_mode_opt1"]}"
    echo "${MSG["msg_configure_connect_mode_opt2"]}"
    echo "${MSG["msg_configure_connect_mode_opt3"]}"
    read -rp "${MSG["msg_configure_connect_mode_prompt"]}" m_opt
    case "$m_opt" in
        1|2|3)
            CONNECT_MODE="$m_opt"
            ;;
    esac
}

# 2) Protocol mode change processing
# 2) プロトコル変更処理
configure_protocol_mode() {
    local p_opt
    echo
    echo "${MSG["msg_configure_protocol_mode_opt1"]}"
    echo "${MSG["msg_configure_protocol_mode_opt2"]}"
    echo "${MSG["msg_configure_protocol_mode_opt3"]}"
    read -rp "${MSG["msg_configure_protocol_mode_prompt"]}" p_opt
    case "$p_opt" in
        1) set_protocol_mode 1 ;;
        2) set_protocol_mode -1 ;;
        3) set_protocol_mode 0 ;;
        *) return ;;
    esac

    # Rebuild the active server list after filtering
    # フィルター通過サーバー一覧の再構築
    build_active_servers
    sync_target_index_by_server
}

# 3) Filter level change processing
# 3) フィルタレベル変更処理
configure_filter_level() {
    local f_val
    echo
    printf '%b\n' "${MSG["msg_configure_filter_level_menu"]}"
    read -rp "${MSG["msg_configure_filter_level_prompt"]}" f_val
    if [ -n "$f_val" ] && [[ "$f_val" =~ ^[0-4]$ ]]; then
        FILTER_LEVEL="$f_val"
        build_active_servers
        sync_target_index_by_server
    fi
}

# Main server-information update routine
# サーバー情報の更新 本体
update_servers() {
    local mode="${1:-force}"
    local base_dir="${FVPN_HOME:-.}"
    local data_dir="${FVPN_DATA:-${base_dir}/data}"
    local work_zip="${data_dir}/fastestvpn_ovpn.zip"

    local dl_dir
    dl_dir=$(get_download_dir)
    local local_zip="${dl_dir}/fastestvpn_ovpn.zip"
    local local_bak="${dl_dir}/fastestvpn_ovpn.zip.bak"

    # 1. When a manually placed local ZIP is present (determined only by the startup flag)
    # 1. ローカルに直接手動配置された zip がある場合 (起動時のフラグのみで判定)
    if [ "$HAS_UPDATE_ZIP" -eq 1 ]; then
        mkdir -p "$data_dir"
        cp -f "$local_zip" "$work_zip"
        mv -f "$local_zip" "$local_bak"
        HAS_UPDATE_ZIP=0  # 処理完了のためフラグをクリア
    else
        # 2. Determine the network-download path
        # 2. ネット経由ダウンロード時の判定
        # Skip automatic update when the LAN is offline (non-zero) or the system is in LOCKDOWN
        # LAN切断(0以外) または ロックダウン中(LOCKDOWN) なら自動更新をスキップ
        if ! is_network_online || [ "$(get_phy_mode)" = "LOCKDOWN" ]; then
            echo "${MSG["msg_update_servers_net_error"]}"
            return 1
        fi

        if [ "$mode" = "skip" ]; then
            CURRENT_TIMEOUT="${TIMEOUT_AUTO_UPDATE}"
            if ! should_check_update; then
                return 0
            fi
        else
            CURRENT_TIMEOUT="${TIMEOUT_MANUAL_UPDATE}"
        fi

        local target_url="${CUSTOM_UPDATE_URL:-$OFFICIAL_UPDATE_URL}"

        if ! download_url_to_work_zip "$target_url" "$work_zip"; then
            echo "${MSG["msg_update_servers_dl_fail"]}"
            return 1
        fi
    fi

    if ! apply_work_zip_package; then
        echo "${MSG["msg_update_servers_apply_fail"]}"
        return 1
    fi

    local default_mark="${MARK_ADDED:-+}"
    if [ "${FVPN_TOTAL_COUNT}" -eq 0 ]; then
        default_mark="${MARK_NORMAL:-_}"
    fi

    build_master_servers "$default_mark"

    echo "${MSG["msg_update_servers_success"]}"
    return 0
}

# ==============================================================================
# Export rating data (all records, fixed-format output)
# 評価データのエクスポート（全件・固定フォーマット出力）
# ==============================================================================
export_server_ratings() {
    local target_dir
    target_dir=$(get_download_dir)

    if [ ! -d "$target_dir" ]; then
        mkdir -p "$target_dir" 2>/dev/null || {
            printf '%s\n' "$(printf "${MSG["msg_export_server_ratings_dir_error"]}" "$target_dir")"
            return 1
        }
    fi

    if [ -z "$MASTER_SERVERS_BUFFER" ]; then
        echo "${MSG["msg_export_server_ratings_no_data"]}"
        return 1
    fi

    local export_file="${target_dir}/${FILE_RATINGS_EXPORT_NAME:-fvpn_ratings.txt}"
    local tmp_file
    tmp_file=$(mktemp)

    local buf_len=${#MASTER_SERVERS_BUFFER}
    local offset=0
    local exported_count=0

    while [ "$offset" -lt "$buf_len" ]; do
        local rec="${MASTER_SERVERS_BUFFER:$offset:RECORD_BYTE_SIZE}"
        [ ${#rec} -lt 120 ] && break

        # Get the 128-byte record after removing the trailing newline
        # 末尾の改行を取り除いた128バイト行を取得
        local line="${rec%$'\n'}"
        # Remove trailing spaces from the record
        # 行末の余剰スペースを除去
        line="${line%"${line##*[![:space:]]}"}"

        if [ -n "$line" ]; then
            printf "%s\n" "$line" >> "$tmp_file"
            ((exported_count++))
        fi

        offset=$((offset + RECORD_BYTE_SIZE))
    done

    if [ "$exported_count" -gt 0 ]; then
        mv "$tmp_file" "$export_file"
        printf '%s\n' "$(printf "${MSG["msg_export_server_ratings_success"]}" "$exported_count")"
        printf '%s\n' "$(printf "${MSG["msg_export_server_ratings_out_path"]}" "$export_file")"
    else
        rm -f "$tmp_file"
        echo "${MSG["msg_export_server_ratings_no_target"]}"
    fi

    return 0
}

# ==============================================================================
# Import rating data (direct in-memory replacement using constants)
# 評価データのインポート（メモリ直接置換・定数利用版）
# ==============================================================================
import_server_ratings() {
    local target_dir
    target_dir=$(get_download_dir)

    local import_file="${target_dir}/${FILE_RATINGS_EXPORT_NAME:-fvpn_ratings.txt}"

    if [ ! -f "$import_file" ]; then
        echo "${MSG["msg_import_server_ratings_no_file"]}"
        printf '%s\n' "$(printf "${MSG["msg_import_server_ratings_check_path"]}" "$import_file")"
        return 1
    fi

    if [ -z "$MASTER_SERVERS_BUFFER" ]; then
        build_master_servers
    fi

    echo "${MSG["msg_import_server_ratings_executing"]}"

    # 1. Load the import file into an associative array in one pass (O(N))
    # 1. インポートファイルを連想配列に一括取り込み (O(N))
    declare -A import_map
    local loaded_count=0
    local line

    while IFS= read -r line || [ -n "$line" ]; do
        [ ${#line} -lt 14 ] && continue

        # Extract fields using constants from config.sh
        # config.sh の定数で切り出し
        local p_type="${line:${OFFSET_PROTO}:${LENGTH_PROTO}}"
        local r_val="${line:${OFFSET_RATING}:${LENGTH_RATING}}"
        local fn="${line:${OFFSET_FNAME}}"
        fn=$(echo "$fn" | xargs)

        if [[ "$p_type" =~ ^[ut]$ ]] && [[ "$r_val" =~ ^[0-4]$ ]] && [ -n "$fn" ]; then
            import_map["${p_type}_${fn}"]="$r_val"
            ((loaded_count++))
        fi
    done < "$import_file"

    if [ "$loaded_count" -eq 0 ]; then
        echo "${MSG["msg_import_server_ratings_no_valid_data"]}"
        return 1
    fi

    # 2. Update rating values directly at exact positions in MASTER_SERVERS_BUFFER
    # 2. MASTER_SERVERS_BUFFER 内の評価値をピンポイントで直接書き換え
    local rec_size=${RECORD_BYTE_SIZE}
    local buf_len=${#MASTER_SERVERS_BUFFER}
    local offset=0
    local updated_count=0

    while [ "$offset" -lt "$buf_len" ]; do
        local rec="${MASTER_SERVERS_BUFFER:$offset:$rec_size}"
        [ ${#rec} -lt 120 ] && break

        local p_type="${rec:${OFFSET_PROTO}:${LENGTH_PROTO}}"
        local fn="${rec:${OFFSET_FNAME}}"
        fn=$(echo "$fn" | xargs)

        local key="${p_type}_${fn}"

        # Check whether a change target exists
        # 変更対象が存在するか確認
        if [ -n "${import_map[$key]+exists}" ]; then
            local new_r="${import_map[$key]}"
            local current_r="${rec:${OFFSET_RATING}:${LENGTH_RATING}}"

            # Perform in-place replacement only when the value differs
            # 現在の評価値と異なる場合のみインプレース置換
            if [ "$current_r" != "$new_r" ]; then
                local target_idx=$((offset + ${OFFSET_RATING}))
                
                # Rewrite only the rating byte in the buffer (avoid rebuilding and re-concatenating the entire string)
                # バッファの 10バイト目のみを書き換え（全体文字列の再構築・再連結を回避）
                MASTER_SERVERS_BUFFER="${MASTER_SERVERS_BUFFER:0:$target_idx}${new_r}${MASTER_SERVERS_BUFFER:$((target_idx + 1))}"
                ((updated_count++))
            fi
        fi

        offset=$((offset + rec_size))
    done

    # 3. Save and activate only when changes occurred
    # 3. 変更があった場合のみ保存と有効化処理を実行
    if [ "$updated_count" -gt 0 ]; then
        build_active_servers
        sync_target_index_by_server
        printf '%s\n' "$(printf "${MSG["msg_import_server_ratings_success"]}" "$updated_count")"
    else
        echo "${MSG["msg_import_server_ratings_no_change"]}"
    fi

    return 0
}

# ==============================================================================
# Quick-connect logic calculation
# 簡易接続 ロジック計算処理
# ==============================================================================

# Main quick-VPN connection routine
# 簡易VPN接続 本体
quick_connect() {
    local N="${ACTIVE_TOTAL_COUNT}"

    if [ "$N" -le 0 ]; then
        echo "${MSG["msg_quick_connect_no_active_servers"]}"
        return 1
    fi

    # Calculate TARGET_INDEX in memory according to the selected mode
    # モードに応じた TARGET_INDEX のインメモリ演算
    case "${CONNECT_MODE}" in
        2) # SEQ (順番)
            TARGET_INDEX=$(( (TARGET_INDEX + 1) % N ))
            ;;
        3) # RANDOM (ランダム)
            local r=$(( RANDOM % N ))
            [ "$r" -eq "$TARGET_INDEX" ] && r=$(( (r + 1) % N ))
            TARGET_INDEX="$r"
            ;;
        1|*) # FIXED (固定)
            (( TARGET_INDEX < 0 )) && TARGET_INDEX=0
            ;;
    esac
    update_target_server_by_index

    # Get the zero-based master index from the finalized TARGET_INDEX
    # 確定した TARGET_INDEX からマスターインデックス（0スタート）を取得
    local m_idx
    m_idx=$(get_target_master_index)

    # Display the selected server
    # 選択サーバーの表示
    local display_info
    display_info=$(get_server_info_line "$TARGET_INDEX")
    echo "${display_info}"

    # Execute VPN connection through the UI-integrated wrapper with messages
    # VPN接続実行（メッセージ表示を行うUI統合接続関数へ）
    connect_by_master_index_wm "$m_idx"
    return $?
}

# Main quick-connect settings submenu
# 簡易接続設定 メインサブメニュー
show_quick_connect_settings() {
    while true; do
        local mode_disp proto_disp filter_disp

        # 1) Display connection mode (1 fixed / 2 sequential / 3 random)
        # 1) 接続モード表示 (1: 固定 / 2: 順番 / 3: ランダム)
        case "${CONNECT_MODE}" in
            1) mode_disp="${MSG["msg_show_quick_connect_settings_mode_fixed"]}" ;;
            2) mode_disp="${MSG["msg_show_quick_connect_settings_mode_seq"]}" ;;
            3) mode_disp="${MSG["msg_show_quick_connect_settings_mode_random"]}" ;;
            *) mode_disp="${MSG["msg_show_quick_connect_settings_mode_fixed"]}" ;;
        esac

        # 2) Display protocol mode (positive: UDP / negative: TCP / 0: mix)
        # 2) プロトコル表示 (正の数: UDP / 負の数: TCP / 0: mix)
        local p="${PROTOCOL_MODE}"
        if (( p > 0 )); then
            proto_disp="[1:UDP]  2:TCP  3:mix"
        elif (( p < 0 )); then
            proto_disp="1:UDP  [2:TCP]  3:mix"
        else
            proto_disp="1:UDP  2:TCP  [3:mix]"
        fi

        # 3) Display filter level
        # 3) フィルタレベル表示
        case "${FILTER_LEVEL}" in
            4) filter_disp="[4] 3  2  1  0" ;;
            3) filter_disp="[4  3] 2  1  0" ;;
            2) filter_disp="[4  3  2] 1  0" ;;
            1) filter_disp="[4  3  2  1] 0" ;;
            0) filter_disp="[4  3  2  1  0]" ;;
            *) filter_disp="[4  3  2] 1  0" ;;
        esac

        echo
        printf '%s\n' "$(printf "${MSG["msg_show_quick_connect_settings_menu"]}" "$mode_disp" "$proto_disp" "$filter_disp")"
        read -rp "${MSG["msg_show_quick_connect_settings_prompt"]}" q_choice
        q_choice="${q_choice:-0}"

        case "$q_choice" in
            1) configure_connect_mode ;;
            2) configure_protocol_mode ;;
            3) configure_filter_level ;;
            0) break ;;
            *) echo "${MSG["msg_show_quick_connect_settings_invalid"]}" ;;
        esac
    done
}

# ==============================================================================
# Server management, rating UI, and submenu functions
# サーバー管理・評価 UI・サブメニュー関数
# ==============================================================================

reset_ratings_menu() {
    echo ""
    read -rp "${MSG["msg_reset_ratings_menu_confirm"]}" confirm
    case "$confirm" in
        [yY]|[yY][eE][sS])
            if reset_server_ratings; then
                echo "${MSG["msg_reset_ratings_menu_success"]}"
            fi
            ;;
        *)
            echo "${MSG["msg_reset_ratings_menu_canceled"]}"
            ;;
    esac
}

# ------------------------------------------------------------------------------
# Individual server-rating dialog (UI layer)
# 個別サーバー評価の設定ダイアログ（UI層）
# ------------------------------------------------------------------------------
manage_protocol_servers() {
    local target_proto="$1" # "u" または "t"
    local proto_label="UDP"
    [ "$target_proto" = "t" ] && proto_label="TCP"

    local record_size=${RECORD_BYTE_SIZE}
    local udp_cnt="${FVPN_UDP_COUNT}"
    local tcp_cnt="${FVPN_TCP_COUNT}"

    local max_num=$udp_cnt
    if [ "$target_proto" = "t" ]; then
        max_num=$tcp_cnt
    fi

    [ "$max_num" -le 0 ] && { printf '%s\n' "$(printf "${MSG["msg_manage_protocol_servers_no_servers"]}" "$proto_label")"; return 0; }

    # 1. Show the server list only on the first pass
    # 1. 最初の一回のみ一覧表を表示
    echo ""
    printf '%s\n' "$(printf "${MSG["msg_manage_protocol_servers_list_header"]}" "$proto_label")"
    
    local base_index
    base_index=$(get_master_index "$target_proto" 1)
    local start_byte=$(( base_index * record_size ))
    local total_bytes=$(( max_num * record_size ))
    local sub_buf="${MASTER_SERVERS_BUFFER:$start_byte:$total_bytes}"

    # Remove trailing spaces and display the list in one batch
    # 行末空白を除去して一括表示
    printf '%s' "$sub_buf" | sed 's/[[:space:]]*$//'

    echo "=================================================="
    echo "${MSG["msg_manage_protocol_servers_legend"]}"
    echo "--------------------------------------------------"

    # 2. Input loop for rating changes
    # 2. 評価変更の受付ループ
    while true; do
        read -rp "${MSG["msg_manage_protocol_servers_select_prompt"]}" num_input

        [ -z "$num_input" ] || [ "$num_input" = "0" ] && break

        # Range check
        # 範囲チェック
        if [[ ! "$num_input" =~ ^[1-9][0-9]*$ ]] || [ "$num_input" -gt "$max_num" ]; then
            printf '%s\n' "$(printf "${MSG["msg_manage_protocol_servers_out_of_range"]}" "$max_num")"
            continue
        fi

        # Calculate the master index from the zero-based number
        # 0スタート番号からマスターインデックスを算出
        local target_master_idx
        target_master_idx=$(get_master_index "$target_proto" "$num_input")

        echo "$(get_master_server_info_line "$target_master_idx")"
        read -rp "${MSG["msg_manage_protocol_servers_val_prompt"]}" new_rate
        if [[ ! "$new_rate" =~ ^[0-4]$ ]]; then
            echo "${MSG["msg_manage_protocol_servers_invalid_val"]}"
            continue
        fi

        # Update the rating and display only the affected record
        # 評価を更新して該当行のみを出力表示
        update_server_rating_by_master_index "$target_master_idx" "$new_rate"
        echo "$(get_master_server_info_line "$target_master_idx")"
        echo ""
    done
}

# ------------------------------------------------------------------------------
# Main individual-server connection routine
# サーバー個別指定接続機能 本体
# ------------------------------------------------------------------------------
select_vpn_server() {
    local target_proto=""

    # --- 1. Protocol selection loop ---
    # --- 1. プロトコル選択ループ ---
    while true; do
        printf '%b\n' "${MSG["msg_select_vpn_server_title"]}"
        printf '%b\n' "${MSG["msg_select_vpn_server_opts"]}"
        read -rp "${MSG["msg_select_vpn_server_proto_prompt"]}" p_choice

        case "$p_choice" in
            1) target_proto="u"; break ;;
            2) target_proto="t"; break ;;
            0|"") echo "${MSG["msg_reset_ratings_menu_canceled"]}"; return 0 ;;
            *) echo "${MSG["msg_select_vpn_server_invalid_proto"]}" ;;
        esac
    done

    # --- 2. Check target count ---
    # --- 2. 対象件数の確認 ---
    local target_count=0
    if [ "$target_proto" = "u" ]; then
        target_count="${ACTIVE_UDP_COUNT}"
    else
        target_count="${ACTIVE_TCP_COUNT}"
    fi

    if [ "$target_count" -le 0 ]; then
        printf '%s\n' "$(printf "${MSG["msg_select_vpn_server_no_servers"]}" "${target_proto^^}")"
        return 0
    fi

    # --- 3. Display only the selected protocol region ---
    # --- 3. 該当プロトコル領域のみをスライス表示 ---
    echo ""
    printf '%s\n' "$(printf "${MSG["msg_select_vpn_server_list_header"]}" "${target_proto^^}" "$target_count")"

    local start_offset=0
    [ "$target_proto" = "t" ] && start_offset=$(( ${ACTIVE_UDP_COUNT} * RECORD_BYTE_SIZE ))
    local total_bytes=$(( target_count * RECORD_BYTE_SIZE ))

    local sub_buf="${ACTIVE_SERVERS_BUFFER:$start_offset:$total_bytes}"
    printf '%s\n' "$sub_buf" | sed 's/[[:space:]]*$//'

    # --- 4. Server-number input and retry loop ---
    # --- 4. サーバー番号入力 ＆ 再入力ループ ---
    local match_target_index=-1
    local target_master_idx=-1
    local s_num=""

    while true; do
        read -rp "${MSG["msg_select_vpn_server_num_prompt"]}" s_num

        # Cancel (0 or empty input)
        # キャンセル（0または未入力）
        if [ -z "$s_num" ] || [ "$s_num" -eq 0 ] 2>/dev/null; then
            echo "${MSG["msg_reset_ratings_menu_canceled"]}"
            return 0
        fi

        # Numeric validation
        # 数値チェック
        if ! [[ "$s_num" =~ ^[1-9][0-9]*$ ]]; then
            echo "${MSG["msg_select_vpn_server_invalid_num"]}"
            continue
        fi

        # Search the target server in the active buffer
        # PASSバッファから該当サーバーを検索
        match_target_index=-1
        target_master_idx=-1
        local i=0

        while [ "$i" -lt "$target_count" ]; do
            local current_offset=$(( start_offset + (i * RECORD_BYTE_SIZE) ))
            local rec="${ACTIVE_SERVERS_BUFFER:$current_offset:RECORD_BYTE_SIZE}"

            # Extract the protocol-local number from the server record (OFFSET_INDEX:LENGTH_INDEX)
            # サーバー行からプロトコル内連番（OFFSET_INDEX:LENGTH_INDEX）を抽出
            local num_str="${rec:$OFFSET_INDEX:$LENGTH_INDEX}"
            num_str=$(echo "$num_str" | xargs)

            if [ "$num_str" -eq "$s_num" ] 2>/dev/null; then
                if [ "$target_proto" = "u" ]; then
                    match_target_index="$i"
                else
                    match_target_index=$(( ${ACTIVE_UDP_COUNT} + i ))
                fi

                local p_type="${rec:$OFFSET_PROTO:$LENGTH_PROTO}"
                target_master_idx=$(get_master_index "$p_type" "$num_str")
                break
            fi
            ((i++))
        done

        # Existence check: leave the loop and connect when found
        # 存在チェック: 見つかった場合はループを抜けて接続へ
        if [ "$target_master_idx" -ge 0 ]; then
            break
        fi

        # If not found, show a warning and request input again
        # 見つからなかった場合は警告を出して再入力
        printf '%s\n' "$(printf "${MSG["msg_select_vpn_server_not_found"]}" "$s_num" "${target_proto^^}")"
    done

    # Update the target server
    # 注目サーバーの更新
    TARGET_INDEX="$match_target_index"
    update_target_server_by_index

    # --- 5. Execute the connection through the unified function ---
    # --- 5. 一元接続関数による接続実行 ---
    get_server_info_line
    echo ""
    connect_by_master_index_wm "$target_master_idx"
    return $?
}

# ------------------------------------------------------------------------------
# Main server-management and rating submenu
# サーバー管理・評価 サブメニュー本体
# ------------------------------------------------------------------------------
show_rating_menu() {
    while true; do
        echo ""
        printf '%b\n' "${MSG["msg_show_rating_menu_menu"]}"
        read -rp "${MSG["msg_show_rating_menu_prompt"]}" rm_choice
        rm_choice="${rm_choice:-0}"

        case "$rm_choice" in
            1) manage_protocol_servers "u" ;;
            2) manage_protocol_servers "t" ;;
            3) export_server_ratings ;;
            4) import_server_ratings ;;
            5) reset_ratings_menu ;;
            6) update_servers ;;
            7) configure_vpn_timeout ;;
            0) break ;;
            *) echo "${MSG["msg_show_rating_menu_invalid"]}" ;;
        esac
    done
}

configure_vpn_timeout() {
    local t_val
    echo
    echo "${MSG["msg_configure_vpn_timeout_title"]}"
    printf '%s\n' "$(printf "${MSG["msg_configure_vpn_timeout_curr_val"]}" "$TIMEOUT_VPN_CONNECT")"
    read -rp "${MSG["msg_configure_vpn_timeout_prompt"]}" t_val
    if [[ "$t_val" =~ ^[0-9]+$ ]] && [ "$t_val" -ge 1 ] && [ "$t_val" -le 120 ]; then
        TIMEOUT_VPN_CONNECT="$t_val"
        save_all_settings
        printf '%s\n' "$(printf "${MSG["msg_configure_vpn_timeout_success"]}" "$TIMEOUT_VPN_CONNECT")"
    fi
}

#
# Initial setup (permissions, ID/password settings, and logrotate placement)
# 初期設定（権限付与 & ID/PASS設定 & logrotate配置）
#
permission_setup() {
    local data_dir="${FVPN_DATA:-$HOME/VPN/FastestVPN/data}"
    local log_dir="${FVPN_LOGDIR:-$HOME/VPN/FastestVPN/logs}"
    local auth_file="$data_dir/auth.conf"
    local logrotate_conf="/etc/logrotate.d/fvpn"

    echo
    echo "${MSG["msg_permission_setup_title"]}"

    if [ "$DEBUG" = "1" ]; then
        echo "[DEBUG] FVPN_DATA = $data_dir"
        echo "[DEBUG] FVPN_LOGDIR = $log_dir"
        echo "[DEBUG] AUTH_FILE = $auth_file"
    fi

    # 1. Create directories and set permissions
    # 1. ディレクトリ作成・権限設定
    echo "${MSG["msg_permission_setup_step1"]}"
    if [ ! -d "$data_dir" ]; then
        mkdir -p "$data_dir"
        printf '%s\n' "$(printf "${MSG["msg_permission_setup_dir_created"]}" "$data_dir")"
    fi
    chmod 700 "$data_dir" 2>/dev/null

    if [ ! -d "$log_dir" ]; then
        mkdir -p "$log_dir"
        printf '%s\n' "$(printf "${MSG["msg_permission_setup_log_created"]}" "$log_dir")"
    fi
    chmod 755 "$log_dir" 2>/dev/null

    # 2. Install the logrotate configuration
    # 2. logrotate 設定ファイルの配置
    echo
    echo "${MSG["msg_permission_setup_step2"]}"
    
    # Resolve the absolute path of openvpn.log precisely
    # openvpn.log の絶対パスを正確に特定
    local abs_log_path
    abs_log_path=$(readlink -f "${log_dir}/openvpn.log")

    cat << EOF | sudo tee "$logrotate_conf" >/dev/null
$abs_log_path {
    size 2M
    rotate 1
    copytruncate
    missingok
    notifempty
    su root root
}
EOF

    if [ $? -eq 0 ]; then
        sudo chmod 644 "$logrotate_conf" 2>/dev/null
        printf '%s\n' "$(printf "${MSG["msg_permission_setup_logrotate_success"]}" "$logrotate_conf")"
    else
        echo "${MSG["msg_permission_setup_logrotate_fail"]}"
    fi

    # 3. Configure ID/password credentials
    # 3. ID/PASS 認証情報設定
    # (Existing processing unchanged)
    # (既存処理そのまま)
}

#
# Cleanup (revoke permissions, remove auth file, and remove logrotate configuration)
# 終了処理（権限解除 & 認証ファイル破棄 & logrotate設定削除）
#
permission_cleanup() {
    local data_dir="${FVPN_DATA:-$HOME/VPN/FastestVPN/data}"
    local pid_file="$data_dir/fvpn.pid"
    local auth_file="$data_dir/auth.conf"
    local logrotate_conf="/etc/logrotate.d/fvpn"

    echo
    echo "${MSG["msg_permission_cleanup_title"]}"

    if [ "$DEBUG" = "1" ]; then
        echo "[DEBUG] PID_FILE = $pid_file"
        echo "[DEBUG] AUTH_FILE = $auth_file"
    fi

    local cleaned=0

    # 1. Remove the remaining PID file
    # 1. 残留PIDファイルの削除
    if [ -f "$pid_file" ]; then
        local pid
        pid=$(cat "$pid_file" 2>/dev/null)
        rm -f "$pid_file"
        printf '%s\n' "$(printf "${MSG["msg_permission_cleanup_pid_removed"]}" "${pid:-${MSG["msg_permission_cleanup_pid_unknown"]}}")"
        cleaned=1
    fi

    # 2. Remove the logrotate configuration
    # 2. logrotate 設定ファイルの削除
    if [ -f "$logrotate_conf" ]; then
        sudo rm -f "$logrotate_conf" 2>/dev/null
        printf '%s\n' "$(printf "${MSG["msg_permission_cleanup_logrotate_removed"]}" "$logrotate_conf")"
        cleaned=1
    fi

    if [ "$cleaned" -eq 0 ]; then
        echo "${MSG["msg_permission_cleanup_no_cleanup"]}"
    fi

    echo "${MSG["msg_permission_cleanup_cleanup_done"]}"
    return 0
}

# ------------------------------------------------------------------------------
# Start/stop usage (permission and authentication) submenu
# 使用開始・使用停止（権限認証）サブメニュー
# ------------------------------------------------------------------------------
show_setup_cleanup_menu() {
    while true; do
        echo ""
        printf '%b\n' "${MSG["msg_show_setup_cleanup_menu_menu"]}"
        read -rp "${MSG["msg_show_setup_cleanup_menu_prompt"]}" sc_choice
        sc_choice="${sc_choice:-0}"

        case "$sc_choice" in
            1) permission_setup ;;   # 従来の8番の処理関数
            2) permission_cleanup ;; # 従来の9番の処理関数
            0) break ;;
            *) echo "${MSG["msg_show_rating_menu_invalid"]}" ;;
        esac
    done
}

# ==============================================================================
# Main menu display and selection loop
# メインメニュー表示・選択ループ
# ==============================================================================
show_main_menu() {
    while true; do
        show_debug_registers

        printf '%b\n' "========== FVPN v${FVPN_VERSION} by Ton2Chan ==========" "${MSG["msg_show_main_menu_opts"]}"
        echo "-------------------------------------------"
        show_status_header
        
        read -rp "${MSG["msg_show_main_menu_prompt"]}" choice

        case "$choice" in
            1) quick_connect ;;
            2) disconnect_vpn ;;
            3) select_vpn_server ;;
            4) show_quick_connect_settings ;;
            5) show_rating_menu ;;
            9) show_setup_cleanup_menu ;;
            0)
                # 1. Confirm disconnect and perform cleanup when VPN is connected
                # 1. VPN接続中の場合は切断確認・クリーンアップ
                exit_fvpn

                # 2. Synchronize memory to files in one batch (master buffer and settings)
                # 2. メモリからファイルへ一括同期（マスターバッファ＆設定ファイル）
                save_master_servers_buffer
                save_all_settings

                # 3. Output the only exit message in the main routine
                # 3. メインルーチンで唯一の終了メッセージ出力
                echo "${MSG["msg_show_main_menu_exit"]}"
                break
                ;;
            *) echo "${MSG["msg_show_main_menu_invalid"]}" ;;
        esac

        echo ""
    done
}
