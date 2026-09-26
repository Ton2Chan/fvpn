#!/bin/bash
# ==============================================================================
# FVPN - Menu & User Interaction Module (UI & Interaction Layer)
# ==============================================================================

# ------------------------------------------------------------------------------
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

# 認証ステータス判定
local auth_status="認証:[--]"
local state="${AUTH_STATE:-0}"

if [ "$state" -gt 0 ]; then
    # 正の数: 認証OK (1, 2, ...)
    auth_status="認証:[OK]"
elif [ "$state" -lt 0 ]; then
    # 負の数: 認証NG (-1, -2, ...)
    auth_status="認証:[NG]"
else
    # 0: 未確認 / 初期状態
    auth_status="認証:[--]"
fi

    # 前半ヘッダー出力 (VPN  fix  lock [off] 認証:[NG] )
    printf "VPN %s%s%s %s" "$fix_str" "$lock_str" "$state_str" "$auth_status"
    echo ""

    # 後半部（汎用1行サーバー表示：引数なしで注目サーバーを出力）
    get_server_info_line

    echo ""
    echo "-------------------------------------------"
}

# ==============================================================================
# メッセージ表示付き接続処理 (UI要素を含む関数)
# ==============================================================================

# ------------------------------------------------------------------------------
# メッセージ表示付きマスターインデックス接続関数
# 引数: $1 = 0スタートのマスターインデックス
# 戻値: 0:成功 / 0以外:失敗
# ------------------------------------------------------------------------------
connect_by_master_index_wm() {
    local m_idx="$1"

    # 中間層接続関数の呼び出し（処理はすべて移譲）
    connect_by_master_index "$m_idx"
    local res=$?

    # --- 接続結果メッセージ表示 ---
    echo ""
    if [ "$res" -eq 0 ]; then
        echo " ✓ VPN接続が正常に確立しました。"
    else
        echo " ❌ VPN接続に失敗しました。"
        echo " 🔒 キルスイッチ(LOCKDOWN)により通信を保護中"
    fi

    return $res
}

# ------------------------------------------------------------------------------
# 1) VPN切断処理 (単一・確定シーケンス : メニュー2のコマンド)
# ------------------------------------------------------------------------------
disconnect_vpn() {
    echo "VPN切断処理を実行中..."

    # 物理層の切断・検証処理を一本道で呼び出し
    if phy_disconnect; then
        # 切断成功時、念のため中間層経由でクリーンアップを確定呼び出し
        phy_cleanup_if_disconnected
        echo "✓ 生IP通信へ復元しました。"
        return 0
    else
        echo "❌ 物理プロセスの停止に失敗しました。"
        return 1
    fi
}

# ------------------------------------------------------------------------------
# 2) アプリ終了前フェーズ制御 (確認ダイアログ & VPN切断)
# ------------------------------------------------------------------------------
exit_fvpn() {
    local current_mode
    current_mode=$(get_phy_mode)

    # 接続中、または保護ロック中(LOCKDOWN)の場合のみダイアログで確認
    if [ "$current_mode" != "DISCONNECTED" ]; then
        echo ""
        echo "⚠️  現在 VPN 接続中 (または保護ロック中) です。"
        read -rp "VPNを切断して終了しますか？ [y/N]: " ans

        case "$ans" in
            [yY]|[yY][eE][sS])
                disconnect_vpn
                ;;
            *)
                echo "VPN保護状態 (キルスイッチ) を継続します。"
                ;;
        esac
    else
        # 未接続状態の場合の念のためクリーンアップ
        phy_cleanup_if_disconnected
    fi
}

# ==============================================================================
# 簡易接続設定 UI・サブメニュー関数
# ==============================================================================

# 1) 接続モード変更処理
configure_connect_mode() {
    local m_opt
    echo
    echo "1: 固定アクセス (常に選択されている注目サーバーへ接続)"
    echo "2: 順番アクセス (接続ごとに次のサーバーへローテーション)"
    echo "3: ランダムアクセス (条件に合うサーバーから毎回自動選出)"
    read -rp "モード選択 [1-3]: " m_opt
    case "$m_opt" in
        1|2|3)
            CONNECT_MODE="$m_opt"
            ;;
    esac
}

