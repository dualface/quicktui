#!/bin/sh
set -e
umask 077

# ============================================================
# QuickTUI Installer
# Usage: curl -fsSL https://quicktui.ai/q.sh | sh
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
CHECK_ONLY=""

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
SERVICE_FAILURE_REASON=""
IS_UPGRADE=""
TMUX_BIN_CONFIG=""
INSTALLED_TMUX_BIN=""
EXISTING_SERVICE=""
EXISTING_TOKEN=""
EXISTING_ADDR=""
EXISTING_PORT=""
EXISTING_ADDR_RAW=""
EXISTING_TERM=""
EXISTING_LANG=""
EXISTING_TMUX_BIN=""
STAGED_BINARY_PATH=""
BACKUP_BINARY_PATH=""

_BG_PID=""
cleanup() {
    [ -n "$_BG_PID" ] && kill "$_BG_PID" 2>/dev/null || true
    [ -n "$DOWNLOAD_TMPDIR" ] && rm -rf "$DOWNLOAD_TMPDIR" || true
}
trap 'cleanup; exit 130' INT TERM
trap cleanup EXIT

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

fetch_text() {
    _url="$1"
    if command -v curl > /dev/null 2>&1; then
        curl -fsSL "$_url"
    elif command -v wget > /dev/null 2>&1; then
        wget -qO- "$_url"
    else
        die "Neither curl nor wget found. Please install one and retry."
    fi
}

shell_quote() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

normalize_sha256() {
    printf '%s\n' "$1" | sed 's/^sha256://; y/ABCDEF/abcdef/'
}

sha256_file() {
    _path="$1"
    if command -v sha256sum > /dev/null 2>&1; then
        sha256sum "$_path" | awk '{print $1}'
    elif command -v shasum > /dev/null 2>&1; then
        shasum -a 256 "$_path" | awk '{print $1}'
    elif command -v openssl > /dev/null 2>&1; then
        openssl dgst -sha256 "$_path" | sed 's/^.*= //'
    else
        die "No SHA-256 tool found (need sha256sum, shasum, or openssl)."
    fi
}

tmux_release_version_from_json() {
    _json_path="$1"
    sed -n '/"tag_name"/{
        s/.*"tag_name"[[:space:]]*:[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/p
        q
    }' "$_json_path"
}

tmux_release_digest_from_json() {
    _json_path="$1"
    _filename="$2"
    awk -v target="\"name\": \"${_filename}\"" '
        index($0, target) { in_asset = 1; next }
        in_asset && /"digest": "sha256:/ {
            sub(/.*"digest": "sha256:/, "")
            sub(/".*/, "")
            print
            exit
        }
    ' "$_json_path"
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
            [ $# -ge 2 ] || die "Missing value for $1"
            OPT_TOKEN="$2"
            shift 2
            ;;
        --no-service)
            OPT_NO_SERVICE="1"
            shift
            ;;
        --term)
            [ $# -ge 2 ] || die "Missing value for $1"
            OPT_TERM="$2"
            shift 2
            ;;
        --lang)
            [ $# -ge 2 ] || die "Missing value for $1"
            OPT_LANG="$2"
            shift 2
            ;;
        --check)
            CHECK_ONLY="1"
            shift
            ;;
        --addr)
            [ $# -ge 2 ] || die "Missing value for $1"
            OPT_ADDR="$2"
            shift 2
            ;;
        --port)
            [ $# -ge 2 ] || die "Missing value for $1"
            OPT_PORT="$2"
            shift 2
            ;;
        --uninstall)
            UNINSTALL="1"
            shift
            ;;
        -h|--help)
            printf 'Usage: q.sh [OPTIONS]\n\n'
            printf 'Options:\n'
            printf '  -y, --yes          Non-interactive mode (use defaults)\n'
            printf '  --token <string>   Set access token (skip prompt)\n'
            printf '  --no-service       Skip background service registration\n'
            printf '  --addr <address>   Listen address (default: 0.0.0.0)\n'
            printf '  --port <port>      Listen port (default: 8022)\n'
            printf '  --term <value>     TERM for tmux (default: screen-256color)\n'
            printf '  --lang <value>     LANG for tmux (default: en_US.UTF-8)\n'
            printf '  --check              Run environment checks without installing\n'
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
    read -r _answer </dev/tty || exit 130
    case "$_answer" in
        [Yy]*) return 0 ;;
        [Nn]*) return 1 ;;
        "")
            [ "$_default" = "y" ] && return 0 || return 1
            ;;
        *) return 1 ;;
    esac
}

validate_listen_addr() {
    _addr="$1"
    [ -n "$_addr" ] || return 1
    case "$_addr" in
        *[!A-Za-z0-9.:\-\[\]]*)
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

validate_terminal_value() {
    case "$1" in
        ''|*[!A-Za-z0-9._@:+-]*)
            return 1
            ;;
    esac
    return 0
}

validate_cli_options() {
    if [ -n "$OPT_TOKEN" ]; then
        validate_token "$OPT_TOKEN" || die "Invalid token: only printable non-whitespace characters are allowed."
    fi
    if [ -n "$OPT_ADDR" ]; then
        validate_listen_addr "$OPT_ADDR" || die "Invalid listen address: '$OPT_ADDR'"
    fi
    if [ -n "$OPT_PORT" ]; then
        validate_port "$OPT_PORT" || die "Invalid port: '$OPT_PORT'. Please enter a number between 1 and 65535."
    fi
    if [ -n "$OPT_TERM" ]; then
        validate_terminal_value "$OPT_TERM" || die "Invalid TERM: '$OPT_TERM'. Use only letters, numbers, dots, underscores, plus, colons, at-signs, and hyphens."
    fi
    if [ -n "$OPT_LANG" ]; then
        validate_terminal_value "$OPT_LANG" || die "Invalid LANG: '$OPT_LANG'. Use only letters, numbers, dots, underscores, plus, colons, at-signs, and hyphens."
    fi
}

