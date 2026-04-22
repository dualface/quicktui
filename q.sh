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
OPT_ROTATE_TOKEN=""
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

_BG_PID=""
_STTY_SAVED=""
cleanup() {
    if [ -n "$_STTY_SAVED" ] && command -v stty > /dev/null 2>&1; then
        stty "$_STTY_SAVED" 2>/dev/null || true
        _STTY_SAVED=""
    fi
    [ -n "$_BG_PID" ] && kill "$_BG_PID" 2>/dev/null || true
    [ -n "$DOWNLOAD_TMPDIR" ] && rm -rf "$DOWNLOAD_TMPDIR" || true
}
# INT/TERM traps clear the EXIT trap first so cleanup runs exactly once.
trap 'trap - EXIT; cleanup; exit 130' INT TERM
trap cleanup EXIT

# ============================================================
# Color handling (respects https://no-color.org/)
# ============================================================

if [ -n "${NO_COLOR:-}" ]; then
    C_RESET='' C_GREEN='' C_YELLOW='' C_RED='' C_BOLD=''
else
    C_RESET="$(printf '\033[0m')"
    C_GREEN="$(printf '\033[0;32m')"
    C_YELLOW="$(printf '\033[0;33m')"
    C_RED="$(printf '\033[0;31m')"
    C_BOLD="$(printf '\033[1m')"
fi

# ============================================================
# Utility functions
# ============================================================

info() {
    printf '%s  ✓%s %s\n' "$C_GREEN" "$C_RESET" "$1"
}

warn() {
    printf '%s  !%s %s\n' "$C_YELLOW" "$C_RESET" "$1"
}

error() {
    printf '%sError:%s %s\n' "$C_RED" "$C_RESET" "$1" >&2
}

die() {
    error "$1"
    exit 1
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
        --rotate-token)
            OPT_ROTATE_TOKEN="1"
            shift
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
            printf '  --rotate-token     Generate a fresh random token (overrides preserved token on upgrade)\n'
            printf '  --no-service       Skip background service registration\n'
            printf '  --addr <address>   Listen address (default: 0.0.0.0)\n'
            printf '  --port <port>      Listen port (default: 8022)\n'
            printf '  --term <value>     TERM for tmux (default: screen-256color)\n'
            printf '  --lang <value>     LANG for tmux (default: en_US.UTF-8)\n'
            printf '  --check            Run environment checks without installing\n'
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
    read -r _answer </dev/tty || exit 1
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
        *[!A-Za-z0-9.:\-\[\]]*) return 1 ;;
    esac
    # IPv6 brackets must be balanced and wrap the whole value.
    case "$_addr" in
        \[*\]) return 0 ;;
        \[*|*\]) return 1 ;;
    esac
    # Dotted-quad candidate: require exactly four numeric octets 0-255.
    case "$_addr" in
        *.*.*.*)
            _rest="$_addr"
            _o1="${_rest%%.*}"; _rest="${_rest#*.}"
            _o2="${_rest%%.*}"; _rest="${_rest#*.}"
            _o3="${_rest%%.*}"; _rest="${_rest#*.}"
            _o4="$_rest"
            case "$_o4" in *.*) return 1 ;; esac
            for _oct in "$_o1" "$_o2" "$_o3" "$_o4"; do
                case "$_oct" in
                    ''|*[!0-9]*) return 1 ;;
                esac
                [ "$_oct" -ge 0 ] && [ "$_oct" -le 255 ] || return 1
            done
            return 0
            ;;
    esac
    # Hostname-like values (letters, digits, dashes, dots) are accepted
    # without further semantic checks; the server rejects bad DNS names.
    return 0
}

validate_terminal_value() {
    case "$1" in
        ''|*[!A-Za-z0-9._@:+-]*)
            return 1
            ;;
    esac
    return 0
}

locale_available() {
    _value="$1"
    _normalized="$(printf '%s\n' "$_value" | sed 's/UTF-/utf/; s/-//g')"
    locale -a 2>/dev/null | grep -iq "^$(printf '%s\n' "$_normalized" | sed 's/\./\\./g')$" || \
        locale -a 2>/dev/null | grep -iq "^$(printf '%s\n' "$_value" | sed 's/\./\\./g')$"
}

