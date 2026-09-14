# FVPN — Ultra-lightweight & Secure Linux CLI for FastestVPN

`fvpn` is an ultra-lightweight and robust CLI (command-line) VPN client developed to operate FastestVPN safely and comfortably in a Linux environment.

Designed to be **compact and responsive** with zero code bloat, it features **complete DNS leak protection** that leaves no vulnerabilities, alongside **self-healing capabilities** resilient to network disruptions.

---

## 💡 Core Architecture & Design Philosophy

`fvpn` was built to thoroughly eliminate safety loopholes within the Linux network stack, going beyond standard connection tools.

### 1. Zero-Vulnerability "Complete DNS Protection"

Many standard VPN clients switch DNS settings only after the VPN server connection is established. This creates a brief window where raw DNS traffic can leak during the initial connection phase (such as querying server IP addresses).

`fvpn` adopts a design—said to be used by a subset of advanced VPN applications—that **strictly locks out DNS traffic from the very beginning of the connection sequence**. By trading off support for silent server IP auto-updates, it prioritizes absolute security: **zero unencrypted DNS queries allowed from connection initiation all the way to disconnection.**

### 2. Full State Preservation of LOCKDOWN (Kill Switch)

Not only does it protect you when a VPN disconnects, but you can also **safely exit the application with LOCKDOWN (kill switch) active, and launch it next time while preserving that exact protection state.** This physically prevents unintended traffic leaks.

### 3. Startup Self-Healing (Auto-Cleanup)

Even if the previous session ended abnormally (e.g., sudden terminal closure or crash), `fvpn` detects raw IP status upon the next launch and automatically initializes leftover rules and zombie processes. You always start from a clean, stable state.

---

## ✨ Key Features

* **Ultra-lightweight & Fast**: Extremely responsive due to minimalist, resource-efficient code design.
* **One-Touch Quick Connect**: Instantly connect to featured servers or optimal nodes.
* **UDP / TCP Support**: Choose based on your usage and network environment.
* **Update Check Logic**:
* Skips auto-checks for 7 days after a server list update, then checks once daily thereafter.
* Adjust these intervals flexibly via parameters in `setting.ini`:
UPDATE_CHECK_INTERVAL=7
UPDATE_RETRY_INTERVAL=1



---

## ⚠️ Important Specification Notice (Configuration Files)

* `fvpn` **loads configuration files from the `data/` directory into memory upon startup, and writes (updates) them back to disk only when the program exits.**
* If you manually edit configuration files (such as `setting.ini`), **always do so while `fvpn` is completely closed.** (Edits made while running will be overwritten upon exit.)

---

## 🛠 Prerequisites

* **OS**: Linux (Ubuntu, Debian, Arch, etc.)
* **Required Packages**: openvpn, iptables, iproute2, sudo privileges

---

## 🚀 Quick Start

git clone [https://github.com/your-username/fvpn.git](https://www.google.com/search?q=https://github.com/your-username/fvpn.git)
cd fvpn
chmod +x fvpn
./fvpn

---

## 🤖 Development Partners (AI Collaboration)

This project was completed by the author (T.C.) through architecture design and algorithmic leadership, with significant assistance from the following AI partners (Free Plans). Without AI, the realization of this tool would not have been possible, and their contributions are deeply acknowledged:

* **Gemini**: Code generation based on specified requirements and algorithms, architecture advice, and debugging support.
* **ChatGPT**: Prototype creation during early development, bug detection, and feature proposals.

---

## 📜 License & Copyright

This project is released under the **[MIT License](https://www.google.com/search?q=LICENSE)**.

* **Copyright**: Copyright (c) 2026 T.C.
* Provided free of charge. Anyone is free to use, modify, and redistribute this software, provided that the copyright notice and permission notice are retained in accordance with the MIT License.

---

## 🤝 Contributions

This tool was released as open source following development and testing by the author. Community feedback and pull requests are warmly welcomed:

* **Feature Extensions & Algorithm Improvements**:
If you submit Pull Requests or code improvements, your contributions will be respected and credited with your name/username in code comments or a CONTRIBUTORS list.
* **Minor Bug Fixes & Typo Corrections**:
For rapid maintenance, individual credits may be omitted and processed directly in commit logs.

---

*For Japanese documentation, please see [README_ja.md](https://www.google.com/search?q=README_ja.md).*