validate_cli_terminal_overrides() {
    if [ -n "$OPT_LANG" ]; then
        command -v locale > /dev/null 2>&1 || die "Cannot validate LANG: 'locale' command not found."
        _normalized="$(echo "$OPT_LANG" | sed 's/UTF-/utf/; s/-//g')"
        if ! locale -a 2>/dev/null | grep -iq "^$(echo "$_normalized" | sed 's/\./\\./g')$" && \
           ! locale -a 2>/dev/null | grep -iq "^$(echo "$OPT_LANG" | sed 's/\./\\./g')$"; then
            die "Invalid LANG: '$OPT_LANG'. Locale is not available on this system."
        fi
    fi

    if [ -n "$OPT_TERM" ]; then
        command -v infocmp > /dev/null 2>&1 || die "Cannot validate TERM: 'infocmp' command not found."
        infocmp "$OPT_TERM" > /dev/null 2>&1 || die "Invalid TERM: '$OPT_TERM'. Terminfo entry not found on this system."
    fi
}

parse_addr_port() {
    _value="$1"
    PARSED_ADDR=""
    PARSED_PORT=""

    case "$_value" in
        \[*\]:*)
            PARSED_ADDR="$(printf '%s\n' "$_value" | sed 's/\]:[0-9][0-9]*$/]/')"
            PARSED_PORT="$(printf '%s\n' "$_value" | sed 's/.*\]://')"
            ;;
        *:*)
            PARSED_ADDR="${_value%:*}"
            PARSED_PORT="${_value##*:}"
            ;;
        *)
            return 1
            ;;
    esac

    validate_listen_addr "$PARSED_ADDR" && validate_port "$PARSED_PORT"
}

validate_existing_config() {
    if [ -n "$EXISTING_TOKEN" ]; then
        validate_token "$EXISTING_TOKEN" || die "Invalid QUICKTUI_TOKEN in existing config."
    fi

    if [ -n "$EXISTING_ADDR_RAW" ]; then
        parse_addr_port "$EXISTING_ADDR_RAW" || die "Invalid QUICKTUI_ADDR in existing config: '$EXISTING_ADDR_RAW'"
        EXISTING_ADDR="$PARSED_ADDR"
        EXISTING_PORT="$PARSED_PORT"
    fi

    if [ -n "$EXISTING_TERM" ]; then
        validate_terminal_value "$EXISTING_TERM" || die "Invalid QUICKTUI_TERM in existing config: '$EXISTING_TERM'"
        command -v infocmp > /dev/null 2>&1 || die "Cannot validate QUICKTUI_TERM in existing config: 'infocmp' command not found."
        infocmp "$EXISTING_TERM" > /dev/null 2>&1 || die "Invalid QUICKTUI_TERM in existing config: '$EXISTING_TERM'. Terminfo entry not found on this system."
    fi

    if [ -n "$EXISTING_LANG" ]; then
        validate_terminal_value "$EXISTING_LANG" || die "Invalid QUICKTUI_LANG in existing config: '$EXISTING_LANG'"
        command -v locale > /dev/null 2>&1 || die "Cannot validate QUICKTUI_LANG in existing config: 'locale' command not found."
        _normalized="$(echo "$EXISTING_LANG" | sed 's/UTF-/utf/; s/-//g')"
        if ! locale -a 2>/dev/null | grep -iq "^$(echo "$_normalized" | sed 's/\./\\./g')$" && \
           ! locale -a 2>/dev/null | grep -iq "^$(echo "$EXISTING_LANG" | sed 's/\./\\./g')$"; then
            die "Invalid QUICKTUI_LANG in existing config: '$EXISTING_LANG'. Locale is not available on this system."
        fi
    fi
}

validate_port() {
    _port="$1"
    case "$_port" in
        ''|*[!0-9]*)
            return 1
            ;;
    esac

    [ "$_port" -ge 1 ] && [ "$_port" -le 65535 ]
}

service_probe_url() {
    _probe_host="$LISTEN_ADDR"
    case "$_probe_host" in
        0.0.0.0)
            _probe_host="127.0.0.1"
            ;;
        "::"|"[::]")
            _probe_host="[::1]"
            ;;
        \[*\])
            ;;
        *:*)
            _probe_host="[$_probe_host]"
            ;;
    esac
    printf 'http://%s:%s/\n' "$_probe_host" "$LISTEN_PORT"
}

wait_for_service_ready() {
    _probe_url="$(service_probe_url)"
    _attempt=1
    while [ "$_attempt" -le 20 ]; do
        if command -v curl > /dev/null 2>&1; then
            if curl -fsS --max-time 2 "$_probe_url" > /dev/null 2>&1; then
                return 0
            fi
        elif command -v wget > /dev/null 2>&1; then
            if wget -q --timeout=2 -O - "$_probe_url" > /dev/null 2>&1; then
                return 0
            fi
        else
            return 1
        fi
        sleep 0.5
        _attempt=$((_attempt + 1))
    done
    return 1
}

download() {
    _url="$1"
    _dest="$2"
    _msg="${3:-Downloading}"
    # Start silent download in background
    if command -v curl > /dev/null 2>&1; then
        curl -fsSL "$_url" -o "$_dest" &
    elif command -v wget > /dev/null 2>&1; then
        wget -q "$_url" -O "$_dest" &
    else
        die "Neither curl nor wget found. Please install one and retry."
    fi
    _dl_pid=$!
    _BG_PID=$_dl_pid
    # Spinner while downloading
    _i=0
    while kill -0 "$_dl_pid" 2>/dev/null; do
        case $((_i % 4)) in
            0) _c='-' ;; 1) _c='\' ;; 2) _c='|' ;; 3) _c='/' ;;
        esac
        printf '\r  %s %s' "$_c" "$_msg"
        _i=$((_i + 1))
        sleep 0.1
    done
    wait "$_dl_pid"
    _dl_rc=$?
    _BG_PID=""
    printf '\r\033[K'
    return $_dl_rc
}


