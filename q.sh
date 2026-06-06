#!/bin/sh
set -e
umask 077

# ============================================================
# QuickTUI Installer
# Usage: curl -fsSL https://quicktui.ai/q.sh | sh
# ============================================================

QUICKTUI_REPO="dualface/quicktui"
QUICKTUI_RELEASES_ENV_SET="${QUICKTUI_RELEASES+x}"
QUICKTUI_RELEASES_ENV_VALUE="${QUICKTUI_RELEASES:-}"
QUICKTUI_RELEASES_API_ENV_SET="${QUICKTUI_RELEASES_API+x}"
QUICKTUI_RELEASES_API_ENV_VALUE="${QUICKTUI_RELEASES_API:-}"
QUICKTUI_GITHUB_BASE_ENV_SET="${QUICKTUI_GITHUB_BASE+x}"
QUICKTUI_GITHUB_BASE_ENV_VALUE="${QUICKTUI_GITHUB_BASE:-}"
TMUX_BUILDS_RELEASES_ENV_SET="${TMUX_BUILDS_RELEASES+x}"
TMUX_BUILDS_RELEASES_ENV_VALUE="${TMUX_BUILDS_RELEASES:-}"
QUICKTUI_RELEASES="https://github.com/${QUICKTUI_REPO}/releases/latest/download"
QUICKTUI_RELEASES_API="https://api.github.com/repos/${QUICKTUI_REPO}/releases?per_page=100"
QUICKTUI_GITHUB_BASE="https://github.com/${QUICKTUI_REPO}"
TMUX_BUILDS_RELEASES="https://github.com/tmux/tmux-builds/releases/download/v"
[ -n "$QUICKTUI_RELEASES_ENV_SET" ] && QUICKTUI_RELEASES="$QUICKTUI_RELEASES_ENV_VALUE"
[ -n "$QUICKTUI_RELEASES_API_ENV_SET" ] && QUICKTUI_RELEASES_API="$QUICKTUI_RELEASES_API_ENV_VALUE"
[ -n "$QUICKTUI_GITHUB_BASE_ENV_SET" ] && QUICKTUI_GITHUB_BASE="$QUICKTUI_GITHUB_BASE_ENV_VALUE"
[ -n "$TMUX_BUILDS_RELEASES_ENV_SET" ] && TMUX_BUILDS_RELEASES="$TMUX_BUILDS_RELEASES_ENV_VALUE"
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
PREVIEW_RELEASE=""
OPT_SERVER_RELEASE=""
REQUIRE_SERVER2=""
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
EXISTING_VERSION=""
EXISTING_CHANNEL=""

_BG_PID=""
_STTY_SAVED=""
_SVC_OUT=""
# install_binary transaction state. Cleanup uses these to roll back a
# partial binary swap when the script dies from a signal (HUP / INT /
# TERM / QUIT) between the backup `mv` and the final success. Without
# this rollback, an SSH disconnect mid-install would leave the user
# with no binary at all and a stopped service.
_INSTALL_TX_ACTIVE=""
_INSTALL_TX_PATH=""
_INSTALL_TX_STAGED=""
_INSTALL_TX_BACKUP=""
_CONFIG_TMP=""
cleanup() {
    if [ -n "$_STTY_SAVED" ] && command -v stty > /dev/null 2>&1; then
        stty "$_STTY_SAVED" </dev/tty 2>/dev/null || true
        _STTY_SAVED=""
    fi
    [ -n "$_BG_PID" ] && kill "$_BG_PID" 2>/dev/null || true
    [ -n "$DOWNLOAD_TMPDIR" ] && rm -rf "$DOWNLOAD_TMPDIR" || true
    [ -n "$_SVC_OUT" ] && rm -f "$_SVC_OUT" || true
    [ -n "$_CONFIG_TMP" ] && rm -f "$_CONFIG_TMP" || true
    if [ -n "$_INSTALL_TX_ACTIVE" ]; then
        # Best-effort rollback. Errors from supervisor restart are
        # surfaced to stderr but not propagated — we are already in
        # an exit handler.
        [ -n "$_INSTALL_TX_PATH" ] && rm -f "$_INSTALL_TX_PATH" 2>/dev/null
        [ -n "$_INSTALL_TX_STAGED" ] && rm -f "$_INSTALL_TX_STAGED" 2>/dev/null
        if [ -n "$_INSTALL_TX_BACKUP" ] && [ -f "$_INSTALL_TX_BACKUP" ]; then
            mv "$_INSTALL_TX_BACKUP" "$_INSTALL_TX_PATH" 2>/dev/null || true
            if [ -n "$IS_UPGRADE" ] && [ -n "$EXISTING_SERVICE" ]; then
                restart_existing_service 2>/dev/null \
                    || printf 'Warning: original service did not restart on rollback; run `%s --install-service` manually.\n' "$_INSTALL_TX_PATH" >&2
            fi
        fi
        _INSTALL_TX_ACTIVE=""
        _INSTALL_TX_PATH=""
        _INSTALL_TX_STAGED=""
        _INSTALL_TX_BACKUP=""
    fi
}
# Signal traps clear the EXIT trap first so cleanup runs exactly once.
# HUP/QUIT are trapped alongside INT/TERM so tmpdirs do not leak when an
# ssh session disconnects or the user sends SIGQUIT mid-install.
trap 'trap - EXIT; cleanup; exit 130' INT TERM HUP QUIT
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

# Dies unless the given value looks like a bare 64-char lowercase hex
# digest. Use after fetching `.sha256` artifacts from the network so an
# HTML 404 body ("<!doctype html...") surfaces a clear "checksum file is
# not a digest" error instead of an opaque "checksum mismatch".
assert_valid_sha256() {
    _value="$1"
    _context="$2"
    case "$_value" in
        *[!0-9a-f]*|'')
            die "${_context} does not look like a SHA-256 digest (got: '$_value')."
            ;;
    esac
    [ "${#_value}" -eq 64 ] || \
        die "${_context} has wrong length (expected 64 hex chars, got ${#_value})."
}

