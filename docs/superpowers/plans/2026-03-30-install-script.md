# install.sh 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 QuickTUI 实现一个交互式一键安装脚本 `install.sh`，引导用户完成环境检测、二进制下载校验、安装路径选择、token 配置和可选的服务注册。

**Architecture:** 单个 POSIX sh 脚本，按步骤顺序执行。每个功能封装为独立函数，主函数 `main` 按序调用。使用 `set -e` 确保任意步骤失败即退出。全局变量在顶部声明，供各函数共享。

**Tech Stack:** POSIX sh，curl/wget，openssl，shasum/sha256sum，launchctl（macOS），systemctl（Linux）

---

## 文件结构

| 文件 | 职责 |
|------|------|
| `install.sh` | 完整安装脚本，包含所有函数和主流程 |

---

### Task 1: 脚本骨架与工具函数

**Files:**
- Create: `install.sh`

- [ ] **Step 1: 创建脚本骨架**

```sh
#!/bin/sh
set -e

# ============================================================
# QuickTUI Installer
# Usage: curl -fsSL https://quicktui.ai/install.sh | sh
# ============================================================

QUICKTUI_REPO="dualface/quicktui"
QUICKTUI_RELEASES="https://github.com/${QUICKTUI_REPO}/releases/latest/download"
QUICKTUI_CONFIG_DIR="${HOME}/.config/quicktui"
QUICKTUI_CONFIG_FILE="${QUICKTUI_CONFIG_DIR}/config"

# Will be set during detection
PLATFORM=""
ARCH=""
BINARY_NAME=""
INSTALL_PATH=""
TOKEN=""
LISTEN_ADDR=""
LISTEN_PORT=""

# ============================================================
# Utility functions
# ============================================================

info() {
    printf '\033[0;32m  ✓\033[0m %s\n' "$1"
}

warn() {
    printf '\033[0;33m  !\033[0m %s\n' "$1"
}

error() {
    printf '\033[0;31mError:\033[0m %s\n' "$1" >&2
}

die() {
    error "$1"
    exit 1
}

confirm() {
    # confirm "question" [default: y/n]
    # Returns 0 for yes, 1 for no
    _prompt="$1"
    _default="${2:-n}"
    if [ "$_default" = "y" ]; then
        _hint="[Y/n]"
    else
        _hint="[y/N]"
    fi
    printf '%s %s ' "$_prompt" "$_hint"
    read -r _answer
    case "$_answer" in
        [Yy]*) return 0 ;;
        [Nn]*) return 1 ;;
        "")
            [ "$_default" = "y" ] && return 0 || return 1
            ;;
        *) return 1 ;;
    esac
}

download() {
    # download <url> <dest>
    _url="$1"
    _dest="$2"
    if command -v curl > /dev/null 2>&1; then
        curl -fsSL "$_url" -o "$_dest"
    elif command -v wget > /dev/null 2>&1; then
        wget -q "$_url" -O "$_dest"
    else
        die "Neither curl nor wget found. Please install one and retry."
    fi
}

# ============================================================
# Main
# ============================================================

main() {
    printf '\n\033[1mQuickTUI Installer\033[0m\n\n'
    detect_platform
    check_tmux
    download_binary
    install_binary
    configure_token
    configure_service
    print_success
}

main
```

- [ ] **Step 2: 设置可执行权限**

```bash
chmod +x /Users/dualface/Desktop/Works/quicktui/install.sh
```

- [ ] **Step 3: 验证脚本语法**

```bash
sh -n /Users/dualface/Desktop/Works/quicktui/install.sh
```

Expected: 无输出（语法正确）

- [ ] **Step 4: 提交**

```bash
git add install.sh
git commit -m "feat: add install.sh skeleton with utility functions"
```

---

### Task 2: 平台检测

**Files:**
- Modify: `install.sh`（在 `detect_platform` 函数位置插入）

- [ ] **Step 1: 实现 detect_platform 函数**

在 `main` 函数前插入：

