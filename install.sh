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
OPT_TOKEN=""
OPT_NO_SERVICE=""
OPT_ADDR=""
OPT_PORT=""
OPT_TERM=""
OPT_LANG=""
UNINSTALL=""

# Will be set during detection
PLATFORM=""
ARCH=""
BINARY_NAME=""
INSTALL_PATH=""
TOKEN=""
TERM_ENV=""
LANG_ENV=""
LISTEN_ADDR=""
LISTEN_PORT=""
DOWNLOADED_BINARY=""
DOWNLOAD_TMPDIR=""
SERVICE_STARTED=""

cleanup() {
    [ -n "$DOWNLOAD_TMPDIR" ] && rm -rf "$DOWNLOAD_TMPDIR" || true
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
--token)
            OPT_TOKEN="$2"
            shift 2
            ;;
        --no-service)
            OPT_NO_SERVICE="1"
            shift
            ;;
        --term)
            OPT_TERM="$2"
            shift 2
            ;;
        --lang)
            OPT_LANG="$2"
            shift 2
            ;;
        --addr)
            OPT_ADDR="$2"
            shift 2
            ;;
        --port)
            OPT_PORT="$2"
            shift 2
            ;;
        --uninstall)
            UNINSTALL="1"
            shift
            ;;
        -h|--help)
            printf 'Usage: install.sh [OPTIONS]\n\n'
            printf 'Options:\n'
            printf '  -y, --yes          Non-interactive mode (use defaults)\n'
            printf '  --token <string>   Set access token (skip prompt)\n'
            printf '  --no-service       Skip background service registration\n'
            printf '  --addr <address>   Listen address (default: 0.0.0.0)\n'
            printf '  --port <port>      Listen port (default: 8022)\n'
            printf '  --term <value>     TERM for tmux (default: xterm-256color)\n'
            printf '  --lang <value>     LANG for tmux (default: en_US.UTF-8)\n'
            printf '  --uninstall        Remove QuickTUI and all related files\n'
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
        curl -fSL --progress-bar "$_url" -o "$_dest"
    elif command -v wget > /dev/null 2>&1; then
        wget --show-progress -q "$_url" -O "$_dest"
    else
        die "Neither curl nor wget found. Please install one and retry."
    fi
}