# Dies with a clear explanation after a failed `read ... </dev/tty`.
# Tries to distinguish the no-tty case (container without /dev/tty) from
# a plain EOF (user hit Ctrl-D to cancel) so the error message matches
# what the user actually did.
die_no_tty() {
    if [ -c /dev/tty ] && ( : </dev/tty ) 2>/dev/null; then
        die "Input cancelled."
    else
        die "Cannot read from /dev/tty (no controlling terminal). Re-run with -y plus CLI options (--token / --addr / --port) to avoid prompts."
    fi
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
        --token=*)
            OPT_TOKEN="${1#--token=}"
            shift
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
        --term=*)
            OPT_TERM="${1#--term=}"
            shift
            ;;
        --lang)
            [ $# -ge 2 ] || die "Missing value for $1"
            OPT_LANG="$2"
            shift 2
            ;;
        --lang=*)
            OPT_LANG="${1#--lang=}"
            shift
            ;;
        --check)
            CHECK_ONLY="1"
            shift
            ;;
        --preview)
            PREVIEW_RELEASE="1"
            shift
            ;;
        --required-version-2)
            # Opt in to the server2 channel. Without this flag, q.sh
            # refuses to install any binary whose --version output
            # contains "server2" (preview or release). The check is
            # post-install with rollback so the previous binary is
            # restored if a misaligned tag slips through.
            REQUIRE_SERVER2="1"
            shift
            ;;
        --server-release)
            [ $# -ge 2 ] || die "Missing value for $1"
            OPT_SERVER_RELEASE="$2"
            shift 2
            ;;
        --server-release=*)
            OPT_SERVER_RELEASE="${1#--server-release=}"
            shift
            ;;
        --addr)
            [ $# -ge 2 ] || die "Missing value for $1"
            OPT_ADDR="$2"
            shift 2
            ;;
        --addr=*)
            OPT_ADDR="${1#--addr=}"
            shift
            ;;
        --port)
            [ $# -ge 2 ] || die "Missing value for $1"
            OPT_PORT="$2"
            shift 2
            ;;
        --port=*)
            OPT_PORT="${1#--port=}"
            shift
            ;;
        --uninstall)
            UNINSTALL="1"
            shift
            ;;
        -h|--help)
            printf 'Usage: q.sh [OPTIONS]\n\n'
            printf 'Options:\n'
            printf '  -y, --yes          Skip prompts; use defaults and auto-accept confirmations\n'
            printf '  --token <string>   Set access token (skip prompt)\n'
            printf '  --rotate-token     Generate a fresh random token (overrides saved token)\n'
            printf '  --no-service       Skip background service registration\n'
            printf '  --addr <address>   Listen address (default: 0.0.0.0)\n'
            printf '  --port <port>      Listen port (default: 8022)\n'
            printf '  --term <value>     TERM for tmux (default xterm-256color)\n'
            printf '  --lang <value>     LANG for tmux (default: en_US.UTF-8)\n'
            printf '  --preview          Install the latest preview release (requires --required-version-2 while the server channel has no preview line)\n'
            printf '  --server-release <tag>  Install a specific server release tag (e.g. 20260518-01 for stable, or server2-preview-... with --required-version-2)\n'
            printf '  --required-version-2  Opt in to the server2 channel (asserts the installed binary --version contains a tag of the form server2-*)\n'
            printf '  --check            Run environment checks without installing\n'
            printf '  --uninstall        Remove QuickTUI and all related files\n'
            printf '  -h, --help         Show this help\n'
            printf '\n'
            printf 'Environment:\n'
            printf '  NO_COLOR                      Disable ANSI color when set\n'
            printf '  QUICKTUI_RELEASES             Base URL for server binary/assets (default: %s)\n' "$QUICKTUI_RELEASES"
            printf '  QUICKTUI_RELEASES_API         GitHub releases API URL for --preview (default: %s)\n' "$QUICKTUI_RELEASES_API"
            printf '  QUICKTUI_GITHUB_BASE          Base URL for --server-release tag downloads (default: %s)\n' "$QUICKTUI_GITHUB_BASE"
            printf '  TMUX_BUILDS_VERSION           Override pinned tmux-builds version\n'
            printf '  TMUX_BUILDS_SHA256            Expected SHA-256 for the tmux tarball\n'
            printf '  TMUX_BUILDS_RELEASES          Base URL for tmux tarball (default: %s)\n' "$TMUX_BUILDS_RELEASES"
            printf '  TMUX_BUILDS_ALLOW_UNVERIFIED  Set to 1 to skip tmux checksum (unsafe)\n'
            printf '\n'
            printf 'Example (override tmux via a piped install):\n'
            printf '  curl -fsSL https://quicktui.ai/q.sh \\\n'
            printf '    | TMUX_BUILDS_VERSION=3.7 TMUX_BUILDS_SHA256=<hex> sh\n'
            exit 0
            ;;
        *)
            die "Unknown option: $1 (use --help for usage)"
            ;;
    esac
done

# Mutually exclusive dispatch flags — checked here instead of in
# validate_cli_options so the UNINSTALL path (which does not call
# validate_cli_options) also rejects the combination.
if [ -n "$UNINSTALL" ] && [ -n "$CHECK_ONLY" ]; then
    die "--uninstall and --check are mutually exclusive."
fi
if [ -n "$UNINSTALL" ] && [ -n "$PREVIEW_RELEASE" ]; then
    die "--uninstall and --preview are mutually exclusive."
fi
if [ -n "$UNINSTALL" ] && [ -n "$OPT_SERVER_RELEASE" ]; then
    die "--uninstall and --server-release are mutually exclusive."
fi
if [ -n "$PREVIEW_RELEASE" ] && [ -n "$OPT_SERVER_RELEASE" ]; then
    die "--preview and --server-release are mutually exclusive."
fi
if [ -n "$OPT_SERVER_RELEASE" ]; then
    case "$OPT_SERVER_RELEASE" in
        server-*)
            # Monorepo git tag is `server-YYYYMMDD-NN`, but the GitHub
            # release tag on dualface/quicktui drops the `server-` prefix.
            # Reject the prefixed form so users do not 404 on copy-paste.
            die "Invalid --server-release tag: '$OPT_SERVER_RELEASE'. Drop the 'server-' prefix (pass 'YYYYMMDD-NN' from the GitHub release, not the monorepo git tag)."
            ;;
        '' | *[!A-Za-z0-9._-]*)
            die "Invalid --server-release tag: '$OPT_SERVER_RELEASE'. Only letters, digits, dot, underscore, and dash are allowed."
            ;;
    esac
    QUICKTUI_RELEASES="${QUICKTUI_GITHUB_BASE}/releases/download/${OPT_SERVER_RELEASE}"
fi

# `--preview` today only resolves the server2 preview channel because
# publish.sh emits no `server-preview-*` tags. Make the user opt in
# explicitly via `--required-version-2` so a server preview line can
# be added later without quietly changing the meaning of `--preview`.
# Skip the gate for `--check` because that path runs environment
# probes without downloading or installing anything; the channel flag
# combinations have no effect there.
if [ -n "$PREVIEW_RELEASE" ] && [ -z "$REQUIRE_SERVER2" ] && [ -z "$CHECK_ONLY" ]; then
    die "--preview currently resolves only the server2 preview channel; re-run with --required-version-2 to confirm, or drop --preview to install the stable release."
fi

confirm() {
    _prompt="$1"
    _default="${2:-n}"
    if [ -n "$NON_INTERACTIVE" ]; then
        return 0
    fi
    if [ "$_default" = "y" ]; then
        _hint="[Y/n]"
    else
        _hint="[y/N]"
    fi
    printf '%s %s ' "$_prompt" "$_hint"
    read -r _answer </dev/tty || die_no_tty
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
        *[!A-Za-z0-9.\-]*)
            return 1
            ;;
        *:*)
            return 1
            ;;
    esac
    # Numeric dotted-quad candidate: require exactly four octets 0-255.
    # Hostnames may also contain three or more dots, so only enter this
    # branch when the value is made solely of digits and dots.
    case "$_addr" in
        *[!0-9.]*)
            ;;
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

terminfo_available() {
    command -v infocmp > /dev/null 2>&1 && infocmp "$1" > /dev/null 2>&1
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
    terminfo_available "$_value" || die "Invalid ${_label}: '$_value'. Terminfo entry not found on this system."
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
            return 1
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

    # For TERM/LANG, reject structurally malformed values but treat a
    # "valid syntax, not installed on this host" situation as a soft miss:
    # clear the existing value so collect_terminal_env falls back to the
    # default, mirroring the fresh-install path (preflight_checks also
    # downgrades when the primary entry is absent).
    if [ -n "$EXISTING_TERM" ]; then
        validate_terminal_value "$EXISTING_TERM" || die "Invalid QUICKTUI_TERM in existing config: '$EXISTING_TERM'"
        if ! terminfo_available "$EXISTING_TERM"; then
            warn "Saved QUICKTUI_TERM='$EXISTING_TERM' is not installed on this host; falling back to default."
            EXISTING_TERM=""
        fi
    fi

    if [ -n "$EXISTING_LANG" ]; then
        validate_terminal_value "$EXISTING_LANG" || die "Invalid QUICKTUI_LANG in existing config: '$EXISTING_LANG'"
        if command -v locale > /dev/null 2>&1 && ! locale_available "$EXISTING_LANG"; then
            warn "Saved QUICKTUI_LANG='$EXISTING_LANG' is not available on this host; falling back to default."
            EXISTING_LANG=""
        fi
    fi
}