run_privileged() {
    if [ "$(id -u)" = "0" ]; then
        "$@"
    elif command -v sudo > /dev/null 2>&1; then
        if [ -n "$NON_INTERACTIVE" ]; then
            sudo -n "$@"
        else
            sudo "$@"
        fi
    else
        die "Root privileges required but 'sudo' is not available. Please run as root or install sudo."
    fi
}

# ============================================================
# Step 0: Detect existing installation (upgrade mode)
# ============================================================

detect_existing_binary() {
    _existing_binary="${HOME}/.local/bin/quicktui-server"
    [ -f "$_existing_binary" ] || return 1
    "$_existing_binary" --version 2>/dev/null || echo "unknown"
}

load_existing_config() {
    [ -f "$QUICKTUI_CONFIG_FILE" ] || return 1
    exec 3< "$QUICKTUI_CONFIG_FILE"
}

parse_existing_config_value() {
    _key="$1"
    _val="$2"

    case "$_key" in
        QUICKTUI_TOKEN) EXISTING_TOKEN="$_val" ;;
        QUICKTUI_ADDR) EXISTING_ADDR_RAW="$_val" ;;
        QUICKTUI_TERM) EXISTING_TERM="$_val" ;;
        QUICKTUI_LANG) EXISTING_LANG="$_val" ;;
        QUICKTUI_TMUX_BIN) EXISTING_TMUX_BIN="$_val" ;;
    esac
}

detect_existing_service_registration() {
    if [ -f "${HOME}/Library/LaunchAgents/ai.quicktui.plist" ] || \
       [ -f "${HOME}/.config/systemd/user/quicktui.service" ]; then
        return 0
    fi
    return 1
}

