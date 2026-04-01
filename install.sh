#!/bin/sh
set -e
umask 077

# ============================================================
# QuickTUI Installer
# Usage: curl -fsSL https://quicktui.ai/install.sh | sh
# ============================================================

QUICKTUI_REPO="dualface/quicktui"
QUICKTUI_RELEASES="${QUICKTUI_RELEASES:-https://github.com/${QUICKTUI_REPO}/releases/latest/download}"
QUICKTUI_CONFIG_DIR="${HOME}/.config/quicktui"
QUICKTUI_CONFIG_FILE="${QUICKTUI_CONFIG_DIR}/config"

# CLI options (set via arguments)
NON_INTERACTIVE=""
OPT_INSTALL_DIR=""
OPT_TOKEN=""
OPT_NO_SERVICE=""
OPT_ADDR=""
OPT_PORT=""

# Will be set during detection
PLATFORM=""
ARCH=""
BINARY_NAME=""
INSTALL_PATH=""
TOKEN=""
LISTEN_ADDR=""
LISTEN_PORT=""
DOWNLOADED_BINARY=""
DOWNLOAD_TMPDIR=""
SERVICE_STARTED=""

cleanup() {
    [ -n "$DOWNLOAD_TMPDIR" ] && rm -rf "$DOWNLOAD_TMPDIR" || true
    stty echo </dev/tty 2>/dev/null || true
}
trap cleanup EXIT INT TERM

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

# ============================================================
# Parse command-line arguments
# ============================================================

while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes)
            NON_INTERACTIVE="1"
            shift
            ;;
        --install-dir)
            OPT_INSTALL_DIR="$2"
            shift 2
            ;;
        --token)
            OPT_TOKEN="$2"
            shift 2
            ;;
        --no-service)
            OPT_NO_SERVICE="1"
            shift
            ;;
        --addr)
            OPT_ADDR="$2"
            shift 2
            ;;
        --port)
            OPT_PORT="$2"
            shift 2
            ;;
        -h|--help)
            printf 'Usage: install.sh [OPTIONS]\n\n'
            printf 'Options:\n'
            printf '  -y, --yes          Non-interactive mode (use defaults)\n'
            printf '  --install-dir <1|2>  Install location: 1=~/.local/bin, 2=/usr/local/bin\n'
            printf '  --token <string>   Set access token (skip prompt)\n'
            printf '  --no-service       Skip background service registration\n'
            printf '  --addr <address>   Listen address (default: 0.0.0.0)\n'
            printf '  --port <port>      Listen port (default: 3000)\n'
            printf '  -h, --help         Show this help\n'
            exit 0
            ;;
        *)
            die "Unknown option: $1 (use --help for usage)"
            ;;
    esac
done

confirm() {
    _prompt="$1"
    _default="${2:-n}"
    if [ -n "$NON_INTERACTIVE" ]; then
        [ "$_default" = "y" ] && return 0 || return 1
    fi
    if [ "$_default" = "y" ]; then
        _hint="[Y/n]"
    else
        _hint="[y/N]"
    fi
    printf '%s %s ' "$_prompt" "$_hint"
    read -r _answer </dev/tty
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

run_privileged() {
    if [ "$(id -u)" = "0" ]; then
        "$@"
    elif command -v sudo > /dev/null 2>&1; then
        sudo "$@"
    else
        die "Root privileges required but 'sudo' is not available. Please run as root or install sudo."
    fi
}

# ============================================================
# Step 1: Detect platform and architecture
# ============================================================

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

    BINARY_NAME="quicktui-server-${PLATFORM}-${ARCH}"
    info "Detected platform: ${PLATFORM}/${ARCH}"
}

# ============================================================
# Step 2: Check tmux
# ============================================================

install_tmux() {
    if [ "$PLATFORM" = "darwin" ]; then
        if ! command -v brew > /dev/null 2>&1; then
            die "Homebrew not found. Please install tmux manually: brew install tmux"
        fi
        brew install tmux
    elif [ "$PLATFORM" = "linux" ]; then
        if command -v apt-get > /dev/null 2>&1; then
            run_privileged apt-get update -q && run_privileged apt-get install -y tmux
        elif command -v yum > /dev/null 2>&1; then
            run_privileged yum install -y tmux
        elif command -v dnf > /dev/null 2>&1; then
            run_privileged dnf install -y tmux
        else
            die "No supported package manager found (apt/yum/dnf). Please install tmux manually."
        fi
    fi
    info "tmux installed"
}

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
    _minor="$(echo "$_tmux_version" | cut -d. -f2 | cut -d- -f1 | sed 's/[^0-9].*//')"

    if [ "$_major" -lt 3 ] || { [ "$_major" -eq 3 ] && [ "$_minor" -lt 2 ]; }; then
        warn "tmux $_tmux_version detected, but QuickTUI requires tmux 3.2 or later."
        if ! confirm "Continue anyway? (some features may not work)"; then
            exit 1
        fi
    else
        info "tmux $_tmux_version detected"
    fi
}