validate_port() {
    _port="$1"
    case "$_port" in
        ''|*[!0-9]*)
            return 1
            ;;
        # Reject leading zeros so dash/busybox don't reinterpret "010" as
        # octal 8 in the numeric comparison below.
        0[0-9]*)
            return 1
            ;;
    esac

    [ "$_port" -ge 1 ] && [ "$_port" -le 65535 ]
}

download() {
    _url="$1"
    _dest="$2"
    _msg="${3:-Downloading}"
    # Refuse anything that is not an https:// or http:// URL. Without
    # the scheme guard, a malicious or misconfigured env var (e.g.
    # QUICKTUI_RELEASES="--config /etc/passwd ...") could be picked up
    # by curl/wget as a flag string. Pairing the guard with `--` makes
    # leading dashes impossible to abuse even if the scheme check is
    # bypassed by future refactors.
    case "$_url" in
        # https / http for production. file:// is allowed because
        # tests use local fixtures and a tampered env var can at worst
        # copy local content into the download tmpdir, where the
        # subsequent sha256 check rejects it.
        https://*|http://*|file://*) ;;
        '')
            die "Download URL is empty."
            ;;
        *)
            die "Refusing to download from non-http(s)/file URL: '$_url'"
            ;;
    esac
    printf '  URL: %s\n' "$_url"
    # Start silent download in background
    if command -v curl > /dev/null 2>&1; then
        curl -fsSL -o "$_dest" -- "$_url" &
    elif command -v wget > /dev/null 2>&1; then
        wget -q -O "$_dest" -- "$_url" &
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

parse_preview_asset_urls() {
    _json_file="$1"
    _binary_name="$2"
    awk -v bin="$_binary_name" '
        BEGIN {
            depth = 0
            in_release = 0
            in_assets = 0
            is_preview = 0
            is_draft = 0
            release_tag = ""
            current_name = ""
            binary_url = ""
            sha_url = ""
            gzip_url = ""
            gzip_sha_url = ""
        }

        function json_string_value(line,    value) {
            value = line
            sub(/^[^:]*:[[:space:]]*"/, "", value)
            sub(/",?[[:space:]]*$/, "", value)
            gsub(/\\"/, "\"", value)
            gsub(/\\\\/, "\\", value)
            return value
        }

        function reset_release() {
            in_release = 1
            in_assets = 0
            is_preview = 0
            is_draft = 0
            release_tag = ""
            current_name = ""
            binary_url = ""
            sha_url = ""
            gzip_url = ""
            gzip_sha_url = ""
        }

        function is_preview_tag(value) {
            # Only the server2 channel currently publishes prereleases.
            # The --preview path is gated on --required-version-2 in
            # the shell layer above, so by the time the awk filter
            # runs the caller has already opted in. Keep the regex
            # strict so a stray prerelease (e.g. a one-off draft) is
            # not silently treated as a server2 build.
            return value ~ /^server2-preview-/
        }

        {
            copy = $0
            opens = gsub(/\{/, "", copy)
            copy = $0
            closes = gsub(/\}/, "", copy)
            if (!in_release && depth == 0 && $0 ~ /^[[:space:]]*\{[[:space:]]*$/) {
                reset_release()
            }
        }

        in_release && /"draft"[[:space:]]*:[[:space:]]*true/ {
            is_draft = 1
        }

        in_release && /"prerelease"[[:space:]]*:[[:space:]]*true/ {
            is_preview = 1
        }

        in_release && /"tag_name"[[:space:]]*:/ {
            release_tag = json_string_value($0)
        }

        in_release && /"assets"[[:space:]]*:/ {
            in_assets = 1
        }

        in_release && in_assets && /"name"[[:space:]]*:/ {
            current_name = json_string_value($0)
        }

        in_release && in_assets && /"browser_download_url"[[:space:]]*:/ {
            if (!is_draft && is_preview && is_preview_tag(release_tag)) {
                url = json_string_value($0)
                if (current_name == bin) binary_url = url
                if (current_name == bin ".sha256") sha_url = url
                if (current_name == bin ".gz") gzip_url = url
                if (current_name == bin ".gz.sha256") gzip_sha_url = url
            }
            current_name = ""
        }

        {
            depth += opens - closes
            if (in_release && in_assets && depth == 1 && $0 ~ /^[[:space:]]*\],?[[:space:]]*$/) {
                in_assets = 0
            }
            if (in_release && depth <= 0) {
                if (!is_draft && is_preview && is_preview_tag(release_tag) && binary_url != "" && sha_url != "") {
                    print binary_url
                    print sha_url
                    print gzip_url
                    print gzip_sha_url
                    exit 0
                }
                in_release = 0
                in_assets = 0
                depth = 0
            }
        }
    ' "$_json_file"
}

resolve_preview_asset_urls() {
    _json_path="${DOWNLOAD_TMPDIR}/releases.json"
    download "$QUICKTUI_RELEASES_API" "$_json_path" "Finding latest preview release..." || \
        die "Failed to query preview releases from ${QUICKTUI_RELEASES_API}."

    _asset_urls="$(parse_preview_asset_urls "$_json_path" "$BINARY_NAME")"
    PREVIEW_BINARY_URL="$(printf '%s\n' "$_asset_urls" | sed -n '1p')"
    PREVIEW_SHA256_URL="$(printf '%s\n' "$_asset_urls" | sed -n '2p')"
    PREVIEW_GZIP_URL="$(printf '%s\n' "$_asset_urls" | sed -n '3p')"
    PREVIEW_GZIP_SHA256_URL="$(printf '%s\n' "$_asset_urls" | sed -n '4p')"
    [ -n "$PREVIEW_BINARY_URL" ] && [ -n "$PREVIEW_SHA256_URL" ] || \
        die "No preview release asset found for ${BINARY_NAME} and ${BINARY_NAME}.sha256."
}

download_verified_file() {
    _download_url="$1"
    _download_sha256_url="$2"
    _download_dest="$3"
    _download_sha_dest="$4"
    _download_label="$5"

    download "$_download_url" "$_download_dest" "Downloading QuickTUI (${_download_label})..." || return 1

    _file_size="$(du -sh "$_download_dest" 2>/dev/null | cut -f1)"
    printf '  File size: %s\n' "${_file_size:-unknown}"

    download "$_download_sha256_url" "$_download_sha_dest" "Downloading checksum..." || return 1

    printf '  Verifying checksum...\n'
    _expected_hash="$(normalize_sha256 "$(awk '{print $1}' "${_download_sha_dest}")")"
    assert_valid_sha256 "$_expected_hash" "Checksum file at ${_download_sha256_url}"
    _actual_hash="$(normalize_sha256 "$(sha256_file "$_download_dest")")"
    [ "$_actual_hash" = "$_expected_hash" ] || {
        rm -rf "$DOWNLOAD_TMPDIR"
        die "Checksum verification failed. The downloaded file may be corrupted."
    }
    return 0
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
        EXISTING_VERSION="$("$_existing_binary" --version 2>/dev/null || echo "unknown")"
        # Channel of the installed binary, used by main() to gate the
        # cross-channel upgrade confirm. Match `server2-` (same shape
        # as check_binary_channel) so a future `server2-YYYYMMDD-NN`
        # stable tag is still classified as the server2 channel.
        case "$EXISTING_VERSION" in
            *server2-*) EXISTING_CHANNEL="server2" ;;
            *) EXISTING_CHANNEL="stable" ;;
        esac
        info "Existing installation detected ($EXISTING_VERSION)"
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
        assert_valid_sha256 "$_expected_sha" "TMUX_BUILDS_SHA256"
    elif [ "$_tmux_ver" = "$TMUX_BUILDS_DEFAULT_VERSION" ]; then
        _expected_sha="$(tmux_builds_pinned_sha256 "$_tmux_os" "$_tmux_arch" || true)"
        [ -n "$_expected_sha" ] || die "No pinned tmux checksum for ${_tmux_os}-${_tmux_arch}. Set TMUX_BUILDS_VERSION and TMUX_BUILDS_SHA256 explicitly, or TMUX_BUILDS_ALLOW_UNVERIFIED=1 to bypass at your own risk."
    else
        if [ "${TMUX_BUILDS_ALLOW_UNVERIFIED:-}" != "1" ]; then
            die "TMUX_BUILDS_VERSION=$_tmux_ver overrides the pinned default ($TMUX_BUILDS_DEFAULT_VERSION). Set TMUX_BUILDS_SHA256=<hex> to verify it, or TMUX_BUILDS_ALLOW_UNVERIFIED=1 to bypass verification at your own risk."
        fi
        warn "Downloading unpinned tmux $_tmux_ver without checksum verification (TMUX_BUILDS_ALLOW_UNVERIFIED=1)."
    fi

    if [ -n "$TMUX_BUILDS_RELEASES_ENV_SET" ]; then
        _tmux_base_url="$TMUX_BUILDS_RELEASES"
    else
        _tmux_base_url="${TMUX_BUILDS_RELEASES}${_tmux_ver}"
    fi
    _tmux_filename="tmux-${_tmux_ver}-${_tmux_os}-${_tmux_arch}.tar.gz"
    _tmux_tmpdir="$(mktemp -d)"
    _tmux_tarball="${_tmux_tmpdir}/tmux.tar.gz"

    download "${_tmux_base_url}/${_tmux_filename}" "$_tmux_tarball" "Downloading tmux ${_tmux_ver}..." || \
        { rm -rf "$_tmux_tmpdir"; die "Failed to download tmux binary from ${_tmux_base_url}/${_tmux_filename}."; }

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

# Parse `tmux -V` output into two numeric tokens on stdout ("major minor").
# Returns non-zero on unparseable input. Callers capture via command
# substitution so there are no shared globals to clobber across calls.
_parse_tmux_major_minor() {
    _bin="$1"
    [ -x "$_bin" ] || return 1
    _ver="$("$_bin" -V 2>/dev/null | sed 's/^tmux //')"
    _p_maj="$(printf '%s\n' "$_ver" | cut -d. -f1)"
    _p_min="$(printf '%s\n' "$_ver" | cut -d. -f2 | cut -d- -f1 | sed 's/[^0-9].*//')"
    case "$_p_maj" in ''|*[!0-9]*) return 1 ;; esac
    case "$_p_min" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s %s\n' "$_p_maj" "$_p_min"
}

