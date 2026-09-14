#!/bin/bash
# ==============================================================================
# FVPN - Menu & User Interaction Module (UI & Interaction Layer)
# ==============================================================================

# ------------------------------------------------------------------------------
# Display Menu Footer / Status Header
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

    # Strictly fixed column format based on 123456 rule
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

    # Determine Authentication Status
    local auth_status="Auth:[--]"
    local state="${AUTH_STATE:-0}"

    if [ "$state" -gt 0 ]; then
        # Positive integer: Auth OK (1, 2, ...)
        auth_status="Auth:[OK]"
    elif [ "$state" -lt 0 ]; then
        # Negative integer: Auth NG (-1, -2, ...)
        auth_status="Auth:[NG]"
    else
        # 0: Unconfirmed / Initial state
        auth_status="Auth:[--]"
    fi

    # Output First Half Header (VPN  fix  lock [off] Auth:[NG] )
    printf "VPN %s%s%s %s" "$fix_str" "$lock_str" "$state_str" "$auth_status"
    echo ""

    # Second Half (Generic 1-line server display: Output target server if no argument)
    get_server_info_line

    echo ""
    echo "-------------------------------------------"
}

# ==============================================================================
# Connection Processing with UI Messages
# ==============================================================================

# ------------------------------------------------------------------------------
# Master Index Connection Function with Output Messages
# Argument: $1 = 0-based Master Index
# Return: 0: Success / Non-zero: Failure
# ------------------------------------------------------------------------------
connect_by_master_index_wm() {
    local m_idx="$1"

    # Invoke intermediate connection function (delegating all execution)
    connect_by_master_index "$m_idx"
    local res=$?

    # --- Connection Result Messages ---
    echo ""
    if [ "$res" -eq 0 ]; then
        echo " ✓ VPN connection established successfully."
    else
        echo " ❌ VPN connection failed."
        echo " 🔒 Traffic protected by Kill Switch (LOCKDOWN)"
    fi

    return $res
}

# ------------------------------------------------------------------------------
# 1) VPN Disconnection Process (Single/Deterministic Sequence : Menu 2)
# ------------------------------------------------------------------------------
disconnect_vpn() {
    echo "Executing VPN disconnection..."

    # Call physical layer disconnect and verification sequence
    if phy_disconnect; then
        # On success, invoke cleanup via intermediate layer to confirm teardown
        phy_cleanup_if_disconnected
        echo "✓ Restored direct raw IP connection."
        return 0
    else
        echo "❌ Failed to stop physical process."
        return 1
    fi
}

# ------------------------------------------------------------------------------
# 2) Pre-Exit Phase Control (Confirmation Dialog & VPN Teardown)
# ------------------------------------------------------------------------------
exit_fvpn() {
    local current_mode
    current_mode=$(get_phy_mode)

    # Prompt confirmation dialog only if connected or locked down
    if [ "$current_mode" != "DISCONNECTED" ]; then
        echo ""
        echo "⚠️  VPN is currently connected (or traffic is locked)."
        read -rp "Disconnect VPN and exit? [y/N]: " ans

        case "$ans" in
            [yY]|[yY][eE][sS])
                disconnect_vpn
                ;;
            *)
                echo "Maintaining VPN protection state (Kill Switch)."
                ;;
        esac
    else
        # Fallback cleanup if disconnected
        phy_cleanup_if_disconnected
    fi
}

# ==============================================================================
# Quick Connection Settings UI & Submenu Functions
# ==============================================================================

# 1) Connection Mode Settings
configure_connect_mode() {
    local m_opt
    echo
    echo "1: Fixed Access (Always connect to currently selected target server)"
    echo "2: Sequential Access (Rotate to next server on each connection)"
    echo "3: Random Access (Auto-select from filtered candidates each time)"
    read -rp "Select mode [1-3]: " m_opt
    case "$m_opt" in
        1|2|3)
            CONNECT_MODE="$m_opt"
            ;;
    esac
}