detect_existing_install() {
    if _old_version="$(detect_existing_binary)"; then
        IS_UPGRADE="1"
        info "Existing installation detected ($_old_version)"
    fi

    if load_existing_config; then
        while IFS='=' read -r _key _val; do
            parse_existing_config_value "$_key" "$_val"
        done <&3
        exec 3<&-
    fi

    validate_existing_config

    if detect_existing_service_registration; then
        EXISTING_SERVICE="1"
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

resolve_tmux_build_target() {
    _tmux_ver="${1:-${TMUX_BUILD_VERSION:-}}"

    TMUX_BUILD_OS="$PLATFORM"
    [ "$TMUX_BUILD_OS" = "darwin" ] && TMUX_BUILD_OS="macos"
    TMUX_BUILD_ARCH="$ARCH"
    [ "$TMUX_BUILD_ARCH" = "amd64" ] && TMUX_BUILD_ARCH="x86_64"

    TMUX_BUILD_FILENAME=""
    [ -n "$_tmux_ver" ] && TMUX_BUILD_FILENAME="tmux-${_tmux_ver}-${TMUX_BUILD_OS}-${TMUX_BUILD_ARCH}.tar.gz"
    return 0
}

fetch_tmux_release_version() {
    TMUX_BUILD_VERSION="${TMUX_BUILDS_VERSION:-}"
    if [ -z "$TMUX_BUILD_VERSION" ]; then
        _api_url="https://api.github.com/repos/tmux/tmux-builds/releases/latest"
        if command -v curl > /dev/null 2>&1; then
            TMUX_BUILD_VERSION="$(curl -fsSL "$_api_url" 2>/dev/null | \
                sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/p')"
        elif command -v wget > /dev/null 2>&1; then
            TMUX_BUILD_VERSION="$(wget -qO- "$_api_url" 2>/dev/null | \
                sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/p')"
        fi
        [ -z "$TMUX_BUILD_VERSION" ] && die "Failed to detect tmux version from GitHub."
    fi

    resolve_tmux_build_target "$TMUX_BUILD_VERSION"
}

download_tmux_archive() {
    TMUX_BUILD_BASE_URL="${TMUX_BUILDS_RELEASES:-https://github.com/tmux/tmux-builds/releases/latest/download}"
    TMUX_BUILD_TMPDIR="$(mktemp -d)"
    TMUX_BUILD_TARBALL="${TMUX_BUILD_TMPDIR}/tmux.tar.gz"

    download "${TMUX_BUILD_BASE_URL}/${TMUX_BUILD_FILENAME}" "$TMUX_BUILD_TARBALL" "Downloading tmux ${TMUX_BUILD_VERSION}..." || \
        { rm -rf "$TMUX_BUILD_TMPDIR"; die "Failed to download tmux binary."; }
}

install_tmux_archive() {
    mkdir -p "${HOME}/.local/tmux" "${HOME}/.local/bin"
    tar -xzf "$TMUX_BUILD_TARBALL" -C "${HOME}/.local/tmux"
    INSTALLED_TMUX_BIN="${HOME}/.local/tmux/tmux"
    chmod 755 "$INSTALLED_TMUX_BIN"
    ln -sf "$INSTALLED_TMUX_BIN" "${HOME}/.local/bin/tmux"
    rm -rf "$TMUX_BUILD_TMPDIR"
    info "tmux installed to ~/.local/tmux (symlinked to ~/.local/bin/tmux)"
}

install_tmux_from_builds() {
    resolve_tmux_build_target
    fetch_tmux_release_version
    download_tmux_archive
    install_tmux_archive
}

install_tmux() {
    _pkg_ok=""
    if [ "$PLATFORM" = "darwin" ]; then
        if command -v brew > /dev/null 2>&1; then
            if brew install tmux 2>/dev/null; then _pkg_ok=1; fi
        elif command -v port > /dev/null 2>&1; then
            if run_privileged port install tmux 2>/dev/null; then _pkg_ok=1; fi
        fi
    elif [ "$PLATFORM" = "linux" ]; then
        if command -v apt-get > /dev/null 2>&1; then
            if run_privileged apt-get update -q && run_privileged apt-get install -y tmux; then _pkg_ok=1; fi
        elif command -v yum > /dev/null 2>&1; then
            if run_privileged yum install -y tmux; then _pkg_ok=1; fi
        elif command -v dnf > /dev/null 2>&1; then
            if run_privileged dnf install -y tmux; then _pkg_ok=1; fi
        fi
    fi

    if [ -z "$_pkg_ok" ]; then
        warn "Package manager unavailable or failed; downloading tmux from GitHub."
        install_tmux_from_builds
        return
    fi
    info "tmux installed"
}

_find_tmux() {
    # 1. $PATH
    command -v tmux 2>/dev/null && return 0
    # 2. Well-known system paths
    for _p in /usr/local/bin/tmux /usr/bin/tmux; do
        if [ -x "$_p" ]; then
            printf '%s\n' "$_p"
            return 0
        fi
    done
    # 3. Previously installed by tmux-builds
    if [ -x "${HOME}/.local/bin/tmux" ]; then
        printf '%s\n' "${HOME}/.local/bin/tmux"
        return 0
    fi
    return 1
}

safe_existing_tmux_bin() {
    _tmux_bin="$1"
    [ -n "$_tmux_bin" ] || return 1
    [ -x "$_tmux_bin" ] || return 1

    _detected_tmux="$(_find_tmux 2>/dev/null || true)"
    [ "$_tmux_bin" = "$_detected_tmux" ] || [ "$_tmux_bin" = "${HOME}/.local/tmux/tmux" ]
}

check_tmux() {
    if ! _find_tmux > /dev/null; then
        warn "tmux is not installed."
        if confirm "Would you like to install tmux automatically?" y; then
            install_tmux
            if ! _find_tmux > /dev/null; then
                die "tmux installation completed, but tmux is still not found."
            fi
        else
            printf '\nPlease install tmux 3.2 or later and run this installer again.\n'
            printf '  macOS:  brew install tmux\n'
            printf '  Ubuntu: sudo apt install tmux\n'
            printf '  CentOS: sudo yum install tmux\n\n'
            exit 1
        fi
    fi

    _tmux_bin="$(_find_tmux)"
    _tmux_version="$("$_tmux_bin" -V 2>/dev/null | sed 's/tmux //')"
    _major="$(echo "$_tmux_version" | cut -d. -f1)"
    _minor="$(echo "$_tmux_version" | cut -d. -f2 | cut -d- -f1 | sed 's/[^0-9].*//')"

    if [ -n "$EXISTING_TMUX_BIN" ] && ! safe_existing_tmux_bin "$EXISTING_TMUX_BIN"; then
        warn "Ignoring untrusted QUICKTUI_TMUX_BIN from existing config."
        EXISTING_TMUX_BIN=""
    fi

    if [ "$_major" -lt 3 ] || { [ "$_major" -eq 3 ] && [ "$_minor" -lt 2 ]; }; then
        warn "tmux $_tmux_version detected, but QuickTUI requires tmux 3.2 or later."
        if ! confirm "Continue anyway? (some features may not work)"; then
            exit 1
        fi
    else
        info "tmux $_tmux_version detected"
    fi

    # Record explicit path when tmux is NOT in $PATH
    if [ -n "$INSTALLED_TMUX_BIN" ]; then
        TMUX_BIN_CONFIG="$INSTALLED_TMUX_BIN"
    elif [ -n "$EXISTING_TMUX_BIN" ] && _existing_ver="$("$EXISTING_TMUX_BIN" -V 2>/dev/null | sed 's/tmux //')" && \
         _ex_major="$(echo "$_existing_ver" | cut -d. -f1)" && \
         _ex_minor="$(echo "$_existing_ver" | cut -d. -f2 | cut -d- -f1 | sed 's/[^0-9].*//')" && \
         [ "$_ex_major" -ge 3 ] 2>/dev/null && \
         { [ "$_ex_major" -gt 3 ] || [ "$_ex_minor" -ge 2 ]; }; then
        TMUX_BIN_CONFIG="$EXISTING_TMUX_BIN"
    elif command -v tmux > /dev/null 2>&1; then
        TMUX_BIN_CONFIG=""
    else
        TMUX_BIN_CONFIG="$_tmux_bin"
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
    download "${QUICKTUI_RELEASES}/${BINARY_NAME}" "$_binary_path" "Downloading QuickTUI (${BINARY_NAME})..." || \
        die "Failed to download binary. Check your internet connection and try again."

    _file_size="$(du -sh "$_binary_path" 2>/dev/null | cut -f1)"
    printf '  File size: %s\n' "${_file_size:-unknown}"

    download "${QUICKTUI_RELEASES}/${BINARY_NAME}.sha256" "$_sha256_path" "Downloading checksum..." || \
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
# Step 3.5: Stop existing service before replacing binary
# ============================================================

stop_existing_service() {
    _binary="${HOME}/.local/bin/quicktui-server"
    _os="$(uname -s)"
    _launchd_plist="${HOME}/Library/LaunchAgents/ai.quicktui.plist"
    _systemd_service="${HOME}/.config/systemd/user/quicktui.service"

    # Try server binary's own uninstall-service first
    if [ -f "$_binary" ]; then
        "$_binary" --uninstall-service 2>/dev/null || true
    fi

    # Belt-and-suspenders: also stop via OS service manager
    if [ "$_os" = "Darwin" ]; then
        if [ -f "$_launchd_plist" ]; then
            launchctl bootout "gui/$(id -u)" "$_launchd_plist" >/dev/null 2>&1 || \
                launchctl unload "$_launchd_plist" >/dev/null 2>&1 || true
        fi
    else
        if [ -f "$_systemd_service" ]; then
            if command -v systemctl > /dev/null 2>&1; then
                systemctl --user stop quicktui >/dev/null 2>&1 || true
            fi
        fi
    fi
    info "Stopped existing service"
}

list_processes_for_binary() {
    _binary="$1"
    _target_file="$(mktemp)"
    printf '%s\n' "$_binary" > "$_target_file"
    if ps -axo pid= -o command= > /dev/null 2>&1; then
        ps -axo pid= -o command=
    else
        ps -eo pid= -o args=
    fi | awk -v self="$$" -v target_file="$_target_file" '
        BEGIN {
            getline target < target_file
            close(target_file)
        }
        {
            pid=$1
            $1=""
            sub(/^ +/, "", $0)
            if (pid != self && index($0, target) > 0) {
                print pid
            }
        }
    '
    rm -f "$_target_file"
}

stop_binary_processes() {
    _binary="$1"
    _pids="$(list_processes_for_binary "$_binary" || true)"
    [ -n "$_pids" ] || return 0

    printf '%s\n' "$_pids" | while IFS= read -r _pid; do
        [ -n "$_pid" ] && kill "$_pid" 2>/dev/null || true
    done

    _attempt=1
    while [ "$_attempt" -le 25 ]; do
        _remaining="$(list_processes_for_binary "$_binary" || true)"
        [ -z "$_remaining" ] && {
            info "Stopped existing QuickTUI processes"
            return 0
        }
        sleep 0.2
        _attempt=$((_attempt + 1))
    done

    printf '%s\n' "$_remaining" | while IFS= read -r _pid; do
        [ -n "$_pid" ] && kill -9 "$_pid" 2>/dev/null || true
    done

    _attempt=1
    while [ "$_attempt" -le 10 ]; do
        _remaining="$(list_processes_for_binary "$_binary" || true)"
        [ -z "$_remaining" ] && {
            info "Stopped existing QuickTUI processes"
            return 0
        }
        sleep 0.2
        _attempt=$((_attempt + 1))
    done

    die "Failed to stop running QuickTUI processes at $_binary."
}

# ============================================================
# Step 4: Install binary
# ============================================================

prepare_binary_swap_paths() {
    INSTALL_PATH="${HOME}/.local/bin/quicktui-server"
    mkdir -p "${HOME}/.local/bin"
    STAGED_BINARY_PATH="${HOME}/.local/bin/.quicktui-server.new.$$"
    BACKUP_BINARY_PATH="${HOME}/.local/bin/.quicktui-server.backup.$$"
}

stage_binary_candidate() {
    cp "$DOWNLOADED_BINARY" "$STAGED_BINARY_PATH"
    chmod 755 "$STAGED_BINARY_PATH"
}

validate_staged_binary() {
    if ! "$STAGED_BINARY_PATH" --version > /dev/null 2>&1; then
        rm -f "$STAGED_BINARY_PATH"
        die "Binary replacement failed: staged binary at $STAGED_BINARY_PATH is not functional."
    fi
}

swap_binary_with_backup() {
    if [ -f "$INSTALL_PATH" ]; then
        mv "$INSTALL_PATH" "$BACKUP_BINARY_PATH"
    fi

    if ! mv "$STAGED_BINARY_PATH" "$INSTALL_PATH"; then
        [ -f "$BACKUP_BINARY_PATH" ] && mv "$BACKUP_BINARY_PATH" "$INSTALL_PATH" || true
        rm -f "$STAGED_BINARY_PATH"
        die "Binary replacement failed: could not move new binary into place."
    fi
}

restore_previous_binary() {
    rm -f "$INSTALL_PATH"
    [ -f "$BACKUP_BINARY_PATH" ] && mv "$BACKUP_BINARY_PATH" "$INSTALL_PATH" || true
}

warn_if_local_bin_not_on_path() {
    case ":${PATH}:" in
        *":${HOME}/.local/bin:"*) ;;
        *)
            warn "~/.local/bin is not in your PATH."
            printf '  Add this to your shell config (~/.bashrc, ~/.zshrc, etc.):\n'
            printf '    export PATH="$HOME/.local/bin:$PATH"\n\n'
            ;;
    esac
}