_tmux_at_least_3_2() {
    _parsed="$(_parse_tmux_major_minor "$1")" || return 1
    _maj="${_parsed%% *}"
    _min="${_parsed##* }"
    [ "$_maj" -gt 3 ] && return 0
    [ "$_maj" -eq 3 ] && [ "$_min" -ge 2 ] && return 0
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
    _parse_tmux_major_minor "$_tmux_bin" > /dev/null || die "Could not parse tmux version from '$_tmux_bin -V'."
    # Preserve the full version string including any patch letter.
    _tmux_version="$("$_tmux_bin" -V 2>/dev/null | sed 's/^tmux //')"

    if [ -n "$EXISTING_TMUX_BIN" ] && ! safe_existing_tmux_bin "$EXISTING_TMUX_BIN"; then
        warn "Ignoring untrusted QUICKTUI_TMUX_BIN from existing config."
        EXISTING_TMUX_BIN=""
    fi

    if ! _tmux_at_least_3_2 "$_tmux_bin"; then
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
    elif [ -n "$EXISTING_TMUX_BIN" ] && _tmux_at_least_3_2 "$EXISTING_TMUX_BIN"; then
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
    _gzip_path="${DOWNLOAD_TMPDIR}/${BINARY_NAME}.gz"
    _gzip_sha256_path="${DOWNLOAD_TMPDIR}/${BINARY_NAME}.gz.sha256"

    printf '  Temp dir:  %s\n' "$DOWNLOAD_TMPDIR"
    if [ -n "$PREVIEW_RELEASE" ]; then
        resolve_preview_asset_urls
        _binary_url="$PREVIEW_BINARY_URL"
        _sha256_url="$PREVIEW_SHA256_URL"
        _gzip_url="$PREVIEW_GZIP_URL"
        _gzip_sha256_url="$PREVIEW_GZIP_SHA256_URL"
    else
        _binary_url="${QUICKTUI_RELEASES}/${BINARY_NAME}"
        _sha256_url="${QUICKTUI_RELEASES}/${BINARY_NAME}.sha256"
        _gzip_url="${QUICKTUI_RELEASES}/${BINARY_NAME}.gz"
        _gzip_sha256_url="${QUICKTUI_RELEASES}/${BINARY_NAME}.gz.sha256"
    fi

    _downloaded_gzip=""
    if command -v gzip > /dev/null 2>&1 && [ -n "$_gzip_url" ] && [ -n "$_gzip_sha256_url" ]; then
        if download_verified_file "$_gzip_url" "$_gzip_sha256_url" "$_gzip_path" "$_gzip_sha256_path" "${BINARY_NAME}.gz"; then
            printf '  Decompressing QuickTUI...\n'
            gzip -dc "$_gzip_path" > "$_binary_path" || {
                rm -rf "$DOWNLOAD_TMPDIR"
                die "Failed to decompress ${_gzip_url}."
            }
            # Cross-check the decompressed payload against the raw
            # `.sha256` artifact (M1). Without this step, the gzip path
            # only proves that the .gz file matches its own digest —
            # if `quicktui-server` and `quicktui-server.gz` were ever
            # built or signed from different sources, the swap would
            # be undetectable. Fall back gracefully when the raw
            # `.sha256` is not published.
            if [ -n "$_sha256_url" ]; then
                if download "$_sha256_url" "$_sha256_path" "Downloading raw checksum..."; then
                    _expected_raw="$(normalize_sha256 "$(awk '{print $1}' "$_sha256_path")")"
                    assert_valid_sha256 "$_expected_raw" "Checksum file at ${_sha256_url}"
                    _actual_raw="$(normalize_sha256 "$(sha256_file "$_binary_path")")"
                    if [ "$_actual_raw" != "$_expected_raw" ]; then
                        rm -rf "$DOWNLOAD_TMPDIR"
                        die "Decompressed binary digest does not match ${_sha256_url}. Compressed and raw artifacts disagree."
                    fi
                else
                    warn "Could not fetch raw checksum from ${_sha256_url}; trusting .gz digest only."
                fi
            fi
            _downloaded_gzip="1"
        else
            warn "Compressed binary unavailable; falling back to uncompressed download."
        fi
    fi

    if [ -z "$_downloaded_gzip" ]; then
        download_verified_file "$_binary_url" "$_sha256_url" "$_binary_path" "$_sha256_path" "$BINARY_NAME" || \
            die "Failed to download binary from ${_binary_url}. Check your internet connection and try again."
    fi

    chmod +x "$_binary_path"
    DOWNLOADED_BINARY="$_binary_path"
    info "Download verified"
}