# 2) プロトコル変更処理
configure_protocol_mode() {
    local p_opt
    echo
    echo "1: UDP のみ (高速・推奨)"
    echo "2: TCP のみ (安定重視)"
    echo "3: mix (UDP と TCP の両方から選択)"
    read -rp "プロトコル選択 [1-3]: " p_opt
    case "$p_opt" in
        1) set_protocol_mode 1 ;;
        2) set_protocol_mode -1 ;;
        3) set_protocol_mode 0 ;;
        *) return ;;
    esac

    # フィルター通過サーバー一覧の再構築
    build_active_servers
    sync_target_index_by_server
}

# 3) フィルタレベル変更処理
configure_filter_level() {
    local f_val
    echo
    echo "--- 接続フィルターレベルの選択 ---"
    echo " 4)  [4] 3  2  1  0  : 評価4(お気に入り)のみ選択"
    echo " 3)  [4  3] 2  1  0  : 評価3(それなり)以上を選択"
    echo " 2)  [4  3  2] 1  0  : 評価2(標準/無評価)以上を選択"
    echo " 1)  [4  3  2  1] 0  : 評価1(なんとか)以上を選択"
    echo " 0)  [4  3  2  1  0] : すべてのサーバーを選択"
    echo "---------------------------------------------------"
    read -rp "レベル選択 [0-4 / Enterで戻る]: " f_val
    if [ -n "$f_val" ] && [[ "$f_val" =~ ^[0-4]$ ]]; then
        FILTER_LEVEL="$f_val"
        build_active_servers
        sync_target_index_by_server
    fi
}

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

    # 1. ローカルに直接手動配置された zip がある場合 (起動時のフラグのみで判定)
    if [ "$HAS_UPDATE_ZIP" -eq 1 ]; then
        mkdir -p "$data_dir"
        cp -f "$local_zip" "$work_zip"
        mv -f "$local_zip" "$local_bak"
        HAS_UPDATE_ZIP=0  # 処理完了のためフラグをクリア
    else
        # 2. ネット経由ダウンロード時の判定
        # LAN切断(0以外) または ロックダウン中(LOCKDOWN) なら自動更新をスキップ
        if ! is_network_online || [ "$(get_phy_mode)" = "LOCKDOWN" ]; then
            echo "ネットに接続できません。"
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
            echo "⚠️ 更新ファイルのダウンロードに失敗しました。"
            return 1
        fi
    fi

    if ! apply_work_zip_package; then
        echo "⚠️ 更新パッケージの適用に失敗しました。"
        return 1
    fi

    local default_mark="${MARK_ADDED:-+}"
    if [ "${FVPN_TOTAL_COUNT}" -eq 0 ]; then
        default_mark="${MARK_NORMAL:-_}"
    fi

    build_master_servers "$default_mark"

    echo "✓ サーバーリストの更新が正常に完了しました。"
    return 0
}

# ==============================================================================
# 評価データのエクスポート（全件・固定フォーマット出力）
# ==============================================================================
export_server_ratings() {
    local target_dir
    target_dir=$(get_download_dir)

    if [ ! -d "$target_dir" ]; then
        mkdir -p "$target_dir" 2>/dev/null || {
            echo "エラー: 保存先ディレクトリ ($target_dir) を作成できませんでした。"
            return 1
        }
    fi

    if [ -z "$MASTER_SERVERS_BUFFER" ]; then
        echo "エラー: エクスポートするサーバーデータが存在しません。"
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

        # 末尾の改行を取り除いた128バイト行を取得
        local line="${rec%$'\n'}"
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
        echo "✓ ${exported_count} 件のサーバー評価データをエクスポートしました。"
        echo "  出力先: ${export_file}"
    else
        rm -f "$tmp_file"
        echo "エラー: エクスポート対象のデータがありませんでした。"
    fi

    return 0
}