install_binary() {
    INSTALL_PATH="${HOME}/.local/bin/quicktui-server"

    if [ -n "$IS_UPGRADE" ]; then
        stop_existing_service
        stop_binary_processes "$INSTALL_PATH"
    fi

    prepare_binary_swap_paths
    stage_binary_candidate
    validate_staged_binary
    swap_binary_with_backup

    if ! "$INSTALL_PATH" --version > /dev/null 2>&1; then
        restore_previous_binary
        die "Binary replacement failed: new binary at $INSTALL_PATH is not functional."
    fi

    rm -f "$BACKUP_BINARY_PATH"
    warn_if_local_bin_not_on_path

    DOWNLOAD_TMPDIR=""
    info "Installed to $INSTALL_PATH"
}

# ============================================================
# Step 5: Configure token
# ============================================================

validate_token() {
    case "$1" in
        *[!A-Za-z0-9._~:/?#@!\$\&\'*+,\;=%^-]*)
            return 1
            ;;
        "")
            return 1
            ;;
    esac
    return 0
}

generate_random_token_value() {
    if command -v openssl > /dev/null 2>&1; then
        TOKEN="$(openssl rand -hex 32)"
    else
        TOKEN="$(head -c 32 /dev/urandom | od -A n -t x1 | tr -d ' \n')"
    fi
}

resolve_token_value() {
    TOKEN=""
    TOKEN_INFO_MESSAGE=""
    TOKEN_NEEDS_PROMPT=""
    TOKEN_NEEDS_GENERATION=""

    if [ -n "$OPT_TOKEN" ]; then
        validate_token "$OPT_TOKEN" || die "Invalid token: only printable non-whitespace characters are allowed."
        TOKEN="$OPT_TOKEN"
        TOKEN_INFO_MESSAGE="Token configured (from argument)"
    elif [ -n "$IS_UPGRADE" ] && [ -n "$EXISTING_TOKEN" ]; then
        TOKEN="$EXISTING_TOKEN"
        TOKEN_INFO_MESSAGE="Token preserved from existing config"
    elif [ -n "$NON_INTERACTIVE" ]; then
        TOKEN_NEEDS_GENERATION="1"
    else
        TOKEN_NEEDS_PROMPT="1"
    fi
}