# 2) Protocol Mode Settings
configure_protocol_mode() {
    local p_opt
    echo
    echo "1: UDP only (Fast / Recommended)"
    echo "2: TCP only (Stability focused)"
    echo "3: Mix (Select from both UDP and TCP)"
    read -rp "Select protocol [1-3]: " p_opt
    case "$p_opt" in
        1) set_protocol_mode 1 ;;
        2) set_protocol_mode -1 ;;
        3) set_protocol_mode 0 ;;
        *) return ;;
    esac

    # Rebuild active server list matching active protocol
    build_active_servers
    sync_target_index_by_server
}

# 3) Filter Level Settings
configure_filter_level() {
    local f_val
    echo
    echo "--- Select Connection Filter Level ---"
    echo " 4)  [4] 3  2  1  0  : Select Rating 4 (Favorites) only"
    echo " 3)  [4  3] 2  1  0  : Select Rating 3 (Good) or higher"
    echo " 2)  [4  3  2] 1  0  : Select Rating 2 (Standard/Unrated) or higher"
    echo " 1)  [4  3  2  1] 0  : Select Rating 1 (Fair) or higher"
    echo " 0)  [4  3  2  1  0] : Select all servers"
    echo "---------------------------------------------------"
    read -rp "Select level [0-4 / Press Enter to go back]: " f_val
    if [ -n "$f_val" ] && [[ "$f_val" =~ ^[0-4]$ ]]; then
        FILTER_LEVEL="$f_val"
        build_active_servers
        sync_target_index_by_server
    fi
}

# Core Server List Update
update_servers() {
    local mode="${1:-force}"
    local base_dir="${FVPN_HOME:-.}"
    local data_dir="${FVPN_DATA:-${base_dir}/data}"
    local work_zip="${data_dir}/fastestvpn_ovpn.zip"

    local dl_dir
    dl_dir=$(get_download_dir)
    local local_zip="${dl_dir}/fastestvpn_ovpn.zip"
    local local_bak="${dl_dir}/fastestvpn_ovpn.zip.bak"

    # 1. If manual update zip exists locally (evaluated via startup flag)
    if [ "$HAS_UPDATE_ZIP" -eq 1 ]; then
        mkdir -p "$data_dir"
        cp -f "$local_zip" "$work_zip"
        mv -f "$local_zip" "$local_bak"
        HAS_UPDATE_ZIP=0  # Clear flag after processing
    else
        # 2. Network download evaluation
        # Skip auto-update if offline (non-zero) or during LOCKDOWN
        if ! is_network_online || [ "$(get_phy_mode)" = "LOCKDOWN" ]; then
            echo "Cannot connect to the network."
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
            echo "⚠️ Failed to download update file."
            return 1
        fi
    fi

    if ! apply_work_zip_package; then
        echo "⚠️ Failed to apply update package."
        return 1
    fi

    local default_mark="${MARK_ADDED:-+}"
    if [ "${FVPN_TOTAL_COUNT}" -eq 0 ]; then
        default_mark="${MARK_NORMAL:-_}"
    fi

    build_master_servers "$default_mark"

    echo "✓ Server list updated successfully."
    return 0
}