require_locale_available() {
    _label="$1"
    _value="$2"
    command -v locale > /dev/null 2>&1 || die "Cannot validate ${_label}: 'locale' command not found."
    locale_available "$_value" || die "Invalid ${_label}: '$_value'. Locale is not available on this system."
}

require_terminfo_available() {
    _label="$1"
    _value="$2"
    command -v infocmp > /dev/null 2>&1 || die "Cannot validate ${_label}: 'infocmp' command not found."
    infocmp "$_value" > /dev/null 2>&1 || die "Invalid ${_label}: '$_value'. Terminfo entry not found on this system."
}

validate_cli_options() {
    if [ -n "$OPT_TOKEN" ] && [ -n "$OPT_ROTATE_TOKEN" ]; then
        die "--token and --rotate-token are mutually exclusive."
    fi
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
        require_locale_available "LANG" "$OPT_LANG"
    fi
    if [ -n "$OPT_TERM" ]; then
        require_terminfo_available "TERM" "$OPT_TERM"
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
        require_terminfo_available "QUICKTUI_TERM in existing config" "$EXISTING_TERM"
    fi

    if [ -n "$EXISTING_LANG" ]; then
        validate_terminal_value "$EXISTING_LANG" || die "Invalid QUICKTUI_LANG in existing config: '$EXISTING_LANG'"
        require_locale_available "QUICKTUI_LANG in existing config" "$EXISTING_LANG"
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
    # Probe /healthz first (conventional health endpoint), then fall back
    # to / for servers that only expose a web UI at the root.
    _probe_base="$(service_probe_url)"
    _probe_base="${_probe_base%/}"
    _attempt=1
    while [ "$_attempt" -le 20 ]; do
        for _path in /healthz /; do
            _full="${_probe_base}${_path}"
            if command -v curl > /dev/null 2>&1; then
                if curl -fsS --max-time 2 "$_full" > /dev/null 2>&1; then
                    return 0
                fi
            elif command -v wget > /dev/null 2>&1; then
                if wget -q --timeout=2 -O - "$_full" > /dev/null 2>&1; then
                    return 0
                fi
            else
                return 1
            fi
        done
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

detect_existing_install() {
    _existing_binary="${HOME}/.local/bin/quicktui-server"
    if [ -f "$_existing_binary" ]; then
        IS_UPGRADE="1"
        _old_version="$("$_existing_binary" --version 2>/dev/null || echo "unknown")"
        info "Existing installation detected ($_old_version)"
    fi

    if [ -f "$QUICKTUI_CONFIG_FILE" ]; then
        while IFS='=' read -r _key _val; do
            case "$_key" in
                QUICKTUI_TOKEN) EXISTING_TOKEN="$_val" ;;
                QUICKTUI_ADDR) EXISTING_ADDR_RAW="$_val" ;;
                QUICKTUI_TERM) EXISTING_TERM="$_val" ;;
                QUICKTUI_LANG) EXISTING_LANG="$_val" ;;
                QUICKTUI_TMUX_BIN) EXISTING_TMUX_BIN="$_val" ;;
            esac
        done < "$QUICKTUI_CONFIG_FILE"
    fi

    validate_existing_config

    if [ -f "${HOME}/Library/LaunchAgents/ai.quicktui.plist" ] || \
       [ -f "${HOME}/.config/systemd/user/quicktui.service" ]; then
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

# Pinned tmux-builds baseline. tmux-builds does not publish checksum files,
# so the installer enforces its own pinned SHA-256 by default. Bump both the
# version and the four SHA-256 lines together when upgrading.
TMUX_BUILDS_DEFAULT_VERSION="3.6a"

tmux_builds_pinned_sha256() {
    case "$1-$2" in
        linux-arm64)  printf '%s\n' 'bb5afd9d646df54a7d7c66e198aa22c7d293c7453534f1670f7c540534db8b5e' ;;
        linux-x86_64) printf '%s\n' 'c0a772a5e6ca8f129b0111d10029a52e02bcbc8352d5a8c0d3de8466a1e59c2e' ;;
        macos-arm64)  printf '%s\n' '12b5b9f8696e1286897d946649c0a80d0169dd76e018d34476a1fbd34de89a0f' ;;
        macos-x86_64) printf '%s\n' 'b9b12eaeba43acf5671acf3857d947525440b544185a8db34ea557199a090251' ;;
        *) return 1 ;;
    esac
}