# ============================================================
# Step 3.5: Stop existing service before replacing binary
# ============================================================

# Stop the currently running service but keep the registration files
# (launchd plist / systemd unit) intact so that install_binary's rollback
# path can use restart_existing_service to bring the old service back.
# Used by install_binary during upgrade.
# Treats "service was not loaded" or "no supervisor available" as
# success — the goal is "service is not running afterwards", so a
# pre-existing not-loaded state, or an environment where the supervisor
# itself cannot be reached (CI containers without systemd-user / a
# real launchd domain), already satisfies that. Any other failure
# aborts: leaving an old supervisor alive while replacing the binary
# risks the OS restarting the stopped process mid-swap.
_supervisor_stop_err_is_benign() {
    case "$1" in
        *"No such process"*|\
        *"could not find"*|\
        *"Could not find"*|\
        *"not loaded"*|\
        *"could not be found"*|\
        *"not be found"*|\
        *"not currently loaded"*|\
        *"Failed to connect to bus"*|\
        *"Failed to connect to system bus"*|\
        *"Failed to connect to user bus"*|\
        *"Failed to get D-Bus connection"*|\
        *"No medium found"*|\
        *"Could not connect to bootstrap server"*|\
        *"Bootstrap not available"*)
            return 0
            ;;
    esac
    return 1
}

stop_service_keep_registration() {
    _os="$(uname -s)"
    _launchd_plist="${HOME}/Library/LaunchAgents/ai.quicktui.plist"
    _systemd_service="${HOME}/.config/systemd/user/quicktui.service"
    _stopped=""

    if [ "$_os" = "Darwin" ]; then
        if [ -f "$_launchd_plist" ]; then
            _err="$(launchctl bootout "gui/$(id -u)" "$_launchd_plist" 2>&1)"
            _rc=$?
            if [ "$_rc" -ne 0 ] && ! _supervisor_stop_err_is_benign "$_err"; then
                _err2="$(launchctl unload "$_launchd_plist" 2>&1)"
                _rc2=$?
                if [ "$_rc2" -ne 0 ] && ! _supervisor_stop_err_is_benign "$_err2"; then
                    die "Failed to stop launchd service before binary replacement: $_err2"
                fi
            fi
            _stopped=1
        fi
    else
        if [ -f "$_systemd_service" ] && command -v systemctl > /dev/null 2>&1; then
            _err="$(systemctl --user stop quicktui 2>&1)"
            _rc=$?
            if [ "$_rc" -ne 0 ] && ! _supervisor_stop_err_is_benign "$_err"; then
                die "Failed to stop systemd service before binary replacement: $_err"
            fi
            _stopped=1
        fi
    fi
    if [ -n "$_stopped" ]; then
        info "Stopped existing service"
    fi
    # Explicit success: the `[ -n "$_stopped" ] && info ...` idiom
    # exits with status 1 when `_stopped` is empty, which `set -e`
    # propagates and kills the installer mid-flight when stopping
    # was not needed (e.g. the previous install was --no-service).
    return 0
}

# Restart a service unit that was previously registered (used during
# install rollback so the user is not left with a stopped service).
# Returns 0 if restart succeeded (or no registration file existed),
# 1 if a registration file existed but the supervisor refused. The
# caller turns a failure into a hard error so the user is not silently
# left with a stopped service after a binary rollback.
restart_existing_service() {
    _os="$(uname -s)"
    _launchd_plist="${HOME}/Library/LaunchAgents/ai.quicktui.plist"
    _systemd_service="${HOME}/.config/systemd/user/quicktui.service"
    if [ "$_os" = "Darwin" ]; then
        if [ -f "$_launchd_plist" ]; then
            launchctl bootstrap "gui/$(id -u)" "$_launchd_plist" >/dev/null 2>&1 && return 0
            launchctl load "$_launchd_plist" >/dev/null 2>&1 && return 0
            return 1
        fi
    else
        if [ -f "$_systemd_service" ] && command -v systemctl > /dev/null 2>&1; then
            systemctl --user start quicktui >/dev/null 2>&1 || return 1
        fi
    fi
    return 0
}

