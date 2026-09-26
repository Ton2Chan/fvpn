#!/bin/bash
# ==============================================================================
# FVPN - Connection Engine & Buffer Logic (Non-UI Core Operations)
# ==============================================================================

# Saved list of filtered servers for trap code handling
# printf "%s" "$ACTIVE_SERVERS_BUFFER" > "${FILE_ACTIVE_SERVERS:-./data/.active_servers_fixed.txt}"

# Network Connectivity Check (Silent Boolean Judgment Function)
is_network_online() {
    ip route show default 2>/dev/null | grep -q "default via"
    return $?  # 0: ONLINE, 1: OFFLINE
}

# ==============================================================================
# Intermediate Tunnel Function (Pure Bridge)
# ==============================================================================

phy_connect() {
    local target_path="$1"
    local s_ip="$2"
    local s_port="$3"
    local s_proto="$4"

    local auth_file="${FVPN_DATA:-./data}/auth.conf"
    local state_file="${FVPN_DATA:-./data}/_phy_mode"
    local conn_file="${FVPN_DATA:-./data}/_phy_connected_server"
    local pid_file="${FVPN_DATA:-./data}/fvpn.pid"
    local log_file="${FVPN_LOGDIR:-./logs}/openvpn.log"
    local timeout="${TIMEOUT_VPN_CONNECT:-30}"

    [ ! -f "$auth_file" ] && auth_file="./data/auth.conf"

    # Clean up existing OpenVPN process and TUN interface safely
    _phy_openvpn_kill
    _phy_tun_clear

    # Apply kill-switch rules prior to launching OpenVPN
    _phy_fw_killswitch "$s_ip" "$s_port" "$s_proto"

    > "$log_file" 2>/dev/null

    # Launch OpenVPN
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

        # 1. Successful VPN connection
        if _phy_tun_check; then
            echo "CONNECTED" > "$state_file" 2>/dev/null
            echo "$target_path" > "$conn_file" 2>/dev/null

            _phy_dns_apply

            export AUTH_STATE=1
            return 0
        fi

        # 2. OpenVPN Process Liveness Check
        #
        # _phy_openvpn_start() creates the PID file first,
        # so skip checking if the file is empty right after startup.
        if [ -s "$pid_file" ]; then
            local openvpn_pid
            openvpn_pid=$(cat "$pid_file" 2>/dev/null)

            if [[ "$openvpn_pid" =~ ^[0-9]+$ ]] &&
               [ "$openvpn_pid" -gt 0 ]; then

                local proc_cmdline
                proc_cmdline=$(tr '\0' ' ' < "/proc/$openvpn_pid/cmdline" 2>/dev/null)

                # Process missing or PID recycled by another application
                if [ -z "$proc_cmdline" ] ||
                   [[ "$proc_cmdline" != *openvpn* ]]; then

                    echo -e "\n[Warning] Detected OpenVPN process disappearance or unexpected termination."
                    ret_code=1
                    break
                fi
            fi
        fi

        # 3. Authentication failure detection
        #
        # Avoid 'grep -q' as it may trigger SIGPIPE on 'tail' when pipefail is enabled.
        # Redirect output to /dev/null instead.
        if [ -s "$log_file" ] &&
           tail -c 8192 "$log_file" 2>/dev/null |
           grep -a "AUTH_FAILED" >/dev/null 2>&1; then

            export AUTH_STATE=-1
            ret_code=2
            break
        fi

        # 4. Communication error (rapid loop indicator) watchdog
        #
        # 'grep -q' is omitted here as well for safety.
        if [ -s "$log_file" ] &&
           tail -c 8192 "$log_file" 2>/dev/null |
           grep -a -E \
           'Operation not permitted|File descriptor in bad state' >/dev/null 2>&1; then

            echo -e "\n[Warning] OpenVPN communication error (rapid loop indicator) detected. Terminating process."
            ret_code=1
            break
        fi

        echo -n "."
        sleep 1
    done

    echo ""

    # Common cleanup sequence upon connection failure or unexpected termination
    _phy_openvpn_kill
    _phy_tun_clear

    # Safely restore kill-switch state
    _phy_fw_killswitch "$s_ip" "$s_port" "$s_proto"

    echo "LOCKDOWN" > "$state_file" 2>/dev/null
    rm -f "$conn_file" "$pid_file" 2>/dev/null

    return "$ret_code"
}

# ==============================================================================
# General Utilities Related to 0-Start Server Index (Master Index)
# ==============================================================================

