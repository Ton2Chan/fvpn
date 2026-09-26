# FVPN — Ultra-lightweight CLI for FastestVPN

**English | 日本語**

---

## English

`fvpn` is a lightweight and simple CLI VPN client developed to operate FastestVPN safely and comfortably in a Linux environment.

It is designed to be responsive with minimal code bloat, while featuring zero-vulnerability DNS leak protection and automatic startup cleanup (resetting leftover rules from abnormal exits).

### Core Architecture & Design Philosophy

#### Complete DNS Protection from the Very Start

Many standard VPN clients switch DNS settings only after the VPN server connection is established, creating a brief window where raw DNS traffic can leak.

`fvpn` strictly locks out DNS traffic from the very beginning of the connection sequence. Since it performs no external DNS queries during connection, raw IP or DNS information will never leak during reconnection from lockdown or server switching.

#### Full State Preservation of LOCKDOWN (Kill Switch)

Not only does it protect you when a VPN disconnects, but you can also safely exit the application with LOCKDOWN active, preserving that exact protection state on the next launch.

#### Startup Self-Healing (Auto-Cleanup)

Even if the previous session ended abnormally (such as sudden terminal closure or a crash), `fvpn` detects raw IP status upon launch and automatically initializes leftover rules and zombie processes.

### Key Features

- **Lightweight & Fast:** Resource-efficient compact design.
- **Modular UI:** Decoupled into inclusion files (`.shinc` / `.shlib`) to prevent execution collisions.
- **One-Touch Quick Connect:** Instantly connect to optimal nodes.
- **UDP / TCP Support:** Choose based on your network environment.
- **Flexible Auto-Update:** Adjustable intervals via `settings.conf`:

```ini
UPDATE_CHECK_INTERVAL=7
UPDATE_RETRY_INTERVAL=1
```

### Important Specification Notice

`fvpn` loads configuration files from the `data/` directory into memory upon startup, and writes them back to disk only when exiting.

If you manually edit configuration files (such as `settings.conf`), always do so while `fvpn` is completely closed.

### Prerequisites & Quick Start

**OS:** Linux (Ubuntu, Debian, Arch, etc.)

**Required Packages:** `openvpn`, `iptables`, `iproute2`, `sudo` privileges

```bash
git clone https://github.com/your-username/fvpn.git
cd fvpn
chmod +x fvpn
./fvpn
```

### AI Collaboration

This project was completed by the author (Ton2Chan) through architecture design and algorithmic leadership, with assistance from AI partners (Free Plans):

- **Gemini:** Code generation based on specified requirements, architecture advice, and debugging.
- **ChatGPT:** Early prototype creation, bug detection, and feature proposals.

### License & Copyright

Released under the MIT License.

**Copyright:** Copyright (c) 2026 Ton2Chan

---

# 日本語

`fvpn` は、Linux 環境で FastestVPN を安全かつ快適に運用するために開発された、軽量でシンプルな CLI（コマンドライン）VPN クライアントです。

コードの無駄を極力削ぎ落としたレスポンスの早い設計でありながら、一瞬の隙も許さない完全な DNS 漏洩保護と、起動時の自動クリーンアップ（異常終了時の残存ルール初期化）機能を備えています。

## 開発思想とアーキテクチャの核心

### 一般的な接続ツールの枠を超え、Linux のネットワークスタックにおける安全性の隙間を埋めることを目指して設計されています。

#### 接続開始から一瞬の隙も作らない「完全 DNS 保護」

一般的な VPN クライアントの多くは、VPN サーバーとの接続が確立された後に DNS 設定を切り替えるため、接続処理の初期段階で一時的に生の DNS トラフィックが漏洩するリスクが存在します。

`fvpn` では、接続シーケンスの最初から DNS トラフィックを厳格にロックアウトする設計を採用しています。

VPN 接続時に外部への DNS 問い合わせを一切行わない仕組みにしているため、ロックダウンからの接続時や VPN サーバー切り替え時の一瞬であっても、生 IP や DNS 情報が漏洩することはありません。

#### LOCKDOWN（キルスイッチ）の完全な状態維持

VPN 接続が切断された場合だけでなく、LOCKDOWN（キルスイッチ）が有効な状態のまま安全にアプリを終了し、次回もその保護状態のまま起動できます。

意図しない通信の漏洩を物理レベルで防ぎます。

#### 起動時の自動クリーンアップ（異常終了への対応）

前回のセッションが異常終了（端末の突然の終了やクラッシュ）した場合でも、次回起動時に生の IP 状態や残存した設定を検知し、残留ルールや不要プロセスを自動的に初期化します。

常にクリーンな状態からスタートできます。

## 主な特徴

- **軽量・高速動作:** 資源消費を抑えたコンパクトな設計。
- **モジュール化された UI:** 表示ロジックを独立した読み込みファイル（`.shinc` / `.shlib`）に分離し、誤動作や読み込み事故を防止。
- **ワンタッチ簡易接続:** 注目サーバーや最適なノードへ即座に接続。
- **UDP / TCP 対応:** ネットワーク環境に合わせて柔軟に選択可能。
- **自動更新制御:** `settings.conf` 内のパラメータで更新チェックの間隔を調整可能。

```ini
UPDATE_CHECK_INTERVAL=7
UPDATE_RETRY_INTERVAL=1
```

## 重要な仕様上の注意（設定ファイルについて）

`fvpn` は、起動時に `data/` ディレクトリ内の設定ファイルをメモリへ読み込み、プログラムの終了時のみファイルへの書き出し（更新）を行います。

手動で設定ファイル（`settings.conf` 等）を直接編集する場合は、必ず `fvpn` を終了した状態で行ってください。

> 実行中に編集すると、終了時に上書きされます。

## システム要件 & クイックスタート

**OS:** Linux (Ubuntu, Debian, Arch 等)

**必要パッケージ:** `openvpn`, `iptables`, `iproute2`, `sudo` 権限

```bash
git clone https://github.com/your-username/fvpn.git
cd fvpn
chmod +x fvpn
./fvpn
```

## 開発パートナー（AI の活用について）

本プロジェクトは、作者（Ton2Chan）によるアーキテクチャ設計およびアルゴリズムの指示のもと、以下の AI パートナー（無料プラン）の多大な協力を得て完成しました。

- **Gemini:** 指定された仕様・アルゴリズムに基づくコード生成、設計およびデバッグのサポート
- **ChatGPT:** 初期開発のプロトタイプ作成、バグ検出、機能提案

## ライセンスと著作権

本プロジェクトは MIT License のもとで公開されています。

**著作権表示:** Copyright (c) 2026 Ton2Chan
