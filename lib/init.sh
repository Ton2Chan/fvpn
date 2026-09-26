#!/bin/bash
# ==============================================================================
# FVPN - Initialization & Environment Manager (Settings, Boot & Updates)
# FVPN - 初期化 & 環境管理モジュール (設定, 起動 & アップデート)
# Version : 1.1.0
# ==============================================================================

# Set protocol mode / プロトコルモードの設定
set_protocol_mode() {
    local mode_num="${1}"
    PROTOCOL_MODE="$mode_num"
}

# Download URL to working zip archive / 指定URLからZIPアーカイブをダウンロード
download_url_to_work_zip() {
    local url="${1:-$OFFICIAL_UPDATE_URL}"
    local dest_zip="$2"
    local timeout="${CURRENT_TIMEOUT}"

    if [ -z "$url" ] || [ -z "$dest_zip" ]; then
        return 1
    fi

    mkdir -p "$(dirname "$dest_zip")" 2>/dev/null

    if command -v curl >/dev/null 2>&1; then
        curl -sSL -A "Mozilla/5.0" --connect-timeout "$timeout" -o "$dest_zip" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -q --user-agent="Mozilla/5.0" --timeout="$timeout" -O "$dest_zip" "$url"
    else
        return 1
    fi

    [ -s "$dest_zip" ]
}

# ------------------------------------------------------------------------------
# should_check_update
# Determine whether to execute automatic server list update check
# サーバーリストの自動更新チェックを実行すべきか判定する
# Return / 戻り値: 0 = Execute check / チェック実行, 1 = Skip / スキップ
# ------------------------------------------------------------------------------
should_check_update() {
    # 1. Mandatory execution on first boot or when unupdated (LAST_UPDATE_TS is 0 or unset)
    # 初回起動/未更新時（LAST_UPDATE_TS が 0 または未設定）は必須実行
    local last_up="${LAST_UPDATE_TS:-0}"
    local last_chk="${LAST_CHECK_TS:-0}"
    [ "$last_up" -eq 0 ] && return 0

    local now_ts
    now_ts=$(date +%s)

    # 2. UPDATE_CHECK_INTERVAL (Cooldown period) evaluation
    # UPDATE_CHECK_INTERVAL (完全封印期間) の判定
    local check_interval_days="${UPDATE_CHECK_INTERVAL:-7}"
    if [ "$check_interval_days" -gt 0 ]; then
        local check_interval_sec=$(( check_interval_days * 86400 ))
        local diff_up=$(( now_ts - last_up ))
        if [ "$diff_up" -lt "$check_interval_sec" ]; then
            return 1 # Skip during cooldown period / 封印期間中のためスキップ
        fi
    fi

    # 3. UPDATE_RETRY_INTERVAL evaluation
    # UPDATE_RETRY_INTERVAL (チェック間隔) の判定
    local retry_interval_days="${UPDATE_RETRY_INTERVAL:-1}"
    if [ "$retry_interval_days" -eq 0 ]; then
        return 0 # Execute on every boot if set to 0 / 0指定時は起動毎にチェック実行
    fi

    local retry_interval_sec=$(( retry_interval_days * 86400 ))
    local diff_chk=$(( now_ts - last_chk ))
    if [ "$diff_chk" -ge "$retry_interval_sec" ]; then
        return 0 # Execute as interval has elapsed / チェック間隔経過のため実行
    fi

    return 1 # Skip as interval has not elapsed / チェック間隔未満のためスキップ
}