install_tmux_from_builds() {
    _tmux_os="$PLATFORM"
    [ "$_tmux_os" = "darwin" ] && _tmux_os="macos"
    _tmux_arch="$ARCH"
    [ "$_tmux_arch" = "amd64" ] && _tmux_arch="x86_64"

    _tmux_ver="${TMUX_BUILDS_VERSION:-$TMUX_BUILDS_DEFAULT_VERSION}"
    _expected_sha=""
    if [ -n "${TMUX_BUILDS_SHA256:-}" ]; then
        _expected_sha="$(normalize_sha256 "$TMUX_BUILDS_SHA256")"
    elif [ "$_tmux_ver" = "$TMUX_BUILDS_DEFAULT_VERSION" ]; then
        _expected_sha="$(tmux_builds_pinned_sha256 "$_tmux_os" "$_tmux_arch" || true)"
        [ -n "$_expected_sha" ] || die "No pinned tmux checksum for ${_tmux_os}-${_tmux_arch}. Set TMUX_BUILDS_VERSION and TMUX_BUILDS_SHA256 explicitly, or TMUX_BUILDS_ALLOW_UNVERIFIED=1 to bypass at your own risk."
    else
        if [ "${TMUX_BUILDS_ALLOW_UNVERIFIED:-}" != "1" ]; then
            die "TMUX_BUILDS_VERSION=$_tmux_ver overrides the pinned default ($TMUX_BUILDS_DEFAULT_VERSION). Set TMUX_BUILDS_SHA256=<hex> to verify it, or TMUX_BUILDS_ALLOW_UNVERIFIED=1 to bypass verification at your own risk."
        fi
        warn "Downloading unpinned tmux $_tmux_ver without checksum verification (TMUX_BUILDS_ALLOW_UNVERIFIED=1)."
    fi

    _tmux_base_url="${TMUX_BUILDS_RELEASES:-https://github.com/tmux/tmux-builds/releases/download/v${_tmux_ver}}"
    _tmux_filename="tmux-${_tmux_ver}-${_tmux_os}-${_tmux_arch}.tar.gz"
    _tmux_tmpdir="$(mktemp -d)"
    _tmux_tarball="${_tmux_tmpdir}/tmux.tar.gz"

    download "${_tmux_base_url}/${_tmux_filename}" "$_tmux_tarball" "Downloading tmux ${_tmux_ver}..." || \
        { rm -rf "$_tmux_tmpdir"; die "Failed to download tmux binary."; }

    if [ -n "$_expected_sha" ]; then
        _actual_sha="$(normalize_sha256 "$(sha256_file "$_tmux_tarball")")"
        if [ "$_actual_sha" != "$_expected_sha" ]; then
            rm -rf "$_tmux_tmpdir"
            die "tmux checksum verification failed (expected $_expected_sha, got $_actual_sha)."
        fi
    fi

    # Reject tarballs containing absolute paths or parent-directory traversal
    # before extracting (BSD tar on macOS and GNU tar on Linux differ on defaults).
    # Capture the listing first so a `tar -tzf` failure is surfaced instead of
    # silently falling through an empty pipe.
    _tar_list="$(tar -tzf "$_tmux_tarball" 2>&1)" || {
        rm -rf "$_tmux_tmpdir"
        die "tmux tarball is unreadable: $_tar_list"
    }
    if ! printf '%s\n' "$_tar_list" | awk '
        /^\// { exit 1 }
        /(^|\/)\.\.(\/|$)/ { exit 1 }
    '; then
        rm -rf "$_tmux_tmpdir"
        die "tmux tarball contains unsafe paths; aborting."
    fi

    mkdir -p "${HOME}/.local/tmux" "${HOME}/.local/bin"
    tar -xzf "$_tmux_tarball" -C "${HOME}/.local/tmux" --no-same-owner
    INSTALLED_TMUX_BIN="${HOME}/.local/tmux/tmux"
    chmod 755 "$INSTALLED_TMUX_BIN"
    ln -sf "$INSTALLED_TMUX_BIN" "${HOME}/.local/bin/tmux"
    rm -rf "$_tmux_tmpdir"
    info "tmux $_tmux_ver installed to ~/.local/tmux (symlinked to ~/.local/bin/tmux)"
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
            # Single sudo invocation covers both update and install so the
            # user is prompted for a password at most once.
            if run_privileged sh -c 'apt-get update -q && apt-get install -y tmux'; then _pkg_ok=1; fi
        elif command -v dnf > /dev/null 2>&1; then
            if run_privileged dnf install -y tmux; then _pkg_ok=1; fi
        elif command -v yum > /dev/null 2>&1; then
            if run_privileged yum install -y tmux; then _pkg_ok=1; fi
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

    # The installer would invoke this binary later anyway (for -V and the
    # preflight session test), so probing -V here adds no new exec surface.
    # Require the output to look like a real tmux build so arbitrary
    # executables cannot be smuggled in via the config file.
    _ver_output="$("$_tmux_bin" -V 2>/dev/null)"
    case "$_ver_output" in
        tmux\ [0-9]*) return 0 ;;
        *) return 1 ;;
    esac
}