# ==============================================================================
# 評価データのインポート（メモリ直接置換・定数利用版）
# ==============================================================================
import_server_ratings() {
    local target_dir
    target_dir=$(get_download_dir)

    local import_file="${target_dir}/${FILE_RATINGS_EXPORT_NAME:-fvpn_ratings.txt}"

    if [ ! -f "$import_file" ]; then
        echo "エラー: インポート対象のファイルが見つかりません。"
        echo "  確認パス: ${import_file}"
        return 1
    fi

    if [ -z "$MASTER_SERVERS_BUFFER" ]; then
        build_master_servers
    fi

    echo "評価データをインポートしています..."

    # 1. インポートファイルを連想配列に一括取り込み (O(N))
    declare -A import_map
    local loaded_count=0
    local line

    while IFS= read -r line || [ -n "$line" ]; do
        [ ${#line} -lt 14 ] && continue

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
        echo "警告: インポートファイル内に有効な評価データが見つかりませんでした。"
        return 1
    fi

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

        # 変更対象が存在するか確認
        if [ -n "${import_map[$key]+exists}" ]; then
            local new_r="${import_map[$key]}"
            local current_r="${rec:${OFFSET_RATING}:${LENGTH_RATING}}"

            # 現在の評価値と異なる場合のみインプレース置換
            if [ "$current_r" != "$new_r" ]; then
                local target_idx=$((offset + ${OFFSET_RATING}))
                
                # バッファの 10バイト目のみを書き換え（全体文字列の再構築・再連結を回避）
                MASTER_SERVERS_BUFFER="${MASTER_SERVERS_BUFFER:0:$target_idx}${new_r}${MASTER_SERVERS_BUFFER:$((target_idx + 1))}"
                ((updated_count++))
            fi
        fi

        offset=$((offset + rec_size))
    done

    # 3. 変更があった場合のみ保存と有効化処理を実行
    if [ "$updated_count" -gt 0 ]; then
        build_active_servers
        sync_target_index_by_server
        echo "✓ ${updated_count} 件のサーバー評価データをインポートしました。"
    else
        echo "情報: 評価データの変更はありませんでした。"
    fi

    return 0
}

# ==============================================================================
# 簡易接続 ロジック計算処理
# ==============================================================================

# 簡易VPN接続 本体
quick_connect() {
    local N="${ACTIVE_TOTAL_COUNT}"

    if [ "$N" -le 0 ]; then
        echo "❌ フィルターを通過した接続可能なサーバーが存在しません。"
        return 1
    fi

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

    # 確定した TARGET_INDEX からマスターインデックス（0スタート）を取得
    local m_idx
    m_idx=$(get_target_master_index)

    # 選択サーバーの表示
    local display_info
    display_info=$(get_server_info_line "$TARGET_INDEX")
    echo "${display_info}"

    # VPN接続実行（メッセージ表示を行うUI統合接続関数へ）
    connect_by_master_index_wm "$m_idx"
    return $?
}

# 簡易接続設定 メインサブメニュー
show_quick_connect_settings() {
    while true; do
        local mode_disp proto_disp filter_disp

        # 1) 接続モード表示 (1: 固定 / 2: 順番 / 3: ランダム)
        case "${CONNECT_MODE}" in
            1) mode_disp="[1:固定] 2:順番  3:ランダム" ;;
            2) mode_disp=" 1:固定 [2:順番] 3:ランダム" ;;
            3) mode_disp=" 1:固定  2:順番 [3:ランダム]" ;;
            *) mode_disp="[1:固定] 2:順番  3:ランダム" ;;
        esac

        # 2) プロトコル表示 (正の数: UDP / 負の数: TCP / 0: mix)
        local p="${PROTOCOL_MODE}"
        if (( p > 0 )); then
            proto_disp="[1:UDP]  2:TCP  3:mix"
        elif (( p < 0 )); then
            proto_disp="1:UDP  [2:TCP]  3:mix"
        else
            proto_disp="1:UDP  2:TCP  [3:mix]"
        fi

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
        echo "========== 簡易接続設定 =========="
        echo " 1) 接続モード変更   : ${mode_disp}"
        echo " 2) プロトコル変更   : ${proto_disp}"
        echo " 3) フィルタレベル   : ${filter_disp}"
        echo " 0) 戻る (Enterのみでも戻ります)"
        echo "----------------------------------"
        read -p "選択 [0]: " q_choice
        q_choice="${q_choice:-0}"

        case "$q_choice" in
            1) configure_connect_mode ;;
            2) configure_protocol_mode ;;
            3) configure_filter_level ;;
            0) break ;;
            *) echo "無効な選択肢です。" ;;
        esac
    done
}

# ==============================================================================
# サーバー管理・評価 UI・サブメニュー関数
# ==============================================================================

reset_ratings_menu() {
    echo ""
    read -p "すべてのサーバー評価をデフォルト(2)に初期化しますか？ (y/N): " confirm
    case "$confirm" in
        [yY]|[yY][eE][sS])
            if reset_server_ratings; then
                echo "✓ 処理が完了しました。(フィルターレベルを0にリセットしました)"
            fi
            ;;
        *)
            echo "キャンセルしました。"
            ;;
    esac
}