# ------------------------------------------------------------------------------
# Get user download directory path (XDG specification compliant)
# ダウンロードフォルダのパス取得 (XDG 規格準拠)
# ------------------------------------------------------------------------------
get_download_dir() {
    local dl_dir=""

    # 1. Execute xdg-user-dir command if available
    # xdg-user-dir コマンドが存在すれば実行して取得
    if command -v xdg-user-dir >/dev/null 2>&1; then
        dl_dir=$(xdg-user-dir DOWNLOAD 2>/dev/null)
    fi

    # 2. Parse user-dirs.dirs file if command is unavailable
    # コマンドで取れず、user-dirs.dirs ファイルが存在すれば解析
    if [ -z "$dl_dir" ] && [ -f "${XDG_CONFIG_HOME:-$HOME/.config}/user-dirs.dirs" ]; then
        local raw_dir
        raw_dir=$(grep "^XDG_DOWNLOAD_DIR=" "${XDG_CONFIG_HOME:-$HOME/.config}/user-dirs.dirs" | cut -d'"' -f2)
        [ -n "$raw_dir" ] && dl_dir=$(eval echo "$raw_dir")
    fi

    # 3. Fallback to $HOME/Downloads if neither method works
    # どちらでも取れない場合のフォールバック ($HOME/Downloads)
    printf "%s" "${dl_dir:-$HOME/Downloads}"
}

# Check authentication configuration existence / 認証情報の存在確認
check_auth_config() {
    [ -s "${FVPN_AUTH}" ]
}

