#!/bin/bash
# ==============================================================================
# FVPN Common Configuration & Constant Management Module (lib/config.sh)
# Version : 0.1.0-dev
# ==============================================================================

# 0. Base Path Auto-determination
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export FVPN_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"

# 1. Logical Layer Settings
export CONNECT_MODE=1     # 1: Fixed (FIX), 2: Sequential (SEQ), 3: Random (RAND)
export PROTOCOL_MODE=0    # 0: MIX (UDP+TCP), 1: UDP Only, -1: TCP Only
export FILTER_LEVEL=1     # 1: Show All, 0-4: Rating Filter

# Official Update URL
export OFFICIAL_UPDATE_URL="${OFFICIAL_UPDATE_URL:-https://support.fastestvpn.com/download/fastestvpn_ovpn//}"

# Auto-update and Timer Default Settings
export TIMEOUT_AUTO_UPDATE="${TIMEOUT_AUTO_UPDATE:-5}"
export TIMEOUT_MANUAL_UPDATE="${TIMEOUT_MANUAL_UPDATE:-15}"
export TIMEOUT_VPN_CONNECT="${TIMEOUT_VPN_CONNECT:-30}" # VPN Connection Timeout in seconds (Default: 30s)
export CURRENT_TIMEOUT="${TIMEOUT_MANUAL_UPDATE}"
export UPDATE_CHECK_INTERVAL=7     # Full lock period after successful update (7 days)
export UPDATE_RETRY_INTERVAL=1     # Skip period on check failure or unupdated state (1 day)

# ------------------------------------------------------------------------------
# Data Structure Specifications (128-byte Fixed-length Buffer Definition)
# ------------------------------------------------------------------------------
# _ 0001 [2] 255.255.255.255 65535 u/australia-stream-udp.ovpn
# _    1 [2] 255.255.255.255 4443  u/australia-stream-udp.ovpn
# _    1 [2] 0.0.0.0         4443  u/australia-stream-udp.ovpn
# 0123456789012345678901234567890123456789
export RECORD_BYTE_SIZE=128      # Fixed length byte size per record

export MARK_NORMAL="_"           # Standard server mark
export MARK_ADDED="+"            # Newly added server mark

export OFFSET_ADDED_MARK=0       # Newly added mark position ("_ " or "+ ")
export LENGTH_ADDED_MARK=1

export OFFSET_INDEX=2            # Server sequential index (e.g., "   1")
export LENGTH_INDEX=4

export OFFSET_RATING=8           # Rating value ("0" to "4")
export LENGTH_RATING=1

export OFFSET_IP=11              # Target IP start position
export LENGTH_IP=15              # Fixed length: 15 bytes

export OFFSET_PORT=27            # Port number start position
export LENGTH_PORT=5             # Port number length (Fixed length: 5 bytes)

export OFFSET_PROTO=33           # Protocol type ("u" or "t") or composite path identifier
export LENGTH_PROTO=1

export OFFSET_FNAME=35           # File name (e.g., "australia-stream-udp.ovpn")

# System & Debug Settings
export DEBUG="${DEBUG:-0}"       # 0: Disabled, 1: Basic Debug, 2: + Detailed Register Dump

# 2. Physical Layer (Directory & File Path Abstractions)
export FVPN_DATA="${FVPN_HOME}/data"
export FVPN_LOG="${FVPN_HOME}/logs"
export FVPN_TCP="${FVPN_HOME}/tcp_files"
export FVPN_UDP="${FVPN_HOME}/udp_files"
export FVPN_TCP_DIR="${FVPN_TCP}"
export FVPN_UDP_DIR="${FVPN_UDP}"

export FILE_MASTER_SERVERS="${FVPN_DATA}/.master_servers_fixed.txt"
export FILE_SETTINGS_INI="${FVPN_DATA}/settings.conf"
export FVPN_SETTINGS="${FILE_SETTINGS_INI}"
export FVPN_AUTH="${FVPN_DATA}/auth.conf"
export FVPN_PID="${FVPN_DATA}/fvpn.pid"
export FVPN_LOGFILE="${FVPN_LOG}/fvpn.log"

# Physical Layer Variables (For external reference)
export AUTH_STATE=0  # 0: Unverified, 1: OK, -1: NG

# Internal Physical Layer Status & Control File Paths
export _PHY_STATE_FILE="${FVPN_DATA}/_phy_mode"
export _PHY_CONNECTED_SERVER_FILE="${FVPN_DATA}/_phy_connected_server"
export _PHY_PID_FILE="${FVPN_PID}"

# DNS Protection & Backup File Paths
export FILE_RESOLV_CONF="/etc/resolv.conf"
export FILE_RESOLV_BACKUP="${FVPN_DATA}/resolv.conf.backup"
export FVPN_DNS_SERVER="10.8.8.8"

export FILE_INIT_MARK="${FILE_MASTER_SERVERS}"

export _UPDATE_WORK_DIR="${FVPN_DATA}/_update_staging"
export _UPDATE_READY_FLAG="${FVPN_DATA}/_update_ready"

# 3. In-Memory Buffers & State Management Variables
export MASTER_SERVERS_BUFFER=""
export ACTIVE_SERVERS_BUFFER=""

# Featured Server Management Variables (Name-based Tracking)
export TARGET_INDEX=-1           # Target server index (-1: Unselected, 0+: Valid Index)
export TARGET_SERVER=""          # Target server identifier name (e.g., "u/australia-stream-udp.ovpn", Unselected: "")

# Boot State Determination Flags (Snapshot for Initialization Process)
export IS_FIRST_BOOT=0      # 1: First Boot (.master_servers_fixed.txt does not exist)
export HAS_UPDATE_ZIP=0     # 1: fastestvpn_ovpn.zip exists in download folder

# Master Server Counts (Set during Master Buffer scan)
export FVPN_UDP_COUNT=0
export FVPN_TCP_COUNT=0
export FVPN_TOTAL_COUNT=0

# Filtered (Active) Server Counts
export ACTIVE_UDP_COUNT=0
export ACTIVE_TCP_COUNT=0
export ACTIVE_TOTAL_COUNT=0

export PARAM_UPDATE_TIMEOUT="${TIMEOUT_MANUAL_UPDATE}"

# 4. Physical Environment Guarantee
mkdir -p "$FVPN_DATA" "$FVPN_LOG"

# Common File Name for Rating Export/Import
FILE_RATINGS_EXPORT_NAME="fvpn_ratings.txt"