# ------------------------------------------------------------------------------
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

    [ "$max_num" -le 0 ] && { echo "(該当する ${proto_label} サーバーがありません)"; return 0; }

    # 1. 最初の一回のみ一覧表を表示
    echo ""
    echo "========== ${proto_label} サーバー一覧・評価設定 =========="
    
    local base_index
    base_index=$(get_master_index "$target_proto" 1)
    local start_byte=$(( base_index * record_size ))
    local total_bytes=$(( max_num * record_size ))
    local sub_buf="${MASTER_SERVERS_BUFFER:$start_byte:$total_bytes}"

    # 行末空白を除去して一括表示
    printf '%s' "$sub_buf" | sed 's/[[:space:]]*$//'

    echo "=================================================="
    echo " 評価凡例: 4:お気に入り, 2:無評価, 1:なんとか, 3:それなり, 0:除外"
    echo "--------------------------------------------------"

    # 2. 評価変更の受付ループ
    while true; do
        read -rp "評価を変更するサーバー番号を選択 [Enterまたは0で戻る]: " num_input

        [ -z "$num_input" ] || [ "$num_input" = "0" ] && break

        # 範囲チェック
        if [[ ! "$num_input" =~ ^[1-9][0-9]*$ ]] || [ "$num_input" -gt "$max_num" ]; then
            echo "⚠️ 1 から ${max_num} の範囲で入力してください。"
            continue
        fi

        # 0スタート番号からマスターインデックスを算出
        local target_master_idx
        target_master_idx=$(get_master_index "$target_proto" "$num_input")

        echo "$(get_master_server_info_line "$target_master_idx")"
        read -rp "新しい評価を入力してください [0-4]: " new_rate
        if [[ ! "$new_rate" =~ ^[0-4]$ ]]; then
            echo "⚠️ 0から4の範囲で入力してください。"
            continue
        fi

        # 評価を更新して該当行のみを出力表示
        update_server_rating_by_master_index "$target_master_idx" "$new_rate"
        echo "$(get_master_server_info_line "$target_master_idx")"
        echo ""
    done
}

# ------------------------------------------------------------------------------
# サーバー個別指定接続機能 本体
# ------------------------------------------------------------------------------
select_vpn_server() {
    local target_proto=""

    # --- 1. プロトコル選択ループ ---
    while true; do
        echo -e "\n========== サーバー個別指定接続 =========="
        echo " 1) UDP"
        echo " 2) TCP"
        echo " 0) 戻る (Enterのみでも戻ります)"
        read -rp "選択 [0-2]: " p_choice

        case "$p_choice" in
            1) target_proto="u"; break ;;
            2) target_proto="t"; break ;;
            0|"") echo "キャンセルしました。"; return 0 ;;
            *) echo "⚠️ 無効な選択です。0-2 の範囲で入力してください。" ;;
        esac
    done

    # --- 2. 対象件数の確認 ---
    local target_count=0
    if [ "$target_proto" = "u" ]; then
        target_count="${ACTIVE_UDP_COUNT}"
    else
        target_count="${ACTIVE_TCP_COUNT}"
    fi

    if [ "$target_count" -le 0 ]; then
        echo "⚠️ 選択されたプロトコル (${target_proto^^}) のフィルター通過サーバーは 0 件です。"
        return 0
    fi

    # --- 3. 該当プロトコル領域のみをスライス表示 ---
    echo ""
    echo "--- 選択可能サーバー一覧 (${target_proto^^} : ${target_count}件) ---"

    local start_offset=0
    [ "$target_proto" = "t" ] && start_offset=$(( ${ACTIVE_UDP_COUNT} * RECORD_BYTE_SIZE ))
    local total_bytes=$(( target_count * RECORD_BYTE_SIZE ))

    local sub_buf="${ACTIVE_SERVERS_BUFFER:$start_offset:$total_bytes}"
    printf '%s\n' "$sub_buf" | sed 's/[[:space:]]*$//'

    # --- 4. サーバー番号入力 ＆ 再入力ループ ---
    local match_target_index=-1
    local target_master_idx=-1
    local s_num=""

    while true; do
        read -rp "接続するサーバー番号を入力 (0:戻る): " s_num

        # キャンセル（0または未入力）
        if [ -z "$s_num" ] || [ "$s_num" -eq 0 ] 2>/dev/null; then
            echo "キャンセルしました。"
            return 0
        fi

        # 数値チェック
        if ! [[ "$s_num" =~ ^[1-9][0-9]*$ ]]; then
            echo "⚠️ 無効な入力です。数値で指定してください。"
            continue
        fi

        # PASSバッファから該当サーバーを検索
        match_target_index=-1
        target_master_idx=-1
        local i=0

        while [ "$i" -lt "$target_count" ]; do
            local current_offset=$(( start_offset + (i * RECORD_BYTE_SIZE) ))
            local rec="${ACTIVE_SERVERS_BUFFER:$current_offset:RECORD_BYTE_SIZE}"

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

        # 存在チェック: 見つかった場合はループを抜けて接続へ
        if [ "$target_master_idx" -ge 0 ]; then
            break
        fi

        # 見つからなかった場合は警告を出して再入力
        echo "⚠️ サーバー番号 [ ${s_num} ] は ${target_proto^^} のフィルター通過一覧に存在しません。"
    done

    # 注目サーバーの更新
    TARGET_INDEX="$match_target_index"
    update_target_server_by_index

    # --- 5. 一元接続関数による接続実行 ---
    get_server_info_line
    echo ""
    connect_by_master_index_wm "$target_master_idx"
    return $?
}