# ==============================================================================
# Export Rating Data (Full Export with Fixed Format Output)
# ==============================================================================
export_server_ratings() {
    local target_dir
    target_dir=$(get_download_dir)

    if [ ! -d "$target_dir" ]; then
        mkdir -p "$target_dir" 2>/dev/null || {
            echo "Error: Failed to create target directory ($target_dir)."
            return 1
        }
    fi

    if [ -z "$MASTER_SERVERS_BUFFER" ]; then
        echo "Error: No server data available to export."
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

        # Strip trailing newline to get 128-byte raw line
        local line="${rec%$'\n'}"
        # Trim trailing spaces
        line="${line%"${line##*[![:space:]]}"}"

        if [ -n "$line" ]; then
            printf "%s\n" "$line" >> "$tmp_file"
            ((exported_count++))
        fi

        offset=$((offset + RECORD_BYTE_SIZE))
    done

    if [ "$exported_count" -gt 0 ]; then
        mv "$tmp_file" "$export_file"
        echo "✓ Exported ${exported_count} server rating records."
        echo "  Output location: ${export_file}"
    else
        rm -f "$tmp_file"
        echo "Error: No data available for export."
    fi

    return 0
}

# ==============================================================================
# Import Rating Data (Direct In-Memory Replacement using Constants)
# ==============================================================================
import_server_ratings() {
    local target_dir
    target_dir=$(get_download_dir)

    local import_file="${target_dir}/${FILE_RATINGS_EXPORT_NAME:-fvpn_ratings.txt}"

    if [ ! -f "$import_file" ]; then
        echo "Error: Import target file not found."
        echo "  Checked path: ${import_file}"
        return 1
    fi

    if [ -z "$MASTER_SERVERS_BUFFER" ]; then
        build_master_servers
    fi

    echo "Importing server rating data..."

    # 1. Bulk load import file into associative array (O(N))
    declare -A import_map
    local loaded_count=0
    local line

    while IFS= read -r line || [ -n "$line" ]; do
        [ ${#line} -lt 14 ] && continue

        # Extract fields using constants from config.sh
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
        echo "Warning: No valid rating data found in import file."
        return 1
    fi

    # 2. In-place modification of rating values directly inside MASTER_SERVERS_BUFFER
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

        # Check if target key exists in import map
        if [ -n "${import_map[$key]+exists}" ]; then
            local new_r="${import_map[$key]}"
            local current_r="${rec:${OFFSET_RATING}:${LENGTH_RATING}}"

            # Perform in-place slice replacement only if rating differs
            if [ "$current_r" != "$new_r" ]; then
                local target_idx=$((offset + ${OFFSET_RATING}))
                
                # Overwrite only the 10th byte byte-slice (Avoids full string rebuild/re-concatenation)
                MASTER_SERVERS_BUFFER="${MASTER_SERVERS_BUFFER:0:$target_idx}${new_r}${MASTER_SERVERS_BUFFER:$((target_idx + 1))}"
                ((updated_count++))
            fi
        fi

        offset=$((offset + rec_size))
    done

    # 3. Save and sync active servers only if modifications occurred
    if [ "$updated_count" -gt 0 ]; then
        build_active_servers
        sync_target_index_by_server
        echo "✓ Imported ${updated_count} server rating records."
    else
        echo "Info: No changes found in rating data."
    fi

    return 0
}

# ==============================================================================
# Quick Connection Logic & Calculation Processing
# ==============================================================================

# Core Quick Connection Function
quick_connect() {
    local N="${ACTIVE_TOTAL_COUNT}"

    if [ "$N" -le 0 ]; then
        echo "❌ No available servers passed the connection filter."
        return 1
    fi

    # In-memory calculation of TARGET_INDEX based on selected mode
    case "${CONNECT_MODE}" in
        2) # SEQ (Sequential)
            TARGET_INDEX=$(( (TARGET_INDEX + 1) % N ))
            ;;
        3) # RANDOM
            local r=$(( RANDOM % N ))
            [ "$r" -eq "$TARGET_INDEX" ] && r=$(( (r + 1) % N ))
            TARGET_INDEX="$r"
            ;;
        1|*) # FIXED
            (( TARGET_INDEX < 0 )) && TARGET_INDEX=0
            ;;
    esac
    update_target_server_by_index

    # Retrieve 0-based master index from determined TARGET_INDEX
    local m_idx
    m_idx=$(get_target_master_index)

    # Display selected target server
    local display_info
    display_info=$(get_server_info_line "$TARGET_INDEX")
    echo "${display_info}"

    # Execute VPN connection (Delegated to UI-integrated connection function with output messages)
    connect_by_master_index_wm "$m_idx"
    return $?
}