# Apply downloaded ZIP update package / ZIPアップデートパッケージの適用
apply_work_zip_package() {
    local base_dir="${FVPN_HOME}"
    local data_dir="${FVPN_DATA}"
    local work_zip="${data_dir}/fastestvpn_ovpn.zip"
    local stage_dir="${_UPDATE_WORK_DIR:-${data_dir}/_update_staging}"

    [ ! -f "$work_zip" ] && return 1

    local udp_dir="${FVPN_UDP_DIR}"
    local tcp_dir="${FVPN_TCP_DIR}"

    rm -rf "$stage_dir"
    mkdir -p "$stage_dir" "$udp_dir" "$tcp_dir"

    # 1. ZIP extraction check / ZIP解凍チェック
    if ! unzip -q -o "$work_zip" -d "$stage_dir"; then
        rm -rf "$stage_dir" "$work_zip"
        return 1
    fi

    # 2. Get expected total count of .ovpn files / 期待される .ovpn ファイル総数を取得
    local expected_cnt
    expected_cnt=$(find "$stage_dir" -type f -iname "*.ovpn" 2>/dev/null | wc -l)

    # 3. Ultra-fast guard: Fail immediately if no .ovpn files found
    # 超高速ガード: .ovpn ファイルが存在しない場合は失敗終了
    [ "$expected_cnt" -eq 0 ] && { rm -rf "$stage_dir" "$work_zip"; return 1; }

    # 4. Ultra-fast guard: Fail if no valid OpenVPN configs (remote directive) exist
    # 超高速ガード: 有効な OpenVPN 設定 (remote 記述) が1つも含まれない場合は失敗終了
    grep -q -i -E '^[[:space:]]*remote[[:space:]]+' "$stage_dir"/*.ovpn "$stage_dir"/*/*.ovpn 2>/dev/null || { rm -rf "$stage_dir" "$work_zip"; return 1; }

    # 5. Create temporary backup directory / 一時バックアップディレクトリの作成
    local bak_dir="${data_dir}/_ovpn_backup"
    rm -rf "$bak_dir"
    mkdir -p "${bak_dir}/udp" "${bak_dir}/tcp"

    # 6. Record existing file count and evacuate to backup (Fail-safe)
    # 既存ファイルの総数を記録し、バックアップ領域へ退避 (フェイルセーフ)
    local old_cnt
    old_cnt=$(find "${udp_dir}" "${tcp_dir}" -type f -iname "*.ovpn" 2>/dev/null | wc -l)

    mv "${udp_dir}"/*.ovpn "${bak_dir}/udp/" 2>/dev/null
    mv "${tcp_dir}"/*.ovpn "${bak_dir}/tcp/" 2>/dev/null

    local bak_cnt
    bak_cnt=$(find "$bak_dir" -type f -iname "*.ovpn" 2>/dev/null | wc -l)

    # Restore old files and fail if evacuation count mismatches
    # 退避件数が不一致（退避失敗）の場合は旧配置を復元して失敗終了
    if [ "$bak_cnt" -ne "$old_cnt" ]; then
        mv "${bak_dir}/udp"/*.ovpn "${udp_dir}/" 2>/dev/null
        mv "${bak_dir}/tcp"/*.ovpn "${tcp_dir}/" 2>/dev/null
        rm -rf "$stage_dir" "$work_zip" "$bak_dir"
        return 1
    fi

    # 7. Move new .ovpn files / 新しい .ovpn ファイルを移動
    find "$stage_dir" -type f -iname "*udp*.ovpn" -exec mv {} "${udp_dir}/" \; 2>/dev/null
    find "$stage_dir" -type f -iname "*tcp*.ovpn" -exec mv {} "${tcp_dir}/" \; 2>/dev/null

    # 8. Placement check (Count actually categorized/moved files)
    # 配置完了チェック (実際に分類・移動されたファイル数のカウント)
    local new_cnt
    new_cnt=$(find "${udp_dir}" "${tcp_dir}" -type f -iname "*.ovpn" 2>/dev/null | wc -l)

    # 9. If new count mismatches expected count, purge new files and restore from backup
    # 期待件数と不一致（移動失敗または一部失敗）の場合は新ファイルを撤去しバックアップから完全復元
    if [ "$new_cnt" -ne "$expected_cnt" ]; then
        rm -f "${udp_dir}"/*.ovpn "${tcp_dir}"/*.ovpn
        mv "${bak_dir}/udp"/*.ovpn "${udp_dir}/" 2>/dev/null
        mv "${bak_dir}/tcp"/*.ovpn "${tcp_dir}/" 2>/dev/null
        rm -rf "$stage_dir" "$work_zip" "$bak_dir"
        return 1
    fi

    # 10. Purge staging/backup and update timestamps only on 100% success
    # 100%成功時のみ作業領域とバックアップを削除してタイムスタンプ更新
    rm -rf "$stage_dir" "$work_zip" "$bak_dir"

    LAST_CHECK_TS=$(date +%s)
    LAST_CHECK_DATE=$(date +'%Y-%m-%d %H:%M:%S')
    LAST_UPDATE_TS="${LAST_CHECK_TS}"
    LAST_UPDATE_DATE="${LAST_CHECK_DATE}"

    return 0
}

# Load all application settings / 全設定の読み込み
load_all_settings() {
    local ini_file="${FILE_SETTINGS_INI}"
    if [ -f "$ini_file" ]; then
        while IFS='=' read -r key val || [ -n "$key" ]; do
            [[ "$key" =~ ^[[:space:]]*# ]] && continue
            [[ "$key" =~ ^\[.*\]$ ]] && continue
            key=$(echo "$key" | xargs)
            val=$(echo "$val" | xargs)
            
            case "$key" in
                TARGET_SERVER)
                    TARGET_SERVER="$val"
                    ;;
                CONNECT_MODE)
                    # 1: FIX, 2: SEQ, 3: RAND
                    if [[ "$val" =~ ^[1-3]$ ]]; then
                        CONNECT_MODE="$val"
                    fi
                    ;;
                PROTOCOL_MODE)
                    # -1: TCP, 0: MIX, 1: UDP
                    if [[ "$val" =~ ^-?[0-9]+$ ]] && [ "$val" -ge -1 ] && [ "$val" -le 1 ]; then
                        PROTOCOL_MODE="$val"
                    fi
                    ;;
                FILTER_LEVEL)
                    # Range 0 to 4 / 0 〜 4 の範囲
                    if [[ "$val" =~ ^[0-4]$ ]]; then
                        FILTER_LEVEL="$val"
                    fi
                    ;;
                TIMEOUT_AUTO_UPDATE | TIMEOUT_MANUAL_UPDATE | TIMEOUT_VPN_CONNECT)
                    # Allow 0 or positive integers / 0以上許可
                    if [[ "$val" =~ ^[0-9][0-9]*$ ]]; then
                        eval "$key=\"$val\""
                    fi
                    ;;
                UPDATE_CHECK_INTERVAL | UPDATE_RETRY_INTERVAL)
                    # Allow 0 or positive integers (days) / 0以上の数値（日指定）を許可
                    if [[ "$val" =~ ^[0-9]+$ ]]; then
                        eval "$key=\"$val\""
                    fi
                    ;;
                LAST_CHECK_TS | LAST_UPDATE_TS)
                    # Epoch seconds / エポック秒（0以上の数値）
                    if [[ "$val" =~ ^[0-9]+$ ]]; then
                        eval "$key=\"$val\""
                    fi
                    ;;
                LAST_CHECK_DATE | LAST_UPDATE_DATE)
                    # Date string / 日付文字列（空文字でなければ採用）
                    if [ -n "$val" ]; then
                        eval "$key=\"$val\""
                    fi
                    ;;
            esac
        done < "$ini_file"
    fi

    build_active_servers
}

# Save all application settings / 全設定の保存
save_all_settings() {
    local ini_file="${FILE_SETTINGS_INI}"
    mkdir -p "$(dirname "$ini_file")" 2>/dev/null

    cat << EOF > "$ini_file"
[SETTINGS]
TARGET_SERVER=${TARGET_SERVER:-}
CONNECT_MODE=${CONNECT_MODE}
PROTOCOL_MODE=${PROTOCOL_MODE}
FILTER_LEVEL=${FILTER_LEVEL}
TIMEOUT_AUTO_UPDATE=${TIMEOUT_AUTO_UPDATE}
TIMEOUT_MANUAL_UPDATE=${TIMEOUT_MANUAL_UPDATE}
TIMEOUT_VPN_CONNECT=${TIMEOUT_VPN_CONNECT}
UPDATE_CHECK_INTERVAL=${UPDATE_CHECK_INTERVAL}
UPDATE_RETRY_INTERVAL=${UPDATE_RETRY_INTERVAL}
LAST_CHECK_TS=${LAST_CHECK_TS}
LAST_UPDATE_TS=${LAST_UPDATE_TS}
LAST_CHECK_DATE=${LAST_CHECK_DATE:-}
LAST_UPDATE_DATE=${LAST_UPDATE_DATE:-}
EOF
}

# ------------------------------------------------------------------------------
# resolve_work_line (Worker function invoked in parallel by xargs -P 16)
# resolve_work_line (xargs -P 16 から呼ばれる必須ワーカー関数)
# ------------------------------------------------------------------------------
resolve_work_line() {
    local key="$1"
    local domain="$2"

    local ip="0.0.0.0"
    if [ -n "$domain" ]; then
        local resolved
        resolved=$(getent ahosts "$domain" | awk '{print $1}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1)
        [ -n "$resolved" ] && ip="$resolved"
    fi

    # 15-character fixed length (Right padded with spaces) / 15文字固定長 (右パディングスペース埋め)
    printf "%s %-15s\n" "$key" "$ip"
}
export -f resolve_work_line

# ==============================================================================
# build_master_servers
# Master function containing 16-parallel DNS IP resolution logic
# 16並列IP引き制御を内包するマスターサーバーバッファ構築関数
# ==============================================================================
build_master_servers() {
    local default_mark="${1:-$MARK_NORMAL}"
    local udp_dir="${FVPN_UDP_DIR}"
    local tcp_dir="${FVPN_TCP_DIR}"

    # 1. Evacuate old rating map from existing buffer
    # 既存バッファから旧評価値マップの退避
    declare -A old_map
    if [ -n "$MASTER_SERVERS_BUFFER" ]; then
        local buf_len=${#MASTER_SERVERS_BUFFER}
        local offset=0
        while [ "$offset" -lt "$buf_len" ]; do
            local rec="${MASTER_SERVERS_BUFFER:$offset:$RECORD_BYTE_SIZE}"
            [ ${#rec} -lt "$RECORD_BYTE_SIZE" ] && break

            local r_val="${rec:$OFFSET_RATING:$LENGTH_RATING}"
            local server_key="${rec:$OFFSET_PROTO}"
            server_key="$(echo "$server_key" | xargs)"

            [ -n "$server_key" ] && old_map["$server_key"]="${r_val}"
            offset=$(( offset + RECORD_BYTE_SIZE ))
        done
    fi

    # 2. Extract "proto/filename domain port" from all .ovpn files (CR removed)
    # 全 .ovpn から 「u/ファイル名 ドメイン名 ポート番号」 の作業リストを作成 (CR除去付き)
    local work_src=""
    if [ -d "$udp_dir" ]; then
        while IFS=: read -r fpath line; do
            local fname domain port
            fname=$(basename "$fpath")
            line=$(echo "$line" | tr -d '\r')
            domain=$(echo "$line" | awk '{print $2}')
            port=$(echo "$line" | awk '{print $3}')
            work_src+="u/${fname} ${domain} ${port}\n"
        done < <(grep -H -E '^[[:space:]]*remote[[:space:]]+' "${udp_dir}"/*.ovpn 2>/dev/null)
    fi

    if [ -d "$tcp_dir" ]; then
        while IFS=: read -r fpath line; do
            local fname domain port
            fname=$(basename "$fpath")
            line=$(echo "$line" | tr -d '\r')
            domain=$(echo "$line" | awk '{print $2}')
            port=$(echo "$line" | awk '{print $3}')
            work_src+="t/${fname} ${domain} ${port}\n"
        done < <(grep -H -E '^[[:space:]]*remote[[:space:]]+' "${tcp_dir}"/*.ovpn 2>/dev/null)
    fi

    # 3. Execute 16-parallel DNS resolution and populate associative arrays (IP_MAP / PORT_MAP)
    # 16並列 IP 引きの実行と連想配列 (IP_MAP / PORT_MAP) への格納
    declare -A IP_MAP
    declare -A PORT_MAP

    local key_res ip_res
    while read -r key_res ip_res; do
        [ -n "$key_res" ] && IP_MAP["$key_res"]="$ip_res"
    done < <(echo -e "$work_src" | xargs -P 16 -I {} bash -c 'resolve_work_line {}')

    local raw_k _ raw_p
    while read -r raw_k _ raw_p; do
        [ -n "$raw_k" ] && PORT_MAP["$raw_k"]="$raw_p"
    done < <(echo -e "$work_src")

    # 4. Generate fixed-length buffer in a single loop
    # 単一ループで固定長バッファを一括生成
    local new_buf=""
    local udp_cnt=0
    local tcp_cnt=0
    local fname_field_len=$(( RECORD_BYTE_SIZE - OFFSET_PROTO - 1 )) # 94 bytes / 94バイト

    local raw_key
    while read -r raw_key _ _; do
        [ -z "$raw_key" ] && continue

        local proto_type="${raw_key:0:1}"
        local seq_num=0

        if [ "$proto_type" = "u" ]; then
            ((udp_cnt++))
            seq_num=$udp_cnt
        else
            ((tcp_cnt++))
            seq_num=$tcp_cnt
        fi

        local seq_str
        seq_str=$(printf "%4d" "$seq_num")

        local mark="$default_mark"
        local r_val="2"

        if [ -n "${old_map[$raw_key]+exists}" ]; then
            mark="$MARK_NORMAL"
            r_val="${old_map[$raw_key]}"
        fi

        local ip_val="${IP_MAP[$raw_key]:-0.0.0.0}"
        local port_val="${PORT_MAP[$raw_key]:-1194}"

        local line_out
        printf -v line_out "%1s %4s [%1s] %-15s %-5s %-${fname_field_len}s\n" \
            "$mark" "$seq_str" "$r_val" "$ip_val" "$port_val" "$raw_key"
        new_buf+="$line_out"
    done < <(echo -e "$work_src")

    # 5. Final update and sync / 最終更新と保存
    MASTER_SERVERS_BUFFER="$new_buf"
    FVPN_UDP_COUNT=$udp_cnt
    FVPN_TCP_COUNT=$tcp_cnt
    FVPN_TOTAL_COUNT=$(( FVPN_UDP_COUNT + FVPN_TCP_COUNT ))

    build_active_servers
    sync_target_index_by_server
}

# ------------------------------------------------------------------------------
# load_master_servers_and_count
# Load master server buffer and count UDP/TCP/Total server numbers
# マスターバッファのロードとUDP/TCP/合計サーバー件数のカウント
# ------------------------------------------------------------------------------
load_master_servers_and_count() {
    if [ "${IS_FIRST_BOOT:-0}" -eq 1 ]; then
        MASTER_SERVERS_BUFFER=""
        FVPN_UDP_COUNT=0
        FVPN_TCP_COUNT=0
        FVPN_TOTAL_COUNT=0
        return 0
    fi

    if [ -z "$MASTER_SERVERS_BUFFER" ]; then
        MASTER_SERVERS_BUFFER="$(cat "${FILE_MASTER_SERVERS}" 2>/dev/null)"$'\n'
    fi

    local buf_len=${#MASTER_SERVERS_BUFFER}
    local offset=0 u_cnt=0 t_cnt=0
    local rec_sz=${RECORD_BYTE_SIZE}

    while [ "$offset" -lt "$buf_len" ]; do
        local rec="${MASTER_SERVERS_BUFFER:$offset:$rec_sz}"
        [ ${#rec} -lt $(( rec_sz - 8 )) ] && break

        local p_type="${rec:$OFFSET_PROTO:$LENGTH_PROTO}"
        [ "$p_type" = "u" ] && ((u_cnt++))
        [ "$p_type" = "t" ] && ((t_cnt++))

        offset=$(( offset + rec_sz ))
    done

    FVPN_UDP_COUNT=$u_cnt
    FVPN_TCP_COUNT=$t_cnt
    FVPN_TOTAL_COUNT=$(( FVPN_UDP_COUNT + FVPN_TCP_COUNT ))
}

# ==============================================================================
# Initialization & Boot Process Manager
# 初期化 & 起動プロセス管理
# ==============================================================================

init_boot_process() {
    # 1. Prepare physical directories / 物理ディレクトリの準備
    mkdir -p "${FVPN_DATA}" "${FVPN_LOGDIR}"

    # 2. Flag evaluation (Boot-time snapshot) / フラグ判定 (起動時点のスナップショット)
    if [ ! -f "${FILE_MASTER_SERVERS}" ]; then
        IS_FIRST_BOOT=1
    else
        IS_FIRST_BOOT=0
    fi

    local dl_dir
    dl_dir=$(get_download_dir)
    if [ -f "${dl_dir}/fastestvpn_ovpn.zip" ]; then
        HAS_UPDATE_ZIP=1
    else
        HAS_UPDATE_ZIP=0
    fi

    # 2.5 Boot-time self-healing (Cleanup residual rules if raw IP and disconnected)
    # 起動時セルフヒーリング (生IPかつ非VPN状態なら残存ルールを完全クリーンアップ)
    if is_network_online && ! ip link show tun0 >/dev/null 2>&1; then
        phy_disconnect >/dev/null 2>&1
    fi

    # 3. Load & count master servers using IS_FIRST_BOOT / IS_FIRST_BOOT を活用したカウント＆ロードの分岐
    load_master_servers_and_count

    # 4. Load configuration file (.ini) / 設定ファイル (.ini) の読み込み
    load_all_settings

    # 5. Boot-time update processing / 起動時アップデート処理
    # Skip update if IS_FIRST_BOOT=0 and HAS_UPDATE_ZIP=0
    if [ "$IS_FIRST_BOOT" -eq 0 ] && [ "$HAS_UPDATE_ZIP" -eq 0 ]; then
        update_servers "skip"
    else
        update_servers
    fi

    # 6. Reload buffer & rebuild active buffer post-update
    # アップデート後のバッファ再ロード ＆ アクティブバッファ構築
    if [ -f "${FILE_MASTER_SERVERS}" ]; then
        MASTER_SERVERS_BUFFER="$(cat "${FILE_MASTER_SERVERS}" 2>/dev/null)"$'\n'
    fi

    build_active_servers
    sync_target_index_by_server
}