# ============================================================
# Step 3: Download and verify binary
# ============================================================

download_binary() {
    DOWNLOAD_TMPDIR="$(mktemp -d)"
    _binary_path="${DOWNLOAD_TMPDIR}/${BINARY_NAME}"
    _sha256_path="${DOWNLOAD_TMPDIR}/${BINARY_NAME}.sha256"

    printf '  Downloading QuickTUI (%s)...\n' "$BINARY_NAME"
    download "${QUICKTUI_RELEASES}/${BINARY_NAME}" "$_binary_path" || \
        die "Failed to download binary. Check your internet connection and try again."

    printf '  Downloading checksum...\n'
    download "${QUICKTUI_RELEASES}/${BINARY_NAME}.sha256" "$_sha256_path" || \
        die "Failed to download checksum file."

    printf '  Verifying checksum...\n'
    _saved_dir="$(pwd)"
    cd "$DOWNLOAD_TMPDIR"
    if [ "$PLATFORM" = "darwin" ]; then
        shasum -a 256 -c "${BINARY_NAME}.sha256" > /dev/null 2>&1 || {
            cd "$_saved_dir"
            rm -rf "$DOWNLOAD_TMPDIR"
            die "Checksum verification failed. The downloaded file may be corrupted."
        }
    else
        sha256sum -c "${BINARY_NAME}.sha256" > /dev/null 2>&1 || {
            cd "$_saved_dir"
            rm -rf "$DOWNLOAD_TMPDIR"
            die "Checksum verification failed. The downloaded file may be corrupted."
        }
    fi
    cd "$_saved_dir"

    chmod +x "$_binary_path"
    DOWNLOADED_BINARY="$_binary_path"
    info "Download verified"
}

# ============================================================
# Step 4: Install binary
# ============================================================

install_binary() {
    if [ -n "$NON_INTERACTIVE" ]; then
        _choice="${OPT_INSTALL_DIR:-1}"
    else
        printf '\nWhere would you like to install QuickTUI?\n'
        printf '  [1] %s/.local/bin/quicktui  (no sudo required)  [default]\n' "$HOME"
        printf '  [2] /usr/local/bin/quicktui  (requires sudo)\n'
        printf 'Enter choice [1]: '
        read -r _choice </dev/tty
        _choice="${_choice:-1}"
    fi

    case "$_choice" in
        1)
            INSTALL_PATH="${HOME}/.local/bin/quicktui"
            mkdir -p "${HOME}/.local/bin"
            mv "$DOWNLOADED_BINARY" "$INSTALL_PATH"
            chmod 755 "$INSTALL_PATH"
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
            run_privileged mv "$DOWNLOADED_BINARY" "$INSTALL_PATH"
            run_privileged chmod 755 "$INSTALL_PATH"
            ;;
        *)
            die "Invalid choice: $_choice"
            ;;
    esac

    DOWNLOAD_TMPDIR=""
    info "Installed to $INSTALL_PATH"
}

# ============================================================
# Step 5: Configure token
# ============================================================

configure_token() {
    if [ -n "$OPT_TOKEN" ]; then
        TOKEN="$OPT_TOKEN"
        info "Token configured (from argument)"
    elif [ -n "$NON_INTERACTIVE" ]; then
        if command -v openssl > /dev/null 2>&1; then
            TOKEN="$(openssl rand -hex 32)"
        else
            TOKEN="$(head -c 32 /dev/urandom | od -A n -t x1 | tr -d ' \n')"
        fi
        info "Random token generated"
    else
        printf '\nHow would you like to set up your access token?\n'
        printf '  [1] Generate a random token automatically  [default]\n'
        printf '  [2] Enter my own token\n'
        printf 'Enter choice [1]: '
        read -r _choice </dev/tty
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
                stty -echo </dev/tty 2>/dev/null || true
                read -r TOKEN </dev/tty
                stty echo </dev/tty 2>/dev/null || true
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
    fi

    mkdir -p "$QUICKTUI_CONFIG_DIR"
    chmod 700 "$QUICKTUI_CONFIG_DIR"
    printf 'QUICKTUI_TOKEN=%s\n' "$TOKEN" > "$QUICKTUI_CONFIG_FILE"
    chmod 600 "$QUICKTUI_CONFIG_FILE"
    info "Config saved to $QUICKTUI_CONFIG_FILE"
}

# ============================================================
# Step 6: Configure background service (optional)
# ============================================================