# Quick Connection Settings Submenu
show_quick_connect_settings() {
    while true; do
        local mode_disp proto_disp filter_disp

        # 1) Connection Mode Display (1: FIXED / 2: SEQ / 3: RANDOM)
        case "${CONNECT_MODE}" in
            1) mode_disp="[1:FIXED] 2:SEQ  3:RANDOM" ;;
            2) mode_disp=" 1:FIXED [2:SEQ] 3:RANDOM" ;;
            3) mode_disp=" 1:FIXED  2:SEQ [3:RANDOM]" ;;
            *) mode_disp="[1:FIXED] 2:SEQ  3:RANDOM" ;;
        esac

        # 2) Protocol Mode Display (Positive: UDP / Negative: TCP / 0: MIX)
        local p="${PROTOCOL_MODE}"
        if (( p > 0 )); then
            proto_disp="[1:UDP]  2:TCP  3:MIX"
        elif (( p < 0 )); then
            proto_disp="1:UDP  [2:TCP]  3:MIX"
        else
            proto_disp="1:UDP  2:TCP  [3:MIX]"
        fi

        # 3) Filter Level Display
        case "${FILTER_LEVEL}" in
            4) filter_disp="[4] 3  2  1  0" ;;
            3) filter_disp="[4  3] 2  1  0" ;;
            2) filter_disp="[4  3  2] 1  0" ;;
            1) filter_disp="[4  3  2  1] 0" ;;
            0) filter_disp="[4  3  2  1  0]" ;;
            *) filter_disp="[4  3  2] 1  0" ;;
        esac

        echo
        echo "========== Quick Connection Settings =========="
        echo " 1) Change Connection Mode   : ${mode_disp}"
        echo " 2) Change Protocol Mode     : ${proto_disp}"
        echo " 3) Filter Level             : ${filter_disp}"
        echo " 0) Back (Press Enter to return)"
        echo "-----------------------------------------------"
        read -p "Select option [0]: " q_choice
        q_choice="${q_choice:-0}"

        case "$q_choice" in
            1) configure_connect_mode ;;
            2) configure_protocol_mode ;;
            3) configure_filter_level ;;
            0) break ;;
            *) echo "Invalid choice." ;;
        esac
    done
}

# ==============================================================================
# Server Management, Rating UI & Submenu Functions
# ==============================================================================

reset_ratings_menu() {
    echo ""
    read -p "Reset all server ratings to default (2)? (y/N): " confirm
    case "$confirm" in
        [yY]|[yY][eE][sS])
            if reset_server_ratings; then
                echo "✓ Processing completed. (Filter level reset to 0)"
            fi
            ;;
        *)
            echo "Operation canceled."
            ;;
    esac
}