# ------------------------------------------------------------------------------
# Calculate 0-start Master Index from protocol type and intra-protocol index
# Arguments: $1 = Protocol Type ("u" or "t"), $2 = Intra-protocol Index (1+)
# Output: 0-start Master Index
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
# Retrieve 0-start Master Index from Target Server (TARGET_INDEX)
# Output: Master Index (0 or higher), -1 on error
# ------------------------------------------------------------------------------
get_target_master_index() {
    local target_idx="${TARGET_INDEX}"
    local total="${ACTIVE_TOTAL_COUNT}"

    if [ "$total" -le 0 ] || [ "$target_idx" -lt 0 ] || [ "$target_idx" -ge "$total" ]; then
        echo "-1"
        return 1
    fi

    # Extract 1 record (RECORD_BYTE_SIZE = 128 bytes)
    local rec_size="${RECORD_BYTE_SIZE}"
    local offset=$(( target_idx * rec_size ))
    local rec="${ACTIVE_SERVERS_BUFFER:$offset:$rec_size}"

    # Extract fields based on constants
    local p_type="${rec:$OFFSET_PROTO:$LENGTH_PROTO}"
    local num_str="${rec:$OFFSET_INDEX:$LENGTH_INDEX}"
    num_str=$(echo "$num_str" | xargs) # Trim whitespace

    # Delegate to master index calculation
    get_master_index "$p_type" "$num_str"
}

# ------------------------------------------------------------------------------
# Unified Rating Update Process by Master Index
# Arguments: $1 = master_index, $2 = new_rating (0-4)
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

    # Pinpoint overwrite of rating value (1 char) in master buffer
    MASTER_SERVERS_BUFFER="${MASTER_SERVERS_BUFFER:0:$target_off}${new_rate}${MASTER_SERVERS_BUFFER:$((target_off + 1))}"

    # Rebuild active server buffer
    build_active_servers
    sync_target_index_by_server

    return 0
}

# ==============================================================================
# VPN Connection Backend Functions (Non-interactive execution)
# ==============================================================================

# ------------------------------------------------------------------------------
# Unified Connection Function by 0-Start Master Index (Primary Connection Route)
# Arguments: $1 = master_index (0-start)
# Return: 0 = Success / -1 = Failure
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

    # Explicit protocol determination
    local s_proto="udp"
    local target_server=""
    if [ "$p_type" = "t" ]; then
        s_proto="tcp"
        target_server="${FVPN_TCP_DIR:-./tcp_files}/${fname}"
    else
        s_proto="udp"
        target_server="${FVPN_UDP_DIR:-./udp_files}/${fname}"
    fi

    # Execute physical layer connection
    phy_connect "$target_server" "$s_ip" "$s_port" "$s_proto"
    local phy_ret=$?

    local status=0
    [ "$phy_ret" -ne 0 ] && status=-1

    # Automatic update of rating value (Unrated: "2")
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
# Active (PASS) Server Buffer Generation
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
# Function: Retrieve specified 0-start Master Index server info line from
#           MASTER_SERVERS_BUFFER and output after trimming trailing whitespace.
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
# Function: Extract 128-byte fixed-length server record of specified index from
#           ACTIVE_SERVERS_BUFFER and output after trimming trailing spaces/newlines.
# ------------------------------------------------------------------------------
get_server_info_line() {
    local line
    local target_idx="${1:-${TARGET_INDEX:--1}}"

    local offset=$((target_idx * RECORD_BYTE_SIZE))
    if (( target_idx >= 0 )); then
        line="${ACTIVE_SERVERS_BUFFER:$offset:RECORD_BYTE_SIZE}"
    else
        line="Unselected"
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
    # Guard against 0 count: Never write to file if total count <= 0
    [ "${FVPN_TOTAL_COUNT:-0}" -le 0 ] && return 0

    local target_file="${FILE_MASTER_SERVERS}"
    LC_ALL=C printf "%s" "$MASTER_SERVERS_BUFFER" > "$target_file"
}

# ==============================================================================
# Target Server Name Management Utilities (TARGET_SERVER / TARGET_INDEX Sync)
# ==============================================================================

# ------------------------------------------------------------------------------
# update_target_server_by_index
# Function: Extract "u/filename" from TARGET_INDEX and set to TARGET_SERVER.
# ------------------------------------------------------------------------------
update_target_server_by_index() {
    [ "${TARGET_INDEX:--1}" -lt 0 ] && TARGET_SERVER="" && return 0

    # Extract fixed-width block from OFFSET_PROTO to EOL and trim trailing whitespace
    TARGET_SERVER="${ACTIVE_SERVERS_BUFFER:$(( TARGET_INDEX * RECORD_BYTE_SIZE + OFFSET_PROTO )):$(( RECORD_BYTE_SIZE - OFFSET_PROTO ))}"
    TARGET_SERVER="$(echo "$TARGET_SERVER" | xargs)"
}

# ------------------------------------------------------------------------------
# sync_target_index_by_server
# Function: Search for TARGET_SERVER within ACTIVE_SERVERS_BUFFER and restore TARGET_INDEX.
# ------------------------------------------------------------------------------
sync_target_index_by_server() {
    [ -z "$TARGET_SERVER" ] && TARGET_INDEX=-1 && return 0

    # Search for line number using TARGET_SERVER (e.g. u/australia-stream-udp.ovpn) (1-start)
    local line_num
    line_num=$(echo -n "$ACTIVE_SERVERS_BUFFER" | grep -F -n -m 1 "$TARGET_SERVER" | cut -d: -f1)

    if [ -n "$line_num" ]; then
        TARGET_INDEX=$(( line_num - 1 ))
    else
        TARGET_INDEX=-1
        TARGET_SERVER=""
    fi
}