setup_launchd() {
    _plist_dir="${HOME}/Library/LaunchAgents"
    _plist_file="${_plist_dir}/ai.quicktui.plist"
    _log_dir="${HOME}/Library/Logs/QuickTUI"
    _gui_target="gui/$(id -u)"

    mkdir -p "$_plist_dir"
    mkdir -p "$_log_dir"

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
    <key>QUICKTUI_CONFIG</key>
    <string>${QUICKTUI_CONFIG_FILE}</string>
    <key>QUICKTUI_ADDR</key>
    <string>${LISTEN_ADDR}:${LISTEN_PORT}</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${_log_dir}/stdout.log</string>
  <key>StandardErrorPath</key>
  <string>${_log_dir}/stderr.log</string>
</dict>
</plist>
EOF

    chmod 600 "$_plist_file"

    # Unload existing service if present
    launchctl bootout "$_gui_target/ai.quicktui" 2>/dev/null || true

    if launchctl bootstrap "$_gui_target" "$_plist_file" 2>/dev/null; then
        SERVICE_STARTED="yes"
        info "launchd service registered: $_plist_file"
        info "Logs: $_log_dir"
    else
        warn "Failed to load launchd service. You can start it manually:"
        warn "  launchctl bootstrap $_gui_target $_plist_file"
        info "launchd service registered (not started): $_plist_file"
    fi
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

    if ! systemctl --user daemon-reload 2>/dev/null; then
        warn "systemctl --user not available. Service file saved to $_service_file"
        return 0
    fi
    systemctl --user enable quicktui 2>/dev/null || true
    if systemctl --user start quicktui 2>/dev/null; then
        SERVICE_STARTED="yes"
        info "systemd user service registered: $_service_file"
    else
        warn "Failed to start service. Try: systemctl --user start quicktui"
        info "systemd user service registered (not started): $_service_file"
    fi
}

configure_service() {
    if [ -n "$OPT_NO_SERVICE" ]; then
        info "Skipped service registration (--no-service)"
        return 0
    fi

    if [ -z "$NON_INTERACTIVE" ]; then
        printf '\n'
        if ! confirm "Would you like to register QuickTUI as a background service?"; then
            return 0
        fi
    fi

    if [ -n "$NON_INTERACTIVE" ]; then
        LISTEN_ADDR="${OPT_ADDR:-0.0.0.0}"
        LISTEN_PORT="${OPT_PORT:-3000}"
    else
        while true; do
            printf 'Listen address [default: 0.0.0.0]: '
            read -r LISTEN_ADDR </dev/tty
            LISTEN_ADDR="${LISTEN_ADDR:-0.0.0.0}"
            case "$LISTEN_ADDR" in
                *[\ \;\`\$\(\)\'\"\#\&\|\<\>\\]*)
                    warn "Invalid listen address: '$LISTEN_ADDR'. Only alphanumeric characters, dots, hyphens, and colons are allowed."
                    LISTEN_ADDR=""
                    ;;
                *)
                    break
                    ;;
            esac
        done

        while true; do
            printf 'Port [default: 3000]: '
            read -r LISTEN_PORT </dev/tty
            LISTEN_PORT="${LISTEN_PORT:-3000}"
            case "$LISTEN_PORT" in
                ''|*[!0-9]*)
                    warn "Invalid port: '$LISTEN_PORT'. Please enter a number between 1 and 65535."
                    LISTEN_PORT=""
                    ;;
                *)
                    if [ "$LISTEN_PORT" -lt 1 ] || [ "$LISTEN_PORT" -gt 65535 ]; then
                        warn "Port must be between 1 and 65535."
                        LISTEN_PORT=""
                    else
                        break
                    fi
                    ;;
            esac
        done
    fi

    if [ "$PLATFORM" = "darwin" ]; then
        setup_launchd
    else
        setup_systemd
    fi
}

# ============================================================
# Step 7: Print success message
# ============================================================

print_success() {
    _version="$("$INSTALL_PATH" --version 2>/dev/null || echo "")"

    printf '\n\033[0;32m✓ QuickTUI installed successfully!\033[0m\n\n'
    printf '  Binary:  %s\n' "$INSTALL_PATH"
    printf '  Config:  %s\n' "$QUICKTUI_CONFIG_FILE"
    [ -n "$_version" ] && printf '  Version: %s\n' "$_version"
    printf '\n'

    if [ "$SERVICE_STARTED" = "yes" ]; then
        _ip=""
        if [ "$PLATFORM" = "darwin" ]; then
            _ip="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "")"
        else
            _ip="$(hostname -I 2>/dev/null | awk '{print $1}' || echo "")"
        fi
        [ -z "$_ip" ] && _ip="localhost"
        printf 'Getting started:\n'
        printf '  Open in browser:  http://%s:%s\n' "$_ip" "$LISTEN_PORT"
        printf '  Token:            %s\n' "$TOKEN"
        printf '  (Enter the token when prompted on first login)\n'
    elif [ -n "$LISTEN_PORT" ]; then
        printf 'Service registration failed. Start manually:\n'
        if [ "$PLATFORM" = "darwin" ]; then
            printf '  launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/ai.quicktui.plist\n'
        else
            printf '  systemctl --user start quicktui\n'
        fi
        printf '  Token: %s\n' "$TOKEN"
    else
        printf 'To start QuickTUI, run:\n'
        printf '  QUICKTUI_TOKEN=%s %s\n' "$TOKEN" "$INSTALL_PATH"
    fi

    printf '\n'
    printf 'iOS App:\n'
    printf '  App Store & TestFlight:  https://quicktui.ai/#download\n'
    printf '\n'
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