# ------------------------------------------------------------------------------
# Individual Server Rating Setup Dialog (UI Layer)
# ------------------------------------------------------------------------------
manage_protocol_servers() {
    local target_proto="$1" # "u" or "t"
    local proto_label="UDP"
    [ "$target_proto" = "t" ] && proto_label="TCP"

    local record_size=${RECORD_BYTE_SIZE}
    local udp_cnt="${FVPN_UDP_COUNT}"
    local tcp_cnt="${FVPN_TCP_COUNT}"

    local max_num=$udp_cnt
    if [ "$target_proto" = "t" ]; then
        max_num=$tcp_cnt
    fi

    [ "$max_num" -le 0 ] && { echo "(No matching ${proto_label} servers found)"; return 0; }

    # 1. Print list table once initially
    echo ""
    echo "========== ${proto_label} Server List & Rating Settings =========="
    
    local base_index
    base_index=$(get_master_index "$target_proto" 1)
    local start_byte=$(( base_index * record_size ))
    local total_bytes=$(( max_num * record_size ))
    local sub_buf="${MASTER_SERVERS_BUFFER:$start_byte:$total_bytes}"

    # Trim trailing whitespace and output batch list
    printf '%s' "$sub_buf" | sed 's/[[:space:]]*$//'

    echo "=================================================="
    echo " Rating Legend: 4:Favorite, 2:Unrated, 1:Fair, 3:Good, 0:Excluded"
    echo "--------------------------------------------------"

    # 2. Rating modification input loop
    while true; do
        read -rp "Select server number to change rating [Enter or 0 to return]: " num_input

        [ -z "$num_input" ] || [ "$num_input" = "0" ] && break

        # Range validation
        if [[ ! "$num_input" =~ ^[1-9][0-9]*$ ]] || [ "$num_input" -gt "$max_num" ]; then
            echo "⚠️ Please enter a number between 1 and ${max_num}."
            continue
        fi

        # Calculate master index from 1-based intra-protocol number
        local target_master_idx
        target_master_idx=$(get_master_index "$target_proto" "$num_input")

        echo "$(get_master_server_info_line "$target_master_idx")"
        read -rp "Enter new rating [0-4]: " new_rate
        if [[ ! "$new_rate" =~ ^[0-4]$ ]]; then
            echo "⚠️ Please enter a value between 0 and 4."
            continue
        fi

        # Update rating and display updated record line
        update_server_rating_by_master_index "$target_master_idx" "$new_rate"
        echo "$(get_master_server_info_line "$target_master_idx")"
        echo ""
    done
}

# ------------------------------------------------------------------------------
# Direct Server Selection & Connection
# ------------------------------------------------------------------------------
select_vpn_server() {
    local target_proto=""

    # --- 1. Protocol selection loop ---
    while true; do
        echo -e "\n========== Direct Server Selection & Connection =========="
        echo " 1) UDP"
        echo " 2) TCP"
        echo " 0) Back (Press Enter to return)"
        read -rp "Select [0-2]: " p_choice

        case "$p_choice" in
            1) target_proto="u"; break ;;
            2) target_proto="t"; break ;;
            0|"") echo "Operation canceled."; return 0 ;;
            *) echo "⚠️ Invalid choice. Please enter a value between 0 and 2." ;;
        esac
    done

    # --- 2. Check matching count ---
    local target_count=0
    if [ "$target_proto" = "u" ]; then
        target_count="${ACTIVE_UDP_COUNT}"
    else
        target_count="${ACTIVE_TCP_COUNT}"
    fi

    if [ "$target_count" -le 0 ]; then
        echo "⚠️ No servers passed filter for selected protocol (${target_proto^^})."
        return 0
    fi

    # --- 3. Slice and display filtered server buffer for target protocol ---
    echo ""
    echo "--- Available Server List (${target_proto^^} : ${target_count} items) ---"

    local start_offset=0
    [ "$target_proto" = "t" ] && start_offset=$(( ${ACTIVE_UDP_COUNT} * RECORD_BYTE_SIZE ))
    local total_bytes=$(( target_count * RECORD_BYTE_SIZE ))

    local sub_buf="${ACTIVE_SERVERS_BUFFER:$start_offset:$total_bytes}"
    printf '%s\n' "$sub_buf" | sed 's/[[:space:]]*$//'

    # --- 4. Server selection and prompt loop ---
    local match_target_index=-1
    local target_master_idx=-1
    local s_num=""

    while true; do
        read -rp "Enter server number to connect (0 to return): " s_num

        # Cancel on 0 or empty input
        if [ -z "$s_num" ] || [ "$s_num" -eq 0 ] 2>/dev/null; then
            echo "Operation canceled."
            return 0
        fi

        # Numeric check
        if ! [[ "$s_num" =~ ^[1-9][0-9]*$ ]]; then
            echo "⚠️ Invalid input. Please enter a valid number."
            continue
        fi

        # Search matching server in active PASS buffer
        match_target_index=-1
        target_master_idx=-1
        local i=0

        while [ "$i" -lt "$target_count" ]; do
            local current_offset=$(( start_offset + (i * RECORD_BYTE_SIZE) ))
            local rec="${ACTIVE_SERVERS_BUFFER:$current_offset:RECORD_BYTE_SIZE}"

            # Extract intra-protocol sequence number from record field (OFFSET_INDEX:LENGTH_INDEX)
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

        # Exit loop and connect if found
        if [ "$target_master_idx" -ge 0 ]; then
            break
        fi

        # Show warning and retry on mismatch
        echo "⚠️ Server number [ ${s_num} ] is not available in filtered ${target_proto^^} list."
    done

    # Sync target server index
    TARGET_INDEX="$match_target_index"
    update_target_server_by_index

    # --- 5. Connection execution via unified UI connection handler ---
    get_server_info_line
    echo ""
    connect_by_master_index_wm "$target_master_idx"
    return $?
}