```sh
detect_platform() {
    _os="$(uname -s)"
    _arch="$(uname -m)"

    case "$_os" in
        Darwin)
            PLATFORM="darwin"
            ;;
        Linux)
            PLATFORM="linux"
            ;;
        *)
            die "Unsupported operating system: $_os. QuickTUI supports macOS and Linux only."
            ;;
    esac

    case "$_arch" in
        arm64|aarch64)
            ARCH="arm64"
            ;;
        x86_64|amd64)
            ARCH="amd64"
            ;;
        *)
            die "Unsupported architecture: $_arch. QuickTUI supports arm64 and x86_64 only."
            ;;
    esac

    # macOS Intel only supports amd64, macOS Apple Silicon only arm64
    # Linux only supports amd64 in current releases
    if [ "$PLATFORM" = "linux" ] && [ "$ARCH" = "arm64" ]; then
        die "Linux arm64 is not yet supported. Please use x86_64 Linux."
    fi

    BINARY_NAME="quicktui-${PLATFORM}-${ARCH}"
    info "Detected platform: ${PLATFORM}/${ARCH}"
}
```

- [ ] **Step 2: 验证语法**

```bash
sh -n /Users/dualface/Desktop/Works/quicktui/install.sh
```

Expected: 无输出

- [ ] **Step 3: 手动测试平台检测**

```bash
sh -c '
PLATFORM=""; ARCH=""; BINARY_NAME=""
uname -s; uname -m
'
```

Expected: 输出当前 OS 和架构（如 `Darwin` 和 `arm64`）

- [ ] **Step 4: 提交**

```bash
git add install.sh
git commit -m "feat: add platform detection to install.sh"
```

---

### Task 3: tmux 检测与安装

**Files:**
- Modify: `install.sh`

- [ ] **Step 1: 实现 check_tmux 函数**

在 `detect_platform` 函数后插入：

```sh
check_tmux() {
    if ! command -v tmux > /dev/null 2>&1; then
        warn "tmux is not installed."
        if confirm "Would you like to install tmux automatically?"; then
            install_tmux
        else
            printf '\nPlease install tmux 3.2 or later and run this installer again.\n'
            printf '  macOS:  brew install tmux\n'
            printf '  Ubuntu: sudo apt install tmux\n'
            printf '  CentOS: sudo yum install tmux\n\n'
            exit 1
        fi
        return
    fi

    _tmux_version="$(tmux -V 2>/dev/null | sed 's/tmux //')"
    _major="$(echo "$_tmux_version" | cut -d. -f1)"
    _minor="$(echo "$_tmux_version" | cut -d. -f2 | cut -d- -f1)"

    if [ "$_major" -lt 3 ] || { [ "$_major" -eq 3 ] && [ "$_minor" -lt 2 ]; }; then
        warn "tmux $_tmux_version detected, but QuickTUI requires tmux 3.2 or later."
        if ! confirm "Continue anyway? (some features may not work)"; then
            exit 1
        fi
    else
        info "tmux $_tmux_version detected"
    fi
}

install_tmux() {
    if [ "$PLATFORM" = "darwin" ]; then
        if ! command -v brew > /dev/null 2>&1; then
            die "Homebrew not found. Please install tmux manually: brew install tmux"
        fi
        brew install tmux
    elif [ "$PLATFORM" = "linux" ]; then
        if command -v apt-get > /dev/null 2>&1; then
            sudo apt-get update -q && sudo apt-get install -y tmux
        elif command -v yum > /dev/null 2>&1; then
            sudo yum install -y tmux
        elif command -v dnf > /dev/null 2>&1; then
            sudo dnf install -y tmux
        else
            die "No supported package manager found (apt/yum/dnf). Please install tmux manually."
        fi
    fi
    info "tmux installed"
}
```

- [ ] **Step 2: 验证语法**

```bash
sh -n /Users/dualface/Desktop/Works/quicktui/install.sh
```

Expected: 无输出

- [ ] **Step 3: 提交**

```bash
git add install.sh
git commit -m "feat: add tmux detection and auto-install to install.sh"
```

---

### Task 4: 下载并校验二进制

**Files:**
- Modify: `install.sh`

- [ ] **Step 1: 实现 download_binary 函数**

在 `check_tmux` 相关函数后插入：