check_tmux() {
    if ! _find_tmux > /dev/null; then
        warn "tmux is not installed."
        if [ -n "$CHECK_ONLY" ]; then
            return 0
        fi
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
    [ -n "$_major" ] && [ -n "$_minor" ] || die "Could not parse tmux version from '$_tmux_bin -V' output: '$_tmux_version'."

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
    _expected_hash="$(normalize_sha256 "$(awk '{print $1}' "${_sha256_path}")")"
    _actual_hash="$(normalize_sha256 "$(sha256_file "$_binary_path")")"
    [ "$_actual_hash" = "$_expected_hash" ] || {
        rm -rf "$DOWNLOAD_TMPDIR"
        die "Checksum verification failed. The downloaded file may be corrupted."
    }

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

# Restart a service unit that was previously registered (used during
# install rollback so the user is not left with a stopped service).
restart_existing_service() {
    _os="$(uname -s)"
    _launchd_plist="${HOME}/Library/LaunchAgents/ai.quicktui.plist"
    _systemd_service="${HOME}/.config/systemd/user/quicktui.service"
    if [ "$_os" = "Darwin" ]; then
        if [ -f "$_launchd_plist" ]; then
            launchctl bootstrap "gui/$(id -u)" "$_launchd_plist" >/dev/null 2>&1 || \
                launchctl load "$_launchd_plist" >/dev/null 2>&1 || true
        fi
    else
        if [ -f "$_systemd_service" ] && command -v systemctl > /dev/null 2>&1; then
            systemctl --user start quicktui >/dev/null 2>&1 || true
        fi
    fi
}

list_processes_for_binary() {
    _binary="$1"
    _binary_base="${_binary##*/}"
    _self_uid="$(id -u)"
    # Filter by numeric uid (usernames get truncated to 8 chars on older
    # Linux procps). Force full command lines with -ww so argv[1] isn't
    # clipped at the terminal width when the installer runs in a pipeline.
    # Match rules:
    #   1. argv[0] equals the full install path, or
    #   2. argv[0] basename equals our binary basename, or
    #   3. argv[0] is a known shell interpreter AND argv[1] equals the
    #      full install path (no basename fallback on this branch, to
    #      avoid false positives like `grep quicktui-server`).
    {
        if ps -axww -o pid= -o uid= -o command= > /dev/null 2>&1; then
            ps -axww -o pid= -o uid= -o command=
        else
            ps -eww -o pid= -o uid= -o args=
        fi
    } | awk \
        -v self="$$" \
        -v uid="$_self_uid" \
        -v target_abs="$_binary" \
        -v target_base="$_binary_base" '
        {
            pid=$1
            usr=$2
            if (pid == self) next
            if (usr != uid) next
            argv0=$3
            if (argv0 == target_abs) { print pid; next }
            n=split(argv0, parts, "/")
            argv0_base=parts[n]
            if (argv0_base == target_base) { print pid; next }
            if (argv0_base == "sh" || argv0_base == "bash" || \
                argv0_base == "dash" || argv0_base == "zsh" || \
                argv0_base == "ksh") {
                if ($4 == target_abs) print pid
            }
        }
    '
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

install_binary() {
    INSTALL_PATH="${HOME}/.local/bin/quicktui-server"
    _staged_path="${HOME}/.local/bin/.quicktui-server.new.$$"
    _backup_path="${HOME}/.local/bin/.quicktui-server.backup.$$"
    mkdir -p "${HOME}/.local/bin"

    if [ -n "$IS_UPGRADE" ]; then
        stop_existing_service
        stop_binary_processes "$INSTALL_PATH"
    fi

    cp "$DOWNLOADED_BINARY" "$_staged_path"
    chmod 755 "$_staged_path"
    if ! "$_staged_path" --version > /dev/null 2>&1; then
        rm -f "$_staged_path"
        die "Binary replacement failed: staged binary at $_staged_path is not functional."
    fi
    if [ -f "$INSTALL_PATH" ]; then
        mv "$INSTALL_PATH" "$_backup_path"
    fi
    if ! mv "$_staged_path" "$INSTALL_PATH"; then
        if [ -f "$_backup_path" ]; then
            mv "$_backup_path" "$INSTALL_PATH" || true
            [ -n "$IS_UPGRADE" ] && [ -n "$EXISTING_SERVICE" ] && restart_existing_service
        fi
        rm -f "$_staged_path"
        die "Binary replacement failed: could not move new binary into place."
    fi

    if ! "$INSTALL_PATH" --version > /dev/null 2>&1; then
        rm -f "$INSTALL_PATH"
        if [ -f "$_backup_path" ]; then
            mv "$_backup_path" "$INSTALL_PATH" || true
            [ -n "$IS_UPGRADE" ] && [ -n "$EXISTING_SERVICE" ] && restart_existing_service
        fi
        die "Binary replacement failed: new binary at $INSTALL_PATH is not functional."
    fi

    rm -f "$_backup_path"
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

configure_token() {
    if [ -n "$OPT_TOKEN" ]; then
        TOKEN="$OPT_TOKEN"
        info "Token configured (from argument)"
    elif [ -n "$OPT_ROTATE_TOKEN" ]; then
        generate_random_token_value
        info "Token rotated (new random value)"
    elif [ -n "$IS_UPGRADE" ] && [ -n "$EXISTING_TOKEN" ]; then
        TOKEN="$EXISTING_TOKEN"
        info "Token preserved from existing config"
    elif [ -n "$NON_INTERACTIVE" ]; then
        generate_random_token_value
        info "Random token generated"
    else
        printf '\nHow would you like to set up your access token?\n'
        printf '  [1] Generate a random token automatically  [default]\n'
        printf '  [2] Enter my own token\n'
        printf 'Enter choice [1]: '
        read -r _choice </dev/tty || exit 1
        _choice="${_choice:-1}"

        case "$_choice" in
            1)
                generate_random_token_value
                info "Random token generated"
                ;;
            2)
                printf 'Enter your token: '
                # Suppress echo so the token does not land in the terminal's
                # scrollback. Restores terminal state even on Ctrl-C via the
                # cleanup trap (see _STTY_SAVED).
                _echo_suppressed=""
                if command -v stty > /dev/null 2>&1; then
                    _STTY_SAVED="$(stty -g </dev/tty 2>/dev/null || true)"
                    if [ -n "$_STTY_SAVED" ] && stty -echo </dev/tty 2>/dev/null; then
                        _echo_suppressed="1"
                    else
                        _STTY_SAVED=""
                    fi
                fi
                read -r TOKEN </dev/tty || {
                    if [ -n "$_echo_suppressed" ]; then
                        stty "$_STTY_SAVED" </dev/tty 2>/dev/null || true
                        _STTY_SAVED=""
                        printf '\n'
                    fi
                    exit 1
                }
                if [ -n "$_echo_suppressed" ]; then
                    stty "$_STTY_SAVED" </dev/tty 2>/dev/null || true
                    _STTY_SAVED=""
                    printf '\n'
                fi
                validate_token "$TOKEN" || die "Invalid token: only printable non-whitespace characters are allowed."
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
# Step 6: Configure listen address
# ============================================================

configure_network() {
    # Each value comes from exactly one source (CLI > existing config during
    # upgrade > non-interactive default > interactive prompt). Interactive
    # values validate inline so a bad address aborts before the next prompt;
    # the final validation covers the other sources as a defence in depth.
    if [ -n "$OPT_ADDR" ]; then
        LISTEN_ADDR="$OPT_ADDR"
    elif [ -n "$IS_UPGRADE" ] && [ -n "$EXISTING_ADDR" ]; then
        LISTEN_ADDR="$EXISTING_ADDR"
    elif [ -n "$NON_INTERACTIVE" ]; then
        LISTEN_ADDR="0.0.0.0"
    else
        _default_addr="${EXISTING_ADDR:-0.0.0.0}"
        printf '\nListen address [default: %s]: ' "$_default_addr"
        read -r LISTEN_ADDR </dev/tty || exit 1
        LISTEN_ADDR="${LISTEN_ADDR:-$_default_addr}"
        validate_listen_addr "$LISTEN_ADDR" || die "Invalid listen address: '$LISTEN_ADDR'"
    fi

    if [ -n "$OPT_PORT" ]; then
        LISTEN_PORT="$OPT_PORT"
    elif [ -n "$IS_UPGRADE" ] && [ -n "$EXISTING_PORT" ]; then
        LISTEN_PORT="$EXISTING_PORT"
    elif [ -n "$NON_INTERACTIVE" ]; then
        LISTEN_PORT="8022"
    else
        _default_port="${EXISTING_PORT:-8022}"
        printf 'Port [default: %s]: ' "$_default_port"
        read -r LISTEN_PORT </dev/tty || exit 1
        LISTEN_PORT="${LISTEN_PORT:-$_default_port}"
        validate_port "$LISTEN_PORT" || die "Invalid port: '$LISTEN_PORT'. Please enter a number between 1 and 65535."
    fi

    validate_listen_addr "$LISTEN_ADDR" || die "Invalid listen address: '$LISTEN_ADDR'"
    validate_port "$LISTEN_PORT" || die "Invalid port: '$LISTEN_PORT'. Please enter a number between 1 and 65535."

    printf 'QUICKTUI_ADDR=%s:%s\n' "$LISTEN_ADDR" "$LISTEN_PORT" >> "$QUICKTUI_CONFIG_FILE"
    info "Listen address: ${LISTEN_ADDR}:${LISTEN_PORT}"
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
        read -r _input </dev/tty || exit 1
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

    # Delegate service registration to the server binary. Capture its output
    # so we can suppress the QR-code reminder line (q.sh re-emits it under
    # "Getting started" in print_success with its own colorization).
    _svc_out="$(mktemp)"
    _svc_rc=0
    "$INSTALL_PATH" --install-service \
        --addr "${LISTEN_ADDR}:${LISTEN_PORT}" \
        --term "$TERM_ENV" \
        --lang "$LANG_ENV" > "$_svc_out" 2>&1 || _svc_rc=$?
    awk '/--qrcode/ { next } { print }' "$_svc_out"
    rm -f "$_svc_out"

    if [ "$_svc_rc" -eq 0 ]; then
        if wait_for_service_ready; then
            SERVICE_STARTED="yes"
        else
            SERVICE_STARTED="failed"
            SERVICE_FAILURE_REASON="startup"
            warn "Service was registered but did not become reachable at $(service_probe_url)"
            # Roll back the half-registered service so the user does not end
            # up with a stale service unit that will not start.
            "$INSTALL_PATH" --uninstall-service >/dev/null 2>&1 || true
            warn "Rolled back the failed service registration."
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
# Manual start command
# ============================================================

print_manual_start_command() {
    _addr="${LISTEN_ADDR}:${LISTEN_PORT}"
    printf '  QUICKTUI_TOKEN=%s ' "$(shell_quote "$TOKEN")"
    printf 'QUICKTUI_ADDR=%s ' "$(shell_quote "$_addr")"
    printf 'QUICKTUI_TERM=%s ' "$(shell_quote "$TERM_ENV")"
    printf 'QUICKTUI_LANG=%s ' "$(shell_quote "$LANG_ENV")"
    if [ -n "$TMUX_BIN_CONFIG" ]; then
        printf 'QUICKTUI_TMUX_BIN=%s ' "$(shell_quote "$TMUX_BIN_CONFIG")"
    fi
    printf '%s\n' "$(shell_quote "$INSTALL_PATH")"
}

# ============================================================
# Step 9: Print success message
# ============================================================

mask_token() {
    # Show only the last four characters so the token is not committed to
    # terminal scrollback verbatim. Users can read the full value from
    # $QUICKTUI_CONFIG_FILE (600 perms, owner-only).
    _t="$1"
    _len="${#_t}"
    if [ "$_len" -le 8 ]; then
        printf '%s\n' "$_t"
    else
        _last4="${_t#"${_t%????}"}"
        printf '••••%s (full value stored in %s)\n' "$_last4" "$QUICKTUI_CONFIG_FILE"
    fi
}

print_success() {
    _version="$("$INSTALL_PATH" --version 2>/dev/null || echo "")"

    if [ -n "$IS_UPGRADE" ]; then
        printf '\n%s✓ QuickTUI upgraded successfully!%s\n\n' "$C_GREEN" "$C_RESET"
    else
        printf '\n%s✓ QuickTUI installed successfully!%s\n\n' "$C_GREEN" "$C_RESET"
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
            printf '  Token:            %s' "$(mask_token "$TOKEN")"
            printf '  (Enter the token when prompted on first login)\n'
        fi
        printf "  %sTip:%s Run %s'quicktui-server --qrcode'%s to display the connection QR code for the iOS app.\n" \
            "$C_BOLD$C_GREEN" "$C_RESET" "$C_BOLD" "$C_RESET"
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
            printf '  Token: %s' "$(mask_token "$TOKEN")"
        fi
    else
        printf 'To start QuickTUI without a service, run:\n'
        print_manual_start_command
        printf '  Note: %s is only used by the background service.\n' "$QUICKTUI_CONFIG_FILE"
        printf '        Direct launches read CLI flags and environment variables.\n'
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
    printf '\n%sQuickTUI Uninstaller%s\n\n' "$C_BOLD" "$C_RESET"

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
        printf '\n%s✓ QuickTUI uninstalled successfully.%s\n\n' "$C_GREEN" "$C_RESET"
    fi
}

# ============================================================
# Environment preflight checks
# ============================================================

preflight_checks() {
    printf '\n  Environment checks:\n'
    _preflight_warnings=0

    if command -v locale > /dev/null 2>&1; then
        if locale_available "$LANG_ENV"; then
            info "Locale $LANG_ENV available"
        else
            warn "Locale \"$LANG_ENV\" is not available on this system, falling back to C.UTF-8."
            LANG_ENV="C.UTF-8"
        fi
    else
        printf '    - Locale check skipped (locale command not found)\n'
    fi

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

    _check_shell="${SHELL:-/bin/sh}"
    if [ -x "$_check_shell" ]; then
        info "Default shell $_check_shell OK"
    else
        warn "Default shell \"$_check_shell\" is not executable."
        printf '    Set the SHELL environment variable to a valid shell path, or install the missing shell.\n'
        _preflight_warnings=$((_preflight_warnings + 1))
    fi

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

    _tmux_check_bin="${TMUX_BIN_CONFIG:-tmux}"
    if command -v "$_tmux_check_bin" > /dev/null 2>&1 || [ -x "$_tmux_check_bin" ]; then
        _tmux_socket="quicktui-preflight-$$"
        _tmux_session="_qtui_preflight_$$"
        _tmux_stderr="$(TERM="$TERM_ENV" LANG="$LANG_ENV" LC_ALL="$LANG_ENV" \
            "$_tmux_check_bin" -L "$_tmux_socket" new-session -d -s "$_tmux_session" 2>&1)"
        _tmux_rc=$?
        "$_tmux_check_bin" -L "$_tmux_socket" kill-server > /dev/null 2>&1 || true
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

    if [ "$_preflight_warnings" -gt 0 ]; then
        printf '\n'
        warn "$_preflight_warnings issue(s) found. Some features may not work correctly."

        if [ -n "$CHECK_ONLY" ]; then
            return 1
        elif [ -z "$NON_INTERACTIVE" ] && ! confirm "Continue installation?" n; then
            exit 1
        fi
    fi
    printf '\n'
    return 0
}

# ============================================================
# Main
# ============================================================

main() {
    validate_cli_options
    validate_cli_terminal_overrides
    detect_existing_install
    if [ -n "$IS_UPGRADE" ]; then
        printf '\n%sQuickTUI Upgrader%s\n\n' "$C_BOLD" "$C_RESET"
    else
        printf '\n%sQuickTUI Installer%s\n\n' "$C_BOLD" "$C_RESET"
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
    preflight_checks || exit 1
else
    main
fi
