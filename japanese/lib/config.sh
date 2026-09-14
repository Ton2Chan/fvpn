#!/bin/bash
# ==============================================================================
# FVPN 共通設定・定数管理モジュール (lib/config.sh)
# Version : 0.1.0-dev
# ==============================================================================

# 0. ベースパス自動判定
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export FVPN_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"

# 1. 論理層
export CONNECT_MODE=1     # 1: 固定(FIX), 2: 順番(SEQ), 3: ランダム(RAND)
export PROTOCOL_MODE=0    # 0: MIX (UDP+TCP), 1: UDP専用, -1: TCP専用
export FILTER_LEVEL=1     # 1: 全表示, 0〜4: 評価フィルター

# 公式アップデートURL
export OFFICIAL_UPDATE_URL="${OFFICIAL_UPDATE_URL:-https://support.fastestvpn.com/download/fastestvpn_ovpn//}"

# 自動更新・タイマーデフォルト設定
export TIMEOUT_AUTO_UPDATE="${TIMEOUT_AUTO_UPDATE:-5}"
export TIMEOUT_MANUAL_UPDATE="${TIMEOUT_MANUAL_UPDATE:-15}"
export TIMEOUT_VPN_CONNECT="${TIMEOUT_VPN_CONNECT:-30}" # ★新設: VPN接続タイムアウト秒数 (デフォルト30秒)
export CURRENT_TIMEOUT="${TIMEOUT_MANUAL_UPDATE}"
export UPDATE_CHECK_INTERVAL=7     # 更新成功後の完全封印期間 (7日)
export UPDATE_RETRY_INTERVAL=1     # チェック失敗/未更新時のスキップ期間 (1日)

# ------------------------------------------------------------------------------
# データ構造仕様定数 (128バイト固定長バッファ定義)
# ------------------------------------------------------------------------------
# _ 0001 [2] 255.255.255.255 65535 u/australia-stream-udp.ovpn
# _    1 [2] 255.255.255.255 4443  u/australia-stream-udp.ovpn
# _    1 [2] 0.0.0.0         4443  u/australia-stream-udp.ovpn
# 0123456789012345678901234567890123456789
export RECORD_BYTE_SIZE=128      # 1レコードあたりの固定長バイト数

export MARK_NORMAL="_"           # 通常サーバーマーク
export MARK_ADDED="+"            # 新規追加サーバーマーク

export OFFSET_ADDED_MARK=0       # 新規追加マーク位置 ("_ " または "+ ")
export LENGTH_ADDED_MARK=1

export OFFSET_INDEX=2            # サーバー通し番号 (例: "   1")
export LENGTH_INDEX=4

export OFFSET_RATING=8           # 評価値 ("0"〜"4")
export LENGTH_RATING=1

export OFFSET_IP=11              # 例: プロトコル等の後ろの適切な位置
export LENGTH_IP=15              # 固定長 15バイト

export OFFSET_PORT=27            # ポート番号開始位置
export LENGTH_PORT=5             # ポート番号長 (固定5バイト)

export OFFSET_PROTO=33           # プロトコル種別 ("u" または "t") または合成ファイル名"u/australia-stream-udp.ovpn"など
export LENGTH_PROTO=1

export OFFSET_FNAME=35           # ファイル名 (例: "australia-stream-udp.ovpn")

# システム・デバッグ設定
export DEBUG="${DEBUG:-0}"       # 0: 無効, 1: 簡易デバッグ, 2: +詳細レジスタダンプ

# 2. 物理層 (ディレクトリ & ファイルパス抽象化)
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

# 物理層変数(外部参照用)
export AUTH_STATE=0  # 0: 未確認, 1: OK, -1: NG

# 物理層内部ステータス・制御用ファイルパス (統合)
export _PHY_STATE_FILE="${FVPN_DATA}/_phy_mode"
export _PHY_CONNECTED_SERVER_FILE="${FVPN_DATA}/_phy_connected_server"
export _PHY_PID_FILE="${FVPN_PID}"

# DNS保護・退避用ファイルパス (追加)
export FILE_RESOLV_CONF="/etc/resolv.conf"
export FILE_RESOLV_BACKUP="${FVPN_DATA}/resolv.conf.backup"
export FVPN_DNS_SERVER="10.8.8.8"

export FILE_INIT_MARK="${FILE_MASTER_SERVERS}"

export _UPDATE_WORK_DIR="${FVPN_DATA}/_update_staging"
export _UPDATE_READY_FLAG="${FVPN_DATA}/_update_ready"

# 3. オンメモリバッファ & 状態管理変数
export MASTER_SERVERS_BUFFER=""
export ACTIVE_SERVERS_BUFFER=""

# ★注目サーバー管理変数 (名前ベース追跡対応)
export TARGET_INDEX=-1           # 注目サーバーインデックス (-1: 未選択, 0〜: 有効インデックス)
export TARGET_SERVER=""          # 注目サーバー識別子名 (例: "u/australia-stream-udp.ovpn", 未選択は "")

# 起動状態判定用フラグ (初期化プロセス用スナップショット)
export IS_FIRST_BOOT=0      # 1: 初回起動 (.master_servers_fixed.txt が存在しない)
export HAS_UPDATE_ZIP=0     # 1: ダウンロードフォルダに fastestvpn_ovpn.zip が存在

# マスターサーバー件数 (マスターバッファ走査時にセット)
export FVPN_UDP_COUNT=0
export FVPN_TCP_COUNT=0
export FVPN_TOTAL_COUNT=0

# フィルター通過(アクティブ)サーバー件数
export ACTIVE_UDP_COUNT=0
export ACTIVE_TCP_COUNT=0
export ACTIVE_TOTAL_COUNT=0

export PARAM_UPDATE_TIMEOUT="${TIMEOUT_MANUAL_UPDATE}"

# 4. 物理環境保証
mkdir -p "$FVPN_DATA" "$FVPN_LOG"

# 評価データのエクスポート/インポート用共通ファイル名
FILE_RATINGS_EXPORT_NAME="fvpn_ratings.txt"