prompt_for_token_value() {
    [ -n "$TOKEN_NEEDS_PROMPT" ] || return 0

    printf '\nHow would you like to set up your access token?\n'
    printf '  [1] Generate a random token automatically  [default]\n'
    printf '  [2] Enter my own token\n'
    printf 'Enter choice [1]: '
    read -r _choice </dev/tty || exit 130
    _choice="${_choice:-1}"

    case "$_choice" in
        1)
            generate_random_token_value
            TOKEN_INFO_MESSAGE="Random token generated"
            ;;
        2)
            printf 'Enter your token: '
            read -r TOKEN </dev/tty || exit 130
            validate_token "$TOKEN" || die "Invalid token: only printable non-whitespace characters are allowed."
            TOKEN_INFO_MESSAGE="Token configured"
            ;;
        *)
            die "Invalid choice: $_choice"
            ;;
    esac
}

write_token_config() {
    mkdir -p "$QUICKTUI_CONFIG_DIR"
    chmod 700 "$QUICKTUI_CONFIG_DIR"
    printf 'QUICKTUI_TOKEN=%s\n' "$TOKEN" > "$QUICKTUI_CONFIG_FILE"
    chmod 600 "$QUICKTUI_CONFIG_FILE"
    info "Config saved to $QUICKTUI_CONFIG_FILE"
}

configure_token() {
    resolve_token_value
    if [ -n "$TOKEN_NEEDS_GENERATION" ]; then
        generate_random_token_value
        TOKEN_INFO_MESSAGE="Random token generated"
    fi
    prompt_for_token_value
    [ -n "$TOKEN_INFO_MESSAGE" ] && info "$TOKEN_INFO_MESSAGE"
    write_token_config
}

# ============================================================
# Step 6: Configure listen address
# ============================================================

resolve_listen_addr() {
    LISTEN_ADDR=""
    LISTEN_ADDR_DEFAULT="${OPT_ADDR:-${EXISTING_ADDR:-0.0.0.0}}"
    LISTEN_ADDR_NEEDS_PROMPT=""
    if [ -n "$OPT_ADDR" ]; then
        LISTEN_ADDR="$OPT_ADDR"
    elif [ -n "$IS_UPGRADE" ] && [ -n "$EXISTING_ADDR" ]; then
        LISTEN_ADDR="$EXISTING_ADDR"
    elif [ -n "$NON_INTERACTIVE" ]; then
        LISTEN_ADDR="0.0.0.0"
    else
        LISTEN_ADDR_NEEDS_PROMPT="1"
        return 0
    fi

    validate_listen_addr "$LISTEN_ADDR" || die "Invalid listen address: '$LISTEN_ADDR'"
}

prompt_for_listen_addr() {
    [ -n "$LISTEN_ADDR_NEEDS_PROMPT" ] || return 0
    printf '\nListen address [default: %s]: ' "$LISTEN_ADDR_DEFAULT"
    read -r LISTEN_ADDR </dev/tty || exit 130
    LISTEN_ADDR="${LISTEN_ADDR:-$LISTEN_ADDR_DEFAULT}"
    validate_listen_addr "$LISTEN_ADDR" || die "Invalid listen address: '$LISTEN_ADDR'"
}

resolve_listen_port() {
    LISTEN_PORT=""
    LISTEN_PORT_DEFAULT="${OPT_PORT:-${EXISTING_PORT:-8022}}"
    LISTEN_PORT_NEEDS_PROMPT=""
    if [ -n "$OPT_PORT" ]; then
        LISTEN_PORT="$OPT_PORT"
    elif [ -n "$IS_UPGRADE" ] && [ -n "$EXISTING_PORT" ]; then
        LISTEN_PORT="$EXISTING_PORT"
    elif [ -n "$NON_INTERACTIVE" ]; then
        LISTEN_PORT="8022"
    else
        LISTEN_PORT_NEEDS_PROMPT="1"
        return 0
    fi

    validate_port "$LISTEN_PORT" || die "Invalid port: '$LISTEN_PORT'. Please enter a number between 1 and 65535."
}

prompt_for_listen_port() {
    [ -n "$LISTEN_PORT_NEEDS_PROMPT" ] || return 0
    printf 'Port [default: %s]: ' "$LISTEN_PORT_DEFAULT"
    read -r LISTEN_PORT </dev/tty || exit 130
    LISTEN_PORT="${LISTEN_PORT:-$LISTEN_PORT_DEFAULT}"
    validate_port "$LISTEN_PORT" || die "Invalid port: '$LISTEN_PORT'. Please enter a number between 1 and 65535."
}

write_network_config() {
    printf 'QUICKTUI_ADDR=%s:%s\n' "$LISTEN_ADDR" "$LISTEN_PORT" >> "$QUICKTUI_CONFIG_FILE"
    info "Listen address: ${LISTEN_ADDR}:${LISTEN_PORT}"
}

configure_network() {
    resolve_listen_addr
    prompt_for_listen_addr
    resolve_listen_port
    prompt_for_listen_port
    write_network_config
}

# ============================================================
# Write terminal environment to config file
# ============================================================

write_terminal_config() {
    printf 'QUICKTUI_TERM=%s\n' "$TERM_ENV" >> "$QUICKTUI_CONFIG_FILE"
    printf 'QUICKTUI_LANG=%s\n' "$LANG_ENV" >> "$QUICKTUI_CONFIG_FILE"
    if [ -n "$TMUX_BIN_CONFIG" ]; then
        printf 'QUICKTUI_TMUX_BIN=%s\n' "$TMUX_BIN_CONFIG" >> "$QUICKTUI_CONFIG_FILE"
    fi
}

# ============================================================
# Collect terminal environment values (no config file writes)
# ============================================================