# ------------------------------------------------------------------------------
# サーバー管理・評価 サブメニュー本体
# ------------------------------------------------------------------------------
show_rating_menu() {
    while true; do
        echo ""
        echo "========== サーバー管理・評価メニュー =========="
        echo " 1) UDP サーバーの一覧・評価設定"
        echo " 2) TCP サーバーの一覧・評価設定"
        echo " 3) サーバー評価をエクスポート"
        echo " 4) サーバー評価をインポート"
        echo " 5) 評価のリセット"
        echo " 6) サーバー情報の更新"
        echo " 7) VPN接続タイムアウト設定"
        echo " 0) 戻る (Enterのみでも戻ります)"
        echo "------------------------------------------------"
        read -rp "選択 [0]: " rm_choice
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
            *) echo "無効な選択です。" ;;
        esac
    done
}

configure_vpn_timeout() {
    local t_val
    echo
    echo "--- VPN接続タイムアウト設定 ---"
    echo " 現在の値: ${TIMEOUT_VPN_CONNECT} 秒"
    read -rp "新しいタイムアウト秒数を入力 [1-120 / Enterで戻る]: " t_val
    if [[ "$t_val" =~ ^[0-9]+$ ]] && [ "$t_val" -ge 1 ] && [ "$t_val" -le 120 ]; then
        TIMEOUT_VPN_CONNECT="$t_val"
        save_all_settings
        echo "✓ タイムアウトを ${TIMEOUT_VPN_CONNECT} 秒に設定しました。"
    fi
}

#
# 初期設定（権限付与 & ID/PASS設定）
#
permission_setup() {
    local data_dir="${FVPN_DATA:-$HOME/VPN/FastestVPN/data}"
    local auth_file="$data_dir/auth.conf"

    echo
    echo "=== 初期設定（権限付与 & 認証情報設定） ==="

    if [ "$DEBUG" = "1" ]; then
        echo "[DEBUG] FVPN_DATA = $data_dir"
        echo "[DEBUG] AUTH_FILE = $auth_file"
    fi

    #
    # 1. 権限付与処理（先行実行）
    #
    echo "1. 権限・ディレクトリのセットアップ中..."
    if [ ! -d "$data_dir" ]; then
        mkdir -p "$data_dir"
        echo "   ✓ データディレクトリを作成しました: $data_dir"
    else
        echo "   ✓ データディレクトリ確認完了"
    fi
    chmod 700 "$data_dir" 2>/dev/null
    echo "   ✓ 権限設定を完了しました"

    #
    # 2. ID/PASS 設定処理
    #
    echo
    echo "2. 認証情報 (ID/PASS) の設定"

    local current_user=""
    local current_pass=""

    # 既存の auth.conf から現在の情報を読み込み
    if [ -f "$auth_file" ]; then
        current_user=$(sed -n '1p' "$auth_file")
        current_pass=$(sed -n '2p' "$auth_file")
        echo "   (現在の設定ユーザー: ${current_user:-未設定})"
        echo "   ※ 変更しない項目は Enter を押すとそのまま保持されます。"
    fi

    echo
    read -rp "ユーザー名 (ID) [${current_user:-未設定}]: " input_user
    read -s -rp "パスワード: " input_pass
    echo

    # 入力が空（Enterのみ）の場合は既存値を保持、未設定かつ空の場合は入力を促す
    local final_user="${input_user:-$current_user}"
    local final_pass="${input_pass:-$current_pass}"

    if [ -z "$final_user" ] || [ -z "$final_pass" ]; then
        echo "エラー: ユーザー名またはパスワードが未設定です。認証情報の保存をスキップしました。"
        return 1
    fi

    # auth.conf の書き出し (権限 600)
    {
        echo "$final_user"
        echo "$final_pass"
    } > "$auth_file"

    chmod 600 "$auth_file"

    echo "✓ 認証情報を保存しました: $auth_file"
    echo "初期設定 (権限付与) が完了しました。"
    return 0
}