download_silent() {
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

    printf '  Temp dir:  %s\n' "$DOWNLOAD_TMPDIR"
    printf '  Downloading QuickTUI (%s)...\n' "$BINARY_NAME"
    download "${QUICKTUI_RELEASES}/${BINARY_NAME}" "$_binary_path" || \
        die "Failed to download binary. Check your internet connection and try again."

    _file_size="$(du -sh "$_binary_path" 2>/dev/null | cut -f1)"
    printf '  File size: %s\n' "${_file_size:-unknown}"

    printf '  Downloading checksum...\n'
    download_silent "${QUICKTUI_RELEASES}/${BINARY_NAME}.sha256" "$_sha256_path" || \
        die "Failed to download checksum file."

    printf '  Verifying checksum...\n'
    # Normalize checksum file: strip any path prefix, keep only hash + filename
    _hash="$(awk '{print $1}' "${_sha256_path}")"
    printf '%s  %s\n' "$_hash" "$BINARY_NAME" > "${_sha256_path}"
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
    INSTALL_PATH="${HOME}/.local/bin/quicktui-server"
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
                printf 'Enter your token: '
                read -r TOKEN </dev/tty
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
# Step 6: Configure terminal environment
# ============================================================

configure_terminal() {
    _interactive_term="${TERM:-xterm-256color}"
    _interactive_lang="${LANG:-en_US.UTF-8}"

    if [ -n "$OPT_TERM" ]; then
        TERM_ENV="$OPT_TERM"
    elif [ -n "$NON_INTERACTIVE" ]; then
        TERM_ENV="xterm-256color"
    else
        printf '\nTerminal environment for tmux:\n'
        printf '  TERM [%s]: ' "$_interactive_term"
        read -r _input </dev/tty
        TERM_ENV="${_input:-$_interactive_term}"
    fi

    if [ -n "$OPT_LANG" ]; then
        LANG_ENV="$OPT_LANG"
    elif [ -n "$NON_INTERACTIVE" ]; then
        LANG_ENV="en_US.UTF-8"
    else
        printf '  LANG [%s]: ' "$_interactive_lang"
        read -r _input </dev/tty
        LANG_ENV="${_input:-$_interactive_lang}"
    fi

    printf 'QUICKTUI_TERM=%s\n' "$TERM_ENV" >> "$QUICKTUI_CONFIG_FILE"
    printf 'QUICKTUI_LANG=%s\n' "$LANG_ENV" >> "$QUICKTUI_CONFIG_FILE"
    info "Terminal: TERM=$TERM_ENV, LANG=$LANG_ENV"
}

# ============================================================
# Step 7: Configure background service (optional)
# ============================================================

setup_launchd() {
    _plist_dir="${HOME}/Library/LaunchAgents"
    _plist_file="${_plist_dir}/ai.quicktui.plist"
    _log_dir="${HOME}/Library/Logs/QuickTUI"
    _gui_target="gui/$(id -u)"

    _wrapper="${_plist_dir}/ai.quicktui.sh"

    mkdir -p "$_plist_dir"
    mkdir -p "$_log_dir"

    # Detect tmux's directory and TMPDIR at install time so launchd can find tmux
    _tmux_dir="$(dirname "$(command -v tmux)")"
    # Wrapper script: source config file to load QUICKTUI_TOKEN, then exec server
    cat > "$_wrapper" << EOF
#!/bin/sh
export PATH="${_tmux_dir}:/usr/local/bin:/usr/bin:/bin"
export TMPDIR="/tmp"
set -a
. ${QUICKTUI_CONFIG_FILE}
set +a
exec ${INSTALL_PATH}
EOF
    chmod 700 "$_wrapper"

    cat > "$_plist_file" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>ai.quicktui</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string>
    <string>${_wrapper}</string>
  </array>
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
        LISTEN_PORT="${OPT_PORT:-8022}"
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
            printf 'Port [default: 8022]: '
            read -r LISTEN_PORT </dev/tty
            LISTEN_PORT="${LISTEN_PORT:-8022}"
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

    printf 'QUICKTUI_ADDR=%s:%s\n' "$LISTEN_ADDR" "$LISTEN_PORT" >> "$QUICKTUI_CONFIG_FILE"
    info "Listen address: $LISTEN_ADDR:$LISTEN_PORT"

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
# Uninstall
# ============================================================

uninstall() {
    printf '\n\033[1mQuickTUI Uninstaller\033[0m\n\n'
    detect_platform

    _removed=0

    # Stop and remove launchd service (macOS)
    if [ "$PLATFORM" = "darwin" ]; then
        _gui_target="gui/$(id -u)"
        _plist="${HOME}/Library/LaunchAgents/ai.quicktui.plist"
        _wrapper="${HOME}/Library/LaunchAgents/ai.quicktui.sh"
        _log_dir="${HOME}/Library/Logs/QuickTUI"

        launchctl bootout "$_gui_target/ai.quicktui" 2>/dev/null && \
            info "launchd service stopped"

        if [ -f "$_plist" ]; then
            rm -f "$_plist"
            info "Removed: $_plist"
            _removed=1
        fi
        if [ -f "$_wrapper" ]; then
            rm -f "$_wrapper"
            info "Removed: $_wrapper"
            _removed=1
        fi
        if [ -d "$_log_dir" ]; then
            rm -rf "$_log_dir"
            info "Removed: $_log_dir"
            _removed=1
        fi
    fi

    # Stop and remove systemd service (Linux)
    if [ "$PLATFORM" = "linux" ]; then
        _service_file="${HOME}/.config/systemd/user/quicktui.service"
        systemctl --user stop quicktui 2>/dev/null && \
            info "systemd service stopped"
        systemctl --user disable quicktui 2>/dev/null || true
        if [ -f "$_service_file" ]; then
            rm -f "$_service_file"
            systemctl --user daemon-reload 2>/dev/null || true
            info "Removed: $_service_file"
            _removed=1
        fi
    fi

    # Remove binary
    _binary="${HOME}/.local/bin/quicktui-server"
    if [ -f "$_binary" ]; then
        rm -f "$_binary"
        info "Removed: $_binary"
        _removed=1
    fi

    # Remove config
    if [ -d "$QUICKTUI_CONFIG_DIR" ]; then
        rm -rf "$QUICKTUI_CONFIG_DIR"
        info "Removed: $QUICKTUI_CONFIG_DIR"
        _removed=1
    fi

    if [ "$_removed" = "0" ]; then
        printf '  Nothing to remove. QuickTUI does not appear to be installed.\n'
    else
        printf '\n\033[0;32m✓ QuickTUI uninstalled successfully.\033[0m\n\n'
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
    configure_terminal
    configure_service
    print_success
}

if [ -n "$UNINSTALL" ]; then
    uninstall
else
    main
fi