collect_terminal_env() {
    _interactive_lang="${LANG:-en_US.UTF-8}"
    if [ -n "$OPT_TERM" ]; then
        TERM_ENV="$OPT_TERM"
    elif [ -n "$IS_UPGRADE" ] && [ -n "$EXISTING_TERM" ]; then
        TERM_ENV="$EXISTING_TERM"
    else
        TERM_ENV="screen-256color"
    fi

    if [ -n "$OPT_LANG" ]; then
        LANG_ENV="$OPT_LANG"
    elif [ -n "$IS_UPGRADE" ] && [ -n "$EXISTING_LANG" ]; then
        LANG_ENV="$EXISTING_LANG"
    elif [ -n "$NON_INTERACTIVE" ]; then
        LANG_ENV="en_US.UTF-8"
    else
        printf '\nTerminal environment for tmux:\n'
        printf '  LANG [%s]: ' "$_interactive_lang"
        read -r _input </dev/tty || exit 130
        LANG_ENV="${_input:-$_interactive_lang}"
        validate_terminal_value "$LANG_ENV" || die "Invalid LANG: '$LANG_ENV'. Use only letters, numbers, dots, underscores, plus, colons, at-signs, and hyphens."
    fi

    info "Terminal: TERM=$TERM_ENV, LANG=$LANG_ENV"
}

# ============================================================
# Step 8: Configure and register background service
# ============================================================

configure_service() {
    if [ -n "$OPT_NO_SERVICE" ]; then
        SERVICE_STARTED="skipped"
        info "Skipped service registration (--no-service)"
        return 0
    fi

    if [ -z "$NON_INTERACTIVE" ] && [ -z "$EXISTING_SERVICE" ]; then
        printf '\n'
        if ! confirm "Would you like to register QuickTUI as a background service?" y; then
            SERVICE_STARTED="skipped"
            return 0
        fi
    fi

    # Delegate service registration to the server binary
    if "$INSTALL_PATH" --install-service \
        --addr "${LISTEN_ADDR}:${LISTEN_PORT}" \
        --term "$TERM_ENV" \
        --lang "$LANG_ENV"; then
        if wait_for_service_ready; then
            SERVICE_STARTED="yes"
        else
            SERVICE_STARTED="failed"
            SERVICE_FAILURE_REASON="startup"
            warn "Service was registered but did not become reachable at $(service_probe_url)"
            warn "You can retry manually:"
            warn "  $INSTALL_PATH --install-service --addr ${LISTEN_ADDR}:${LISTEN_PORT}"
        fi
    else
        SERVICE_STARTED="failed"
        SERVICE_FAILURE_REASON="registration"
        warn "Service registration failed. You can retry manually:"
        warn "  $INSTALL_PATH --install-service --addr ${LISTEN_ADDR}:${LISTEN_PORT}"
    fi
}

# ============================================================
# Step 9: Print success message
# ============================================================

print_success() {
    _version="$("$INSTALL_PATH" --version 2>/dev/null || echo "")"

    if [ -n "$IS_UPGRADE" ]; then
        printf '\n\033[0;32m✓ QuickTUI upgraded successfully!\033[0m\n\n'
    else
        printf '\n\033[0;32m✓ QuickTUI installed successfully!\033[0m\n\n'
    fi
    printf '  Binary:  %s\n' "$INSTALL_PATH"
    printf '  Config:  %s\n' "$QUICKTUI_CONFIG_FILE"
    [ -n "$_version" ] && printf '  Version: %s\n' "$_version"
    printf '\n'

    if [ "$SERVICE_STARTED" = "yes" ]; then
        _ip="$LISTEN_ADDR"
        if [ "$_ip" = "0.0.0.0" ] || [ -z "$_ip" ]; then
            if [ "$PLATFORM" = "darwin" ]; then
                _ip="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "")"
            else
                _ip="$(hostname -I 2>/dev/null | awk '{print $1}' || echo "")"
            fi
            [ -z "$_ip" ] && _ip="localhost"
        fi
        printf 'Getting started:\n'
        printf '  Open in browser:  http://%s:%s\n' "$_ip" "$LISTEN_PORT"
        if [ -n "$IS_UPGRADE" ] && [ "$TOKEN" = "$EXISTING_TOKEN" ]; then
            printf '  Token:            (unchanged)\n'
        else
            printf '  Token:            %s\n' "$TOKEN"
            printf '  (Enter the token when prompted on first login)\n'
        fi
    elif [ "$SERVICE_STARTED" = "failed" ]; then
        if [ "$SERVICE_FAILURE_REASON" = "startup" ]; then
            printf 'Service was registered but did not start successfully. Start manually:\n'
        else
            printf 'Service registration failed. Start manually:\n'
        fi
        if [ "$PLATFORM" = "darwin" ]; then
            printf '  launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/ai.quicktui.plist\n'
        else
            printf '  systemctl --user start quicktui\n'
        fi
        if [ -n "$IS_UPGRADE" ] && [ "$TOKEN" = "$EXISTING_TOKEN" ]; then
            printf '  Token:            (unchanged)\n'
        else
            printf '  Token: %s\n' "$TOKEN"
        fi
    else
        printf 'To start QuickTUI, run:\n'
        printf '  QUICKTUI_TOKEN=%s %s\n' "$(shell_quote "$TOKEN")" "$(shell_quote "$INSTALL_PATH")"
    fi

    printf '\n'
    printf 'iOS App:\n'
    printf '  App Store:  https://apps.apple.com/app/quicktui/id6761338192\n'
    printf '\n'
}

# ============================================================
# Uninstall
# ============================================================