# ------------------------------------------------------------------------------
# Server Management & Rating Submenu
# ------------------------------------------------------------------------------
show_rating_menu() {
    while true; do
        echo ""
        echo "========== Server Management & Rating Menu =========="
        echo " 1) UDP Server List & Rating Settings"
        echo " 2) TCP Server List & Rating Settings"
        echo " 3) Export Server Ratings"
        echo " 4) Import Server Ratings"
        echo " 5) Reset All Ratings"
        echo " 6) Update Server List"
        echo " 7) Configure VPN Connection Timeout"
        echo " 0) Back (Press Enter to return)"
        echo "------------------------------------------------------"
        read -rp "Select [0]: " rm_choice
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
            *) echo "Invalid choice." ;;
        esac
    done
}

configure_vpn_timeout() {
    local t_val
    echo
    echo "--- Configure VPN Connection Timeout ---"
    echo " Current value: ${TIMEOUT_VPN_CONNECT} seconds"
    read -rp "Enter new timeout in seconds [1-120 / Press Enter to go back]: " t_val
    if [[ "$t_val" =~ ^[0-9]+$ ]] && [ "$t_val" -ge 1 ] && [ "$t_val" -le 120 ]; then
        TIMEOUT_VPN_CONNECT="$t_val"
        save_all_settings
        echo "✓ Connection timeout set to ${TIMEOUT_VPN_CONNECT} seconds."
    fi
}

#
# Initial Setup (Permission Grant & Auth Credentials Configuration)
#
permission_setup() {
    local data_dir="${FVPN_DATA:-$HOME/VPN/FastestVPN/data}"
    local auth_file="$data_dir/auth.conf"

    echo
    echo "=== Initial Setup (Permissions & Credentials) ==="

    if [ "$DEBUG" = "1" ]; then
        echo "[DEBUG] FVPN_DATA = $data_dir"
        echo "[DEBUG] AUTH_FILE = $auth_file"
    fi

    #
    # 1. Directory and permission setup
    #
    echo "1. Setting up directories and permissions..."
    if [ ! -d "$data_dir" ]; then
        mkdir -p "$data_dir"
        echo "   ✓ Created data directory: $data_dir"
    else
        echo "   ✓ Data directory verified"
    fi
    chmod 700 "$data_dir" 2>/dev/null
    echo "   ✓ Permission setup completed"

    #
    # 2. Authentication credentials (ID/PASS) configuration
    #
    echo
    echo "2. Configure Authentication Credentials (ID/PASS)"

    local current_user=""
    local current_pass=""

    # Read existing credentials from auth.conf
    if [ -f "$auth_file" ]; then
        current_user=$(sed -n '1p' "$auth_file")
        current_pass=$(sed -n '2p' "$auth_file")
        echo "   (Current user: ${current_user:-Unset})"
        echo "   * Press Enter to keep existing values for unchanged fields."
    fi

    echo
    read -rp "Username (ID) [${current_user:-Unset}]: " input_user
    read -s -rp "Password: " input_pass
    echo

    # Keep existing value if input is empty, require input if unset
    local final_user="${input_user:-$current_user}"
    local final_pass="${input_pass:-$current_pass}"

    if [ -z "$final_user" ] || [ -z "$final_pass" ]; then
        echo "Error: Username or Password is empty. Skipped saving credentials."
        return 1
    fi

    # Write auth.conf (Permissions: 600)
    {
        echo "$final_user"
        echo "$final_pass"
    } > "$auth_file"

    chmod 600 "$auth_file"

    echo "✓ Credentials saved: $auth_file"
    echo "Initial setup completed successfully."
    return 0
}