# Print one pid per line for every running process whose executable is
# our installed quicktui-server (M4 + L1). The old implementation parsed
# `ps` argv0 by whitespace and accepted a basename match, which:
#   1. Could not handle install paths containing spaces (argv0 string
#      split by `ps` field delimiter), and
#   2. Killed unrelated `quicktui-server` builds in other directories
#      owned by the same user (CI matrix, developer worktrees).
# Linux exposes the kernel-resolved exe path via `/proc/<pid>/exe`,
# which is immune to argv tampering. macOS has no /proc, so we use
# `lsof -p <pid>` to read the `txt` (text-segment / executable) entry.
list_processes_for_binary() {
    _binary="$1"
    _self_uid="$(id -u)"
    _self_user="$(id -un 2>/dev/null || printf '%s\n' "$_self_uid")"
    _os="$(uname -s)"

    if [ "$_os" = "Linux" ] && [ -d /proc ]; then
        # /proc/<pid>/exe symlink points at the kernel-known executable
        # path. Filter by uid first to avoid permission errors when
        # readlink'ing other users' /proc entries (those return EACCES
        # silently under `2>/dev/null`).
        for _pid_dir in /proc/[0-9]*; do
            [ -d "$_pid_dir" ] || continue
            _pid="${_pid_dir##*/}"
            [ "$_pid" = "$$" ] && continue
            _uid_line="$(grep '^Uid:' "$_pid_dir/status" 2>/dev/null || true)"
            [ -n "$_uid_line" ] || continue
            _pid_uid="$(printf '%s\n' "$_uid_line" | awk '{print $2}')"
            [ "$_pid_uid" = "$_self_uid" ] || continue
            _exe="$(readlink "$_pid_dir/exe" 2>/dev/null || true)"
            if [ "$_exe" = "$_binary" ]; then
                printf '%s\n' "$_pid"
                continue
            fi
            # Shell-launched scripts: /proc/<pid>/exe symlinks to the
            # interpreter (e.g. /bin/sh), not the script path. Check
            # /proc/<pid>/cmdline (NUL-separated argv) and match when
            # argv[0] is a known shell and argv[1] equals the install
            # path. tr converts NUL to newline so awk can split.
            case "$_exe" in
                */sh|*/bash|*/dash|*/zsh|*/ksh)
                    _argv1="$(tr '\0' '\n' < "$_pid_dir/cmdline" 2>/dev/null \
                        | sed -n '2p')"
                    [ "$_argv1" = "$_binary" ] && printf '%s\n' "$_pid"
                    ;;
            esac
        done
        return 0
    fi

    # macOS / other Unix without /proc. Prefer ps' executable path
    # (`comm`) over per-pid `lsof -p`: scanning every process can hang
    # behind a slow or wedged unrelated process and stall upgrades right
    # after "Download verified".
    if ps -axww -o pid= -o uid= -o comm= > /dev/null 2>&1; then
        ps -axww -o pid= -o uid= -o comm= | awk \
            -v self="$$" \
            -v uid="$_self_uid" \
            -v uname="$_self_user" \
            -v target_abs="$_binary" '
            {
                line=$0
                sub(/^[[:space:]]*/, "", line)
                pid=line
                sub(/[[:space:]].*$/, "", pid)
                sub(/^[^[:space:]]+[[:space:]]+/, "", line)
                usr=line
                sub(/[[:space:]].*$/, "", usr)
                sub(/^[^[:space:]]+[[:space:]]*/, "", line)
                exe=line
                if (pid == self) next
                if (usr != uid && usr != uname) next
                if (exe == target_abs) print pid
            }
        '
    elif command -v lsof > /dev/null 2>&1; then
        # File-targeted lsof is a bounded fallback; do not iterate
        # lsof over every process.
        lsof -t -d txt -- "$_binary" 2>/dev/null | while IFS= read -r _pid; do
            [ -n "$_pid" ] || continue
            [ "$_pid" = "$$" ] && continue
            _pid_uid="$(ps -o uid= -p "$_pid" 2>/dev/null | awk '{print $1}')"
            if [ "$_pid_uid" = "$_self_uid" ] || [ "$_pid_uid" = "$_self_user" ]; then
                printf '%s\n' "$_pid"
            fi
        done
    fi

    # Last-resort: ps argv0 full-path match for shell-launched scripts.
    # Basename fallback removed so unrelated `quicktui-server` builds
    # elsewhere on the same account survive. Paths containing whitespace
    # will not match here, which is intentional: better to miss than to
    # mis-kill.
    {
        if ps -axww -o pid= -o uid= -o command= > /dev/null 2>&1; then
            ps -axww -o pid= -o uid= -o command=
        else
            ps -eww -o pid= -o uid= -o args=
        fi
    } | awk \
        -v self="$$" \
        -v uid="$_self_uid" \
        -v uname="$_self_user" \
        -v target_abs="$_binary" '
        {
            pid=$1; usr=$2
            if (pid == self) next
            if (usr != uid && usr != uname) next
            argv0=$3
            if (argv0 == target_abs) { print pid; next }
            n=split(argv0, parts, "/")
            argv0_base=parts[n]
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

# check_binary_channel asserts the installed binary matches the
# requested channel. The shell layer already rejects --preview without
# --required-version-2, but the stable channel still resolves via
# `releases/latest` which could be repointed to a server2 build before
# q.sh is updated. Catching the mismatch post-install (with rollback)
# avoids the "I asked for stable and got server2" surprise.
# Returns 0 on match, 1 with CHANNEL_ERR populated on mismatch.
check_binary_channel() {
    _bin="$1"
    _ver="$("$_bin" --version 2>/dev/null || true)"
    CHANNEL_ERR=""
    # Match `server2-` with a trailing hyphen so the substring covers
    # `server2-preview-...` and any future `server2-YYYYMMDD-NN` tag
    # without colliding on a hypothetical `server2x` or version-string
    # value that just happens to embed the letters "server2".
    case "$_ver" in
        *server2-*)
            if [ -z "$REQUIRE_SERVER2" ]; then
                CHANNEL_ERR="Installed binary advertises server2 (--version: '$_ver'). Re-run with --required-version-2 to opt in to the server2 channel, or use --server-release <tag> to pin a stable tag."
                return 1
            fi
            ;;
        *)
            if [ -n "$REQUIRE_SERVER2" ]; then
                CHANNEL_ERR="Installed binary does not advertise server2 (--version: '$_ver'). The server2 channel has no matching release yet; pair --required-version-2 with --preview, or drop --required-version-2."
                return 1
            fi
            ;;
    esac
    return 0
}

# Rollback helper shared by all install_binary failure branches. Calls
# restart_existing_service when an upgrade had a registered service so
# the user is not left with a stopped supervisor after a rollback.
# `die`s on supervisor restart failure (H3) — the operator must know
# the original service is now offline.
install_binary_rollback() {
    _msg="$1"
    rm -f "$INSTALL_PATH"
    rm -f "$_INSTALL_TX_STAGED" 2>/dev/null || true
    if [ -f "$_INSTALL_TX_BACKUP" ]; then
        mv "$_INSTALL_TX_BACKUP" "$INSTALL_PATH" || true
        if [ -n "$IS_UPGRADE" ] && [ -n "$EXISTING_SERVICE" ]; then
            if ! restart_existing_service; then
                # Binary restored, but supervisor refused. Tx is now
                # half-rolled-back: report both errors so the user is
                # not silently left with a stopped service.
                _INSTALL_TX_ACTIVE=""
                die "${_msg} Original binary restored, but original service failed to restart. Run 'launchctl bootstrap gui/\$(id -u) ${HOME}/Library/LaunchAgents/ai.quicktui.plist' (macOS) or 'systemctl --user start quicktui' (Linux) manually."
            fi
        fi
    fi
    _INSTALL_TX_ACTIVE=""
    die "$_msg"
}