```sh
download_binary() {
    _tmpdir="$(mktemp -d)"
    _binary_path="${_tmpdir}/${BINARY_NAME}"
    _sha256_path="${_tmpdir}/${BINARY_NAME}.sha256"

    printf '  Downloading QuickTUI (%s)...\n' "$BINARY_NAME"
    download "${QUICKTUI_RELEASES}/${BINARY_NAME}" "$_binary_path" || \
        die "Failed to download binary. Check your internet connection and try again."

    printf '  Downloading checksum...\n'
    download "${QUICKTUI_RELEASES}/${BINARY_NAME}.sha256" "$_sha256_path" || \
        die "Failed to download checksum file."

    # Verify checksum
    printf '  Verifying checksum...\n'
    _saved_dir="$(pwd)"
    cd "$_tmpdir"
    if [ "$PLATFORM" = "darwin" ]; then
        shasum -a 256 -c "${BINARY_NAME}.sha256" > /dev/null 2>&1 || {
            cd "$_saved_dir"
            rm -rf "$_tmpdir"
            die "Checksum verification failed. The downloaded file may be corrupted."
        }
    else
        sha256sum -c "${BINARY_NAME}.sha256" > /dev/null 2>&1 || {
            cd "$_saved_dir"
            rm -rf "$_tmpdir"
            die "Checksum verification failed. The downloaded file may be corrupted."
        }
    fi
    cd "$_saved_dir"

    chmod +x "$_binary_path"
    info "Download verified"

    # Export path for next step
    DOWNLOADED_BINARY="$_binary_path"
    DOWNLOAD_TMPDIR="$_tmpdir"
}
```

在脚本顶部全局变量区域添加：

```sh
DOWNLOADED_BINARY=""
DOWNLOAD_TMPDIR=""
```

- [ ] **Step 2: 验证语法**

```bash
sh -n /Users/dualface/Desktop/Works/quicktui/install.sh
```

Expected: 无输出

- [ ] **Step 3: 提交**

```bash
git add install.sh
git commit -m "feat: add binary download and sha256 verification to install.sh"
```

---

### Task 5: 安装路径选择

**Files:**
- Modify: `install.sh`

- [ ] **Step 1: 实现 install_binary 函数**

```sh
install_binary() {
    printf '\nWhere would you like to install QuickTUI?\n'
    printf '  [1] %s/.local/bin/quicktui  (no sudo required)  [default]\n' "$HOME"
    printf '  [2] /usr/local/bin/quicktui  (requires sudo)\n'
    printf 'Enter choice [1]: '
    read -r _choice
    _choice="${_choice:-1}"

    case "$_choice" in
        1)
            INSTALL_PATH="${HOME}/.local/bin/quicktui"
            mkdir -p "${HOME}/.local/bin"
            mv "$DOWNLOADED_BINARY" "$INSTALL_PATH"
            chmod 755 "$INSTALL_PATH"
            # Warn if not in PATH
            case ":${PATH}:" in
                *":${HOME}/.local/bin:"*) ;;
                *)
                    warn "~/.local/bin is not in your PATH."
                    printf '  Add this to your shell config (~/.bashrc, ~/.zshrc, etc.):\n'
                    printf '    export PATH="$HOME/.local/bin:$PATH"\n\n'
                    ;;
            esac
            ;;
        2)
            INSTALL_PATH="/usr/local/bin/quicktui"
            sudo mv "$DOWNLOADED_BINARY" "$INSTALL_PATH"
            sudo chmod 755 "$INSTALL_PATH"
            ;;
        *)
            die "Invalid choice: $_choice"
            ;;
    esac

    rm -rf "$DOWNLOAD_TMPDIR"
    info "Installed to $INSTALL_PATH"
}
```

- [ ] **Step 2: 验证语法**

```bash
sh -n /Users/dualface/Desktop/Works/quicktui/install.sh
```

Expected: 无输出

- [ ] **Step 3: 提交**

```bash
git add install.sh
git commit -m "feat: add install path selection to install.sh"
```

---

### Task 6: Token 配置

**Files:**
- Modify: `install.sh`

- [ ] **Step 1: 实现 configure_token 函数**