#
# 終了処理（権限解除 & 認証ファイル破棄）
#
permission_cleanup() {
    local data_dir="${FVPN_DATA:-$HOME/VPN/FastestVPN/data}"
    local pid_file="$data_dir/fvpn.pid"
    local auth_file="$data_dir/auth.conf"

    echo
    echo "=== 終了処理（クリーンアップ・認証情報破棄） ==="

    if [ "$DEBUG" = "1" ]; then
        echo "[DEBUG] PID_FILE = $pid_file"
        echo "[DEBUG] AUTH_FILE = $auth_file"
    fi

    local cleaned=0

    # 1. 残留PIDファイルの削除
    if [ -f "$pid_file" ]; then
        local pid
        pid=$(cat "$pid_file" 2>/dev/null)
        rm -f "$pid_file"
        echo "✓ 残存PIDファイルを削除しました (PID: ${pid:-不明})"
        cleaned=1
    fi

    if [ "$cleaned" -eq 0 ]; then
        echo "✓ 削除・クリーンアップが必要なファイルはありませんでした。"
    fi

    echo "終了処理が完了しました。"
    return 0
}

# ------------------------------------------------------------------------------
# 使用開始・使用停止（権限認証）サブメニュー
# ------------------------------------------------------------------------------
show_setup_cleanup_menu() {
    while true; do
        echo ""
        echo "========== 使用開始・使用停止設定 =========="
        echo " 1) 使用開始 (権限付与・認証設定) ※ 使用開始する前に実行してください。"
        echo " 2) 使用停止 (権限解除) ※ 当アプリを削除する前に実行してください。"
        echo " 0) 戻る (Enterのみでも戻ります)"
        echo "--------------------------------------------"
        read -rp "選択 [0]: " sc_choice
        sc_choice="${sc_choice:-0}"

        case "$sc_choice" in
            1) permission_setup ;;   # 従来の8番の処理関数
            2) permission_cleanup ;; # 従来の9番の処理関数
            0) break ;;
            *) echo "無効な選択です。" ;;
        esac
    done
}

# ==============================================================================
# メインメニュー表示・選択ループ
# ==============================================================================
show_main_menu() {
    while true; do
        show_debug_registers

        echo "========== FVPN v1.0.5 by Ton2Chan =========="
        echo " 1) 簡易VPN接続 (注目サーバーへ接続)"
        echo " 2) VPN切断"
        echo " 3) サーバー個別指定接続"
        echo " 4) 簡易接続設定 (モード・プロトコル・フィルタ)"
        echo " 5) サーバー管理・評価・更新"
        echo " 9) 使用開始・使用停止 (権限認証)"
        echo " 0) 終了"
        echo "-------------------------------------------"
        show_status_header
        
        read -rp "選択してください [0-9]: " choice

        case "$choice" in
            1) quick_connect ;;
            2) disconnect_vpn ;;
            3) select_vpn_server ;;
            4) show_quick_connect_settings ;;
            5) show_rating_menu ;;
            9) show_setup_cleanup_menu ;;
            0)
                # 1. VPN接続中の場合は切断確認・クリーンアップ
                exit_fvpn

                # 2. メモリからファイルへ一括同期（マスターバッファ＆設定ファイル）
                save_master_servers_buffer
                save_all_settings

                # 3. メインルーチンで唯一の終了メッセージ出力
                echo "FVPN を終了します。"
                break
                ;;
            *) echo "❌ 無効な選択肢です。" ;;
        esac

        echo ""
    done
}