install_binary() {
    INSTALL_PATH="${HOME}/.local/bin/quicktui-server"
    mkdir -p "${HOME}/.local/bin"
    # mktemp eliminates the $$-predictable staging path so a co-tenant
    # cannot pre-stage a symlink at the same name (M3). The bin dir is
    # owned by the user and umask 077 limits exposure further.
    _staged_path="$(mktemp "${HOME}/.local/bin/.quicktui-server.new.XXXXXX")"
    _backup_path="$(mktemp -u "${HOME}/.local/bin/.quicktui-server.backup.XXXXXX")"

    if [ -n "$IS_UPGRADE" ]; then
        stop_service_keep_registration
        # stop_binary_processes terminates ANY process whose argv[0]
        # matches $INSTALL_PATH. The service was already asked to stop
        # above, but it may not have exited yet, and manually-launched
        # sessions (started outside the system service) will also be
        # killed. If the binary swap rolls back below,
        # restart_existing_service only restores the launchd / systemd
        # unit — non-service processes are not respawned. Warn once so
        # the user knows to re-run any manual sessions afterwards.
        if list_processes_for_binary "$INSTALL_PATH" 2>/dev/null | grep -q .; then
            warn "Stopping any remaining $INSTALL_PATH processes. Manually-launched sessions will not be restarted automatically; re-run them after the upgrade if needed."
        fi
        stop_binary_processes "$INSTALL_PATH"
    fi

    cp "$DOWNLOADED_BINARY" "$_staged_path"
    chmod 755 "$_staged_path"
    if ! "$_staged_path" --version > /dev/null 2>&1; then
        rm -f "$_staged_path"
        die "Binary replacement failed: staged binary at $_staged_path is not functional."
    fi

    # Begin transaction. Cleanup trap now knows to restore _backup_path
    # if the script dies between here and the matching `_INSTALL_TX_ACTIVE=""`
    # below — signal arriving mid-mv would otherwise leave no binary.
    _INSTALL_TX_ACTIVE="1"
    _INSTALL_TX_PATH="$INSTALL_PATH"
    _INSTALL_TX_STAGED="$_staged_path"
    _INSTALL_TX_BACKUP="$_backup_path"

    if [ -f "$INSTALL_PATH" ]; then
        mv "$INSTALL_PATH" "$_backup_path"
    fi
    if ! mv "$_staged_path" "$INSTALL_PATH"; then
        install_binary_rollback "Binary replacement failed: could not move new binary into place."
    fi

    if ! "$INSTALL_PATH" --version > /dev/null 2>&1; then
        install_binary_rollback "Binary replacement failed: new binary at $INSTALL_PATH is not functional."
    fi

    # Channel guard. Roll back to the previous binary if --version
    # disagrees with --required-version-2. Runs BEFORE the backup is
    # cleared so the rollback path can mv the old binary back into
    # place exactly as the functional-check branch above does.
    if ! check_binary_channel "$INSTALL_PATH"; then
        install_binary_rollback "$CHANNEL_ERR"
    fi

    rm -f "$_backup_path"
    # Transaction committed. Cleanup trap stops trying to roll back.
    _INSTALL_TX_ACTIVE=""
    _INSTALL_TX_PATH=""
    _INSTALL_TX_STAGED=""
    _INSTALL_TX_BACKUP=""
    case ":${PATH}:" in
        *":${HOME}/.local/bin:"*) ;;
        *)
            warn "\$HOME/.local/bin is not in your PATH."
            printf '  Add this to your shell config (~/.bashrc, ~/.zshrc, etc.):\n'
            printf '    export PATH="$HOME/.local/bin:$PATH"\n\n'
            ;;
    esac

    # Remove the downloaded staging dir now that its contents have been
    # cp'd into place; clearing the global afterwards prevents the EXIT
    # trap from trying to remove the same path a second time.
    rm -rf "$DOWNLOAD_TMPDIR"
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
        TOKEN="$(openssl rand -hex 32 2>/dev/null)"
    else
        TOKEN="$(head -c 32 /dev/urandom 2>/dev/null | od -A n -t x1 2>/dev/null | tr -d ' \n')"
    fi
    # Belt-and-suspenders: a silent failure from openssl or /dev/urandom
    # would otherwise produce an empty token that bypasses validate_token
    # on the non-interactive / rotate-token paths.
    validate_token "$TOKEN" || die "Failed to generate a random token (openssl and /dev/urandom both unavailable or failed)."
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
        read -r _choice </dev/tty || die_no_tty
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
                    die_no_tty
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
    # Atomic write: stage all config fields in a same-dir 0600 tempfile
    # and rename into place at the end of write_terminal_config. Writing
    # straight to $QUICKTUI_CONFIG_FILE truncated an existing file
    # before chmod could narrow its mode, exposing the token to other
    # users during the gap (H5).
    _CONFIG_TMP="$(mktemp "${QUICKTUI_CONFIG_DIR}/.config.XXXXXX")"
    chmod 600 "$_CONFIG_TMP"
    printf 'QUICKTUI_TOKEN=%s\n' "$TOKEN" > "$_CONFIG_TMP"
    info "Config staged at $_CONFIG_TMP"
    # QUICKTUI_CN_SERVICE_ENV_ANCHOR
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
        read -r LISTEN_ADDR </dev/tty || die_no_tty
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
        read -r LISTEN_PORT </dev/tty || die_no_tty
        LISTEN_PORT="${LISTEN_PORT:-$_default_port}"
        validate_port "$LISTEN_PORT" || die "Invalid port: '$LISTEN_PORT'. Please enter a number between 1 and 65535."
    fi

    validate_listen_addr "$LISTEN_ADDR" || die "Invalid listen address: '$LISTEN_ADDR'"
    validate_port "$LISTEN_PORT" || die "Invalid port: '$LISTEN_PORT'. Please enter a number between 1 and 65535."

    printf 'QUICKTUI_ADDR=%s:%s\n' "$LISTEN_ADDR" "$LISTEN_PORT" >> "$_CONFIG_TMP"
    info "Listen address: ${LISTEN_ADDR}:${LISTEN_PORT}"
}

# ============================================================
# Write terminal environment to config file
# ============================================================

write_terminal_config() {
    printf 'QUICKTUI_TERM=%s\n' "$TERM_ENV" >> "$_CONFIG_TMP"
    printf 'QUICKTUI_LANG=%s\n' "$LANG_ENV" >> "$_CONFIG_TMP"
    if [ -n "$TMUX_BIN_CONFIG" ]; then
        printf 'QUICKTUI_TMUX_BIN=%s\n' "$TMUX_BIN_CONFIG" >> "$_CONFIG_TMP"
    fi
    # Commit the staged config atomically. After this point cleanup
    # no longer needs to remove the tmpfile.
    mv "$_CONFIG_TMP" "$QUICKTUI_CONFIG_FILE"
    _CONFIG_TMP=""
    info "Config saved to $QUICKTUI_CONFIG_FILE"
}

# ============================================================
# Collect terminal environment values (no config file writes)
# ============================================================