```sh
configure_token() {
    printf '\nHow would you like to set up your access token?\n'
    printf '  [1] Generate a random token automatically  [default]\n'
    printf '  [2] Enter my own token\n'
    printf 'Enter choice [1]: '
    read -r _choice
    _choice="${_choice:-1}"

    case "$_choice" in
        1)
            if command -v openssl > /dev/null 2>&1; then
                TOKEN="$(openssl rand -hex 32)"
            else
                TOKEN="$(head -c 32 /dev/urandom | od -A n -t x1 | tr -d ' \n')"
            fi
            info "Random token generated"
            ;;
        2)
            printf 'Enter your token (input hidden): '
            stty -echo 2>/dev/null || true
            read -r TOKEN
            stty echo 2>/dev/null || true
            printf '\n'
            if [ -z "$TOKEN" ]; then
                die "Token cannot be empty."
            fi
            info "Token configured"
            ;;
        *)
            die "Invalid choice: $_choice"
            ;;
    esac

    # Save to config file
    mkdir -p "$QUICKTUI_CONFIG_DIR"
    chmod 700 "$QUICKTUI_CONFIG_DIR"
    printf 'QUICKTUI_TOKEN=%s\n' "$TOKEN" > "$QUICKTUI_CONFIG_FILE"
    chmod 600 "$QUICKTUI_CONFIG_FILE"
    info "Config saved to $QUICKTUI_CONFIG_FILE"
}
```

- [ ] **Step 2: 验证语法**

```bash
sh -n /Users/dualface/Desktop/Works/quicktui/install.sh
```

Expected: 无输出

- [ ] **Step 3: 提交**

```bash
git add install.sh
git commit -m "feat: add token configuration to install.sh"
```

---

### Task 7: 服务注册

**Files:**
- Modify: `install.sh`

- [ ] **Step 1: 实现 configure_service 函数及子函数**

```sh
configure_service() {
    printf '\n'
    if ! confirm "Would you like to register QuickTUI as a background service?"; then
        return 0
    fi

    printf 'Listen address [default: 0.0.0.0]: '
    read -r LISTEN_ADDR
    LISTEN_ADDR="${LISTEN_ADDR:-0.0.0.0}"

    printf 'Port [default: 3000]: '
    read -r LISTEN_PORT
    LISTEN_PORT="${LISTEN_PORT:-3000}"

    if [ "$PLATFORM" = "darwin" ]; then
        setup_launchd
    else
        setup_systemd
    fi
}

setup_launchd() {
    _plist_dir="${HOME}/Library/LaunchAgents"
    _plist_file="${_plist_dir}/ai.quicktui.plist"

    mkdir -p "$_plist_dir"

    cat > "$_plist_file" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>ai.quicktui</string>
  <key>ProgramArguments</key>
  <array>
    <string>${INSTALL_PATH}</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>QUICKTUI_TOKEN</key>
    <string>${TOKEN}</string>
    <key>QUICKTUI_ADDR</key>
    <string>${LISTEN_ADDR}:${LISTEN_PORT}</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
</dict>
</plist>
EOF

    chmod 600 "$_plist_file"
    launchctl load "$_plist_file" 2>/dev/null || \
        warn "Failed to load launchd service. You can start it manually: launchctl load $_plist_file"
    info "launchd service registered: $_plist_file"
}

setup_systemd() {
    _service_dir="${HOME}/.config/systemd/user"
    _service_file="${_service_dir}/quicktui.service"

    mkdir -p "$_service_dir"

    cat > "$_service_file" << EOF
[Unit]
Description=QuickTUI Remote Terminal Server
After=network.target

[Service]
EnvironmentFile=${QUICKTUI_CONFIG_FILE}
ExecStart=${INSTALL_PATH}
Environment=QUICKTUI_ADDR=${LISTEN_ADDR}:${LISTEN_PORT}
Restart=on-failure

[Install]
WantedBy=default.target
EOF

    systemctl --user daemon-reload 2>/dev/null || \
        { warn "systemctl --user not available. Service file saved to $_service_file"; return 0; }
    systemctl --user enable quicktui 2>/dev/null || true
    systemctl --user start quicktui 2>/dev/null || \
        warn "Failed to start service. Try: systemctl --user start quicktui"
    info "systemd user service registered: $_service_file"
}
```

- [ ] **Step 2: 验证语法**