uninstall() {
    printf '\n\033[1mQuickTUI Uninstaller\033[0m\n\n'

    _removed=0
    _binary="${HOME}/.local/bin/quicktui-server"
    _os="$(uname -s)"
    _launchd_plist="${HOME}/Library/LaunchAgents/ai.quicktui.plist"
    _systemd_service="${HOME}/.config/systemd/user/quicktui.service"
    _systemd_link="${HOME}/.config/systemd/user/default.target.wants/quicktui.service"

    # Stop and unregister service
    if [ -f "$_binary" ]; then
        stop_existing_service
        _removed=1
    fi

    # Remove service files
    if [ "$_os" = "Darwin" ]; then
        if [ -f "$_launchd_plist" ]; then
            rm -f "$_launchd_plist"
            info "Removed: $_launchd_plist"
            _removed=1
        fi
    else
        if [ -f "$_systemd_service" ] || [ -L "$_systemd_link" ]; then
            rm -f "$_systemd_link"
            rm -f "$_systemd_service"
            if command -v systemctl > /dev/null 2>&1; then
                systemctl --user daemon-reload >/dev/null 2>&1 || true
            fi
            info "Removed: ${HOME}/.config/systemd/user/quicktui.service"
            _removed=1
        fi
    fi

    # Remove log directory (macOS)
    _log_dir="${HOME}/Library/Logs/QuickTUI"
    if [ -d "$_log_dir" ]; then
        rm -rf "$_log_dir"
        info "Removed: $_log_dir"
        _removed=1
    fi

    # Remove binary
    if [ -f "$_binary" ]; then
        rm -f "$_binary"
        info "Removed: $_binary"
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
# Environment preflight checks
# ============================================================

preflight_check_locale() {
    if command -v locale > /dev/null 2>&1; then
        _normalized="$(echo "$LANG_ENV" | sed 's/UTF-/utf/; s/-//g')"
        if locale -a 2>/dev/null | grep -iq "^$(echo "$_normalized" | sed 's/\./\\./g')$" || \
           locale -a 2>/dev/null | grep -iq "^$(echo "$LANG_ENV" | sed 's/\./\\./g')$"; then
            info "Locale $LANG_ENV available"
        else
            warn "Locale \"$LANG_ENV\" is not available on this system, falling back to C.UTF-8."
            LANG_ENV="C.UTF-8"
        fi
    else
        printf '    - Locale check skipped (locale command not found)\n'
    fi
}

preflight_check_terminfo() {
    if command -v infocmp > /dev/null 2>&1; then
        if infocmp "$TERM_ENV" > /dev/null 2>&1; then
            info "Terminfo $TERM_ENV found"
        else
            warn "Terminfo entry for \"$TERM_ENV\" not found, falling back to screen-256color."
            TERM_ENV="screen-256color"
        fi
    else
        printf '    - Terminfo check skipped (infocmp command not found)\n'
    fi
}

preflight_check_default_shell() {
    _check_shell="${SHELL:-/bin/sh}"
    if [ -x "$_check_shell" ]; then
        info "Default shell $_check_shell OK"
    else
        warn "Default shell \"$_check_shell\" is not executable."
        printf '    Set the SHELL environment variable to a valid shell path, or install the missing shell.\n'
        _preflight_warnings=$((_preflight_warnings + 1))
    fi
}

preflight_check_pty() {
    if [ "$PLATFORM" = "darwin" ]; then
        _pty_ok=""
        script -q /dev/null sh -c 'exit 0' < /dev/null > /dev/null 2>&1 && _pty_ok=1
    else
        _pty_ok=""
        script -qc 'exit 0' /dev/null < /dev/null > /dev/null 2>&1 && _pty_ok=1
    fi
    if [ -n "$_pty_ok" ]; then
        info "PTY allocation OK"
    else
        warn "Cannot allocate a pseudo-terminal (PTY)."
        printf '    Check system PTY limits (Linux: /proc/sys/kernel/pty/max) or container configuration.\n'
        printf '    Some container runtimes need --privileged or explicit /dev/pts mount.\n'
        _preflight_warnings=$((_preflight_warnings + 1))
    fi
}

preflight_check_tmux_session() {
    _tmux_check_bin="${TMUX_BIN_CONFIG:-tmux}"
    if command -v "$_tmux_check_bin" > /dev/null 2>&1 || [ -x "$_tmux_check_bin" ]; then
        _tmux_stderr="$(TERM="$TERM_ENV" LANG="$LANG_ENV" LC_ALL="$LANG_ENV" "$_tmux_check_bin" new-session -d -s _qtui_preflight 2>&1)"
        _tmux_rc=$?
        "$_tmux_check_bin" kill-session -t _qtui_preflight 2>/dev/null || true
        if [ "$_tmux_rc" -eq 0 ]; then
            info "tmux session test passed"
        else
            warn "tmux failed to start a test session."
            [ -n "$_tmux_stderr" ] && printf '    %s\n' "$_tmux_stderr"
            _preflight_warnings=$((_preflight_warnings + 1))
        fi
    else
        warn "tmux binary not found at \"$_tmux_check_bin\"."
        _preflight_warnings=$((_preflight_warnings + 1))
    fi
}

preflight_finalize() {
    if [ "$_preflight_warnings" -gt 0 ]; then
        printf '\n'
        warn "$_preflight_warnings issue(s) found. Some features may not work correctly."

        if [ -n "$CHECK_ONLY" ]; then
            return 1
        elif [ -z "$NON_INTERACTIVE" ]; then
            if ! confirm "Continue installation?" n; then
                exit 1
            fi
        fi
    fi
    printf '\n'
    return 0
}

preflight_checks() {
    printf '\n  Environment checks:\n'
    _preflight_warnings=0

    preflight_check_locale
    preflight_check_terminfo
    preflight_check_default_shell
    preflight_check_pty
    preflight_check_tmux_session
    preflight_finalize
}

# ============================================================
# Main
# ============================================================

main() {
    validate_cli_options
    validate_cli_terminal_overrides
    detect_existing_install
    if [ -n "$IS_UPGRADE" ]; then
        printf '\n\033[1mQuickTUI Upgrader\033[0m\n\n'
    else
        printf '\n\033[1mQuickTUI Installer\033[0m\n\n'
    fi
    detect_platform
    check_tmux
    collect_terminal_env
    preflight_checks
    download_binary
    install_binary
    configure_token
    configure_network
    write_terminal_config
    configure_service
    print_success
}

if [ -n "$UNINSTALL" ]; then
    uninstall
elif [ -n "$CHECK_ONLY" ]; then
    validate_cli_options
    validate_cli_terminal_overrides
    detect_existing_install
    detect_platform
    check_tmux
    TERM_ENV="${OPT_TERM:-${EXISTING_TERM:-screen-256color}}"
    LANG_ENV="${OPT_LANG:-${EXISTING_LANG:-en_US.UTF-8}}"
    preflight_checks
    exit $?
else
    main
fi