collect_terminal_env() {
    # Defaults: TERM=xterm-256color, LANG=en_US.UTF-8. Preflight downgrades
    # LANG to C.UTF-8 if the primary locale is not available on the host.
    if [ -n "$OPT_TERM" ]; then
        TERM_ENV="$OPT_TERM"
    elif [ -n "$IS_UPGRADE" ] && [ -n "$EXISTING_TERM" ]; then
        TERM_ENV="$EXISTING_TERM"
    else
        TERM_ENV="xterm-256color"
    fi

    if [ -n "$OPT_LANG" ]; then
        LANG_ENV="$OPT_LANG"
    elif [ -n "$IS_UPGRADE" ] && [ -n "$EXISTING_LANG" ]; then
        LANG_ENV="$EXISTING_LANG"
    else
        LANG_ENV="en_US.UTF-8"
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

    # Delegate service registration to the server binary. Capture its output
    # so we can suppress the QR-code reminder line (q.sh re-emits it under
    # "Getting started" in print_success with its own colorization).
    # _SVC_OUT is tracked by the cleanup trap so it is removed even if we
    # are interrupted between mktemp and the rm below.
    _SVC_OUT="$(mktemp)"
    _svc_rc=0
    "$INSTALL_PATH" --install-service \
        --addr "${LISTEN_ADDR}:${LISTEN_PORT}" \
        --term "$TERM_ENV" \
        --lang "$LANG_ENV" > "$_SVC_OUT" 2>&1 || _svc_rc=$?
    # Drop ONLY the server's QR-code reminder line so we can re-emit it
    # under "Getting started" with our own formatting. Any other line that
    # happens to mention --qrcode (e.g. an error message) still shows.
    # Anchor to the literal `'quicktui-server --qrcode'` token that
    # svcinstall.go emits so an unrelated future log line that happens
    # to mention `--qrcode` (e.g. a config-update notice) is still
    # printed. If the server-side string changes, update both this
    # filter and the corresponding contract note in website/AGENTS.md.
    awk "/'quicktui-server --qrcode' to display the connection QR code/ { next } { print }" "$_SVC_OUT"
    rm -f "$_SVC_OUT"
    _SVC_OUT=""

    if [ "$_svc_rc" -eq 0 ]; then
        if [ "$PLATFORM" = "linux" ] && command -v loginctl > /dev/null 2>&1; then
            loginctl enable-linger 2>/dev/null || true
        fi
        SERVICE_STARTED="yes"
        # `--install-service` returning 0 means the unit file was written
        # and the supervisor accepted the load; it does NOT prove the
        # process is serving HTTP yet. q.sh used to probe /v2/healthz but
        # that gate was removed while v2 routes remain preview-stage.
        # Surface a brief verification hint so users have a recovery path
        # if the URL printed under "Getting started" refuses connections.
        if [ "$PLATFORM" = "darwin" ]; then
            warn "Service registered. If the browser URL refuses connections, check ~/Library/Logs/QuickTUI/."
        else
            warn "Service registered. If the browser URL refuses connections, check 'journalctl --user -u quicktui'."
        fi
    else
        SERVICE_STARTED="failed"
        warn "Service registration failed. If a unit file was written, re-run with --uninstall before retrying."
        warn "Retry registration manually:"
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

print_native_qrcode() {
    # Probe /dev/tty in a subshell so a failed redirect (dash kills the
    # parent shell on the brace-group form) cannot abort the installer.
    if [ -c /dev/tty ] && ( : </dev/tty ) 2>/dev/null; then
        "$INSTALL_PATH" --list-addr --qrcode </dev/tty
    else
        "$INSTALL_PATH" --list-addr --qrcode
    fi
}

print_interactive_qrcode() {
    if print_native_qrcode; then
        return 0
    fi

    # Native flow failed (no candidate addrs, abort, etc.). Avoid
    # popping a second address-selection UI on top of the one the
    # server already showed; print a static fallback command users
    # can rerun on demand.
    printf '    Run %s%s --list-addr --qrcode%s to display the QR code.\n' \
        "$C_BOLD$C_GREEN" "$INSTALL_PATH" "$C_RESET"
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
        printf '•••• (full value stored in %s)\n' "$QUICKTUI_CONFIG_FILE"
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
        fi
        printf '\n'
        printf '  ---------- Connect from iOS ----------\n'
        if [ -z "$NON_INTERACTIVE" ]; then
            printf '\n'
            print_interactive_qrcode
        else
            # `quicktui-server --qrcode` alone needs an explicit --addr
            # (qrconnect.Print does not fall back to ~/.config/quicktui
            # /config). Use the IP we already computed for the browser
            # URL so a copy-paste produces a scannable QR immediately.
            printf '    Run:\n'
            printf '      %s%s --qrcode --addr %s:%s%s\n' \
                "$C_BOLD$C_GREEN" "$INSTALL_PATH" "$_ip" "$LISTEN_PORT" "$C_RESET"
            printf '    to display the connection QR code\n'
            printf '    for the iOS app.\n'
        fi
        printf '  --------------------------------------\n'
    elif [ "$SERVICE_STARTED" = "failed" ]; then
        printf 'Service registration failed. Retry registration:\n'
        printf '  %s --install-service --addr %s:%s\n' "$INSTALL_PATH" "$LISTEN_ADDR" "$LISTEN_PORT"
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

    # File-browser access hint. Different OS, different cause; both end up at the
    # same client-side banner pointing to the matching FAQ anchor on quicktui.ai.
    case "$(uname -s)" in
        Darwin)
            printf '\nmacOS: file browser may need Full Disk Access for ~/Desktop, ~/Documents, ~/Downloads — see https://quicktui.ai/#q-tcc-macos\n'
            ;;
        Linux)
            printf '\nLinux: file browser is restricted to paths the service user can read (POSIX / SELinux / AppArmor) — see https://quicktui.ai/#q-permission-linux\n'
            ;;
    esac
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

    # Server-managed teardown (only possible if the binary still
    # exists; --uninstall-service is what removes any state the server
    # itself wrote, e.g. log files or extra defaults).
    if [ -f "$_binary" ]; then
        "$_binary" --uninstall-service 2>/dev/null || true
        _removed=1
    fi

    # Supervisor teardown runs whether or not the binary is on disk.
    # Without this M5 fix, deleting the binary first (or replacing it
    # with a broken one) left an orphaned launchd / systemd unit alive
    # that kept restarting the missing executable.
    if [ "$_os" = "Darwin" ]; then
        if [ -f "$_launchd_plist" ]; then
            launchctl bootout "gui/$(id -u)" "$_launchd_plist" >/dev/null 2>&1 \
                || launchctl unload "$_launchd_plist" >/dev/null 2>&1 \
                || true
            rm -f "$_launchd_plist"
            info "Removed: $_launchd_plist"
            _removed=1
        fi
    else
        if [ -f "$_systemd_service" ] || [ -L "$_systemd_link" ]; then
            if command -v systemctl > /dev/null 2>&1; then
                systemctl --user stop quicktui >/dev/null 2>&1 || true
                systemctl --user disable quicktui >/dev/null 2>&1 || true
            fi
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
            warn "Terminfo entry for \"$TERM_ENV\" not found, falling back to xterm-256color."
            TERM_ENV="xterm-256color"
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

    # `script` has incompatible CLI grammars across implementations:
    #   - util-linux (most Linux distros): `script -qc 'cmd' file`
    #   - busybox (Alpine): `script [-q] file -c 'cmd'`
    #   - BSD / macOS: `script [-q] file utility [args...]`
    # Try each in turn so a host with a different flavour doesn't get a
    # misleading "Cannot allocate a PTY" warning.
    _pty_ok=""
    if [ "$PLATFORM" = "darwin" ]; then
        script -q /dev/null sh -c 'exit 0' < /dev/null > /dev/null 2>&1 && _pty_ok=1
    else
        if script -qc 'exit 0' /dev/null < /dev/null > /dev/null 2>&1 || \
           script -q /dev/null -c 'exit 0' < /dev/null > /dev/null 2>&1 || \
           script /dev/null -c 'exit 0' < /dev/null > /dev/null 2>&1 || \
           script -q /dev/null sh -c 'exit 0' < /dev/null > /dev/null 2>&1; then
            _pty_ok=1
        fi
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
    # Cross-channel switch: surface the swap before downloading
    # anything. Two directions:
    #   1. stable installed + `--preview`  -> stable to preview
    #   2. server2 installed (preview) + no `--required-version-2`
    #      -> server2 to stable (the channel guard will roll the
    #      install back, but warn the user upfront so the abort is
    #      not surprising).
    # Saved config (token/addr/term/lang) is reused as-is in both
    # directions; preview/stable schema compatibility is not
    # guaranteed.
    if [ -n "$IS_UPGRADE" ] && [ "$EXISTING_CHANNEL" = "stable" ] && [ -n "$PREVIEW_RELEASE" ]; then
        warn "--preview will replace the stable install with a server2 preview build."
        warn "Existing config (token/addr/term/lang) will be reused; preview/stable schema compatibility is not guaranteed."
        if ! confirm "Continue switching to the preview channel?" n; then
            exit 1
        fi
    elif [ -n "$IS_UPGRADE" ] && [ "$EXISTING_CHANNEL" = "server2" ] && [ -z "$REQUIRE_SERVER2" ]; then
        warn "Existing install advertises server2 (${EXISTING_VERSION}); the requested channel is stable."
        warn "Without --required-version-2 the channel guard will roll back to the previous binary post-install."
        if ! confirm "Continue switching to the stable channel?" n; then
            exit 1
        fi
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
    # Service registration is on by default. A failure is reported via
    # print_success's "Service registration failed" block, but the
    # process must also exit non-zero so CI / automation does not treat
    # a partial install as success (H2). --no-service users opt out of
    # registration, so SERVICE_STARTED="skipped" still exits 0.
    if [ "$SERVICE_STARTED" = "failed" ]; then
        exit 1
    fi
}

if [ -n "$UNINSTALL" ]; then
    # `--required-version-2` only affects download / channel-guard
    # logic. Surface a warn instead of silently swallowing the flag
    # so users do not assume the channel is being verified during
    # removal.
    [ -n "$REQUIRE_SERVER2" ] && warn "--required-version-2 has no effect with --uninstall; ignoring."
    uninstall
elif [ -n "$CHECK_ONLY" ]; then
    # Same rationale as the --uninstall path: --check runs
    # environment probes only.
    [ -n "$REQUIRE_SERVER2" ] && warn "--required-version-2 has no effect with --check; ignoring."
    validate_cli_options
    validate_cli_terminal_overrides
    detect_existing_install
    detect_platform
    check_tmux
    TERM_ENV="${OPT_TERM:-${EXISTING_TERM:-xterm-256color}}"
    LANG_ENV="${OPT_LANG:-${EXISTING_LANG:-en_US.UTF-8}}"
    preflight_checks || exit 1
else
    main
fi