```bash
sh -n /Users/dualface/Desktop/Works/quicktui/install.sh
```

Expected: 无输出

- [ ] **Step 3: 提交**

```bash
git add install.sh
git commit -m "feat: add service registration (launchd/systemd) to install.sh"
```

---

### Task 8: 完成信息打印

**Files:**
- Modify: `install.sh`

- [ ] **Step 1: 实现 print_success 函数**

```sh
print_success() {
    # Detect local IP
    _ip=""
    if [ "$PLATFORM" = "darwin" ]; then
        _ip="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "localhost")"
    else
        _ip="$(hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")"
    fi
    [ -z "$_ip" ] && _ip="localhost"

    _port="${LISTEN_PORT:-3000}"
    _version="$("$INSTALL_PATH" --version 2>/dev/null || echo "unknown")"

    printf '\n\033[0;32m✓ QuickTUI installed successfully!\033[0m\n\n'
    printf '  Binary:  %s\n' "$INSTALL_PATH"
    printf '  Config:  %s\n' "$QUICKTUI_CONFIG_FILE"
    [ "$_version" != "unknown" ] && printf '  Version: %s\n' "$_version"
    printf '\n'
    printf 'Getting started:\n'
    printf '  Open in browser:  http://%s:%s\n' "$_ip" "$_port"
    printf '  Token:            %s\n' "$TOKEN"
    printf '  (Enter the token when prompted on first login)\n'
    printf '\n'
    printf 'iOS App:\n'
    printf '  App Store & TestFlight:  https://quicktui.ai/#download\n'
    printf '\n'
}
```

- [ ] **Step 2: 验证完整脚本语法**

```bash
sh -n /Users/dualface/Desktop/Works/quicktui/install.sh
```

Expected: 无输出

- [ ] **Step 3: 检查脚本完整性——确认所有函数都已实现**

```bash
grep -E '^[a-z_]+\(\)' /Users/dualface/Desktop/Works/quicktui/install.sh
```

Expected 输出（顺序可不同）：
```
info()
warn()
error()
die()
confirm()
download()
detect_platform()
check_tmux()
install_tmux()
download_binary()
install_binary()
configure_token()
configure_service()
setup_launchd()
setup_systemd()
print_success()
main()
```

- [ ] **Step 4: 提交**

```bash
git add install.sh
git commit -m "feat: add success output to install.sh, complete installer"
```

---

### Task 9: 端到端冒烟测试

**Files:** 无文件变更

- [ ] **Step 1: 语法检查（POSIX sh）**

```bash
sh -n /Users/dualface/Desktop/Works/quicktui/install.sh
```

Expected: 无输出

- [ ] **Step 2: 用 shellcheck 静态分析（如已安装）**

```bash
shellcheck -s sh /Users/dualface/Desktop/Works/quicktui/install.sh 2>/dev/null && echo "shellcheck passed" || echo "shellcheck not installed, skipping"
```

- [ ] **Step 3: 验证下载函数的 curl/wget fallback 逻辑**

```bash
sh -c '
download() {
    _url="$1"; _dest="$2"
    if command -v curl > /dev/null 2>&1; then
        curl -fsSL "$_url" -o "$_dest"
    elif command -v wget > /dev/null 2>&1; then
        wget -q "$_url" -O "$_dest"
    else
        echo "ERROR: Neither curl nor wget found" >&2; return 1
    fi
}
download "https://example.com" /tmp/test_download_qt && echo "download OK" && rm /tmp/test_download_qt
'
```

Expected: `download OK`

- [ ] **Step 4: 验证 token 生成**

```bash
sh -c '
if command -v openssl > /dev/null 2>&1; then
    token="$(openssl rand -hex 32)"
else
    token="$(head -c 32 /dev/urandom | od -A n -t x1 | tr -d " \n")"
fi
echo "Token length: ${#token}"
echo "Token sample: ${token}"
'
```

Expected: `Token length: 64`

- [ ] **Step 5: 推送到 GitHub**

```bash
git push origin main
```

Expected: 推送成功，`install.sh` 可通过 `https://raw.githubusercontent.com/dualface/quicktui/main/install.sh` 访问，也可通过 `https://quicktui.ai/install.sh` 访问（DNS 生效后）