#
# Cleanup Process (Cleanup PID & Teardown Temporary Artifacts)
#
permission_cleanup() {
    local data_dir="${FVPN_DATA:-$HOME/VPN/FastestVPN/data}"
    local pid_file="$data_dir/fvpn.pid"
    local auth_file="$data_dir/auth.conf"

    echo
    echo "=== Teardown & Cleanup Process ==="

    if [ "$DEBUG" = "1" ]; then
        echo "[DEBUG] PID_FILE = $pid_file"
        echo "[DEBUG] AUTH_FILE = $auth_file"
    fi

    local cleaned=0

    # 1. Remove residual PID files
    if [ -f "$pid_file" ]; then
        local pid
        pid=$(cat "$pid_file" 2>/dev/null)
        rm -f "$pid_file"
        echo "✓ Removed residual PID file (PID: ${pid:-Unknown})"
        cleaned=1
    fi

    if [ "$cleaned" -eq 0 ]; then
        echo "✓ No residual files requiring cleanup were found."
    fi

    echo "Cleanup process completed."
    return 0
}

# ------------------------------------------------------------------------------
# Setup & Cleanup Submenu
# ------------------------------------------------------------------------------
show_setup_cleanup_menu() {
    while true; do
        echo ""
        echo "========== Setup & Teardown Settings =========="
        echo " 1) Initial Setup (Permissions & Auth) * Run this before first use."
        echo " 2) Cleanup & Reset Permissions * Run this before removing this app."
        echo " 0) Back (Press Enter to return)"
        echo "-----------------------------------------------"
        read -rp "Select [0]: " sc_choice
        sc_choice="${sc_choice:-0}"

        case "$sc_choice" in
            1) permission_setup ;;
            2) permission_cleanup ;;
            0) break ;;
            *) echo "Invalid choice." ;;
        esac
    done
}

# ==============================================================================
# Main Menu Display & Interaction Loop
# ==============================================================================
show_main_menu() {
    while true; do
        show_debug_registers

        echo "========== FVPN v1.0.0 by Ton2Chan =========="
        echo " 1) Quick VPN Connect (Connect to target server)"
        echo " 2) Disconnect VPN"
        echo " 3) Select Server & Connect"
        echo " 4) Quick Connection Settings (Mode, Protocol, Filter)"
        echo " 5) Server Management, Rating & Updates"
        echo " 9) Setup & Teardown (Permissions & Auth)"
        echo " 0) Exit"
        echo "-------------------------------------------"
        show_status_header
        
        read -rp "Please select [0-9]: " choice

        case "$choice" in
            1) quick_connect ;;
            2) disconnect_vpn ;;
            3) select_vpn_server ;;
            4) show_quick_connect_settings ;;
            5) show_rating_menu ;;
            9) show_setup_cleanup_menu ;;
            0)
                # 1. Confirm disconnection and cleanup if currently connected
                exit_fvpn

                # 2. Sync in-memory master buffer and settings to disk
                save_master_servers_buffer
                save_all_settings

                # 3. Final termination message
                echo "Exiting FVPN."
                break
                ;;
            *) echo "❌ Invalid option." ;;
        esac

        echo ""
    done
}
