#!/bin/sh
# QuickTUI Unix bootstrap.
# This script only selects, downloads, and launches the native
# quicktui-installer binary. Installation logic lives in the Rust installer and
# the downloaded quicktui-server setup entry.

set -eu

QUICKTUI_REPO="${QUICKTUI_REPO:-dualface/quicktui}"
QUICKTUI_RELEASES="${QUICKTUI_RELEASES:-https://github.com/${QUICKTUI_REPO}/releases/latest/download}"
QUICKTUI_INSTALLER_RELEASE_TAG="${QUICKTUI_INSTALLER_RELEASE_TAG:-installer-20261024-03}"
QUICKTUI_INSTALLER_RELEASES="${QUICKTUI_INSTALLER_RELEASES:-https://github.com/${QUICKTUI_REPO}/releases/download/${QUICKTUI_INSTALLER_RELEASE_TAG}}"
QUICKTUI_UPDATE_MANIFEST_URL="${QUICKTUI_UPDATE_MANIFEST_URL:-https://quicktui.ai/server-manifest.json}"
QUICKTUI_MAX_INSTALLER_BYTES="${QUICKTUI_MAX_INSTALLER_BYTES:-52428800}"
export QUICKTUI_RELEASES QUICKTUI_INSTALLER_RELEASE_TAG QUICKTUI_INSTALLER_RELEASES QUICKTUI_UPDATE_MANIFEST_URL

die() {
    printf 'quicktui bootstrap: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<EOF
QuickTUI Installer Bootstrap

Usage:
  curl -fsSL https://quicktui.ai/q.sh | sh
  curl -fsSL https://quicktui.ai/q.sh | sh -s -- install --channel preview
  curl -fsSL https://quicktui.ai/q.sh | sh -s -- [installer command and options]

This Unix bootstrap downloads quicktui-installer for the current OS/CPU and
executes it with the original arguments. Windows users should download and run
quicktui-installer-windows-<arch>.exe directly.

Installer commands:
  install                   Install or upgrade the QuickTUI server
  check [--server PATH]     Check runtime dependencies of the selected server
  uninstall                 Uninstall existing service via installed server

Install source (choose at most one):
  --channel server2|preview
                            Install from the server2 (official) or preview
                            channel
  --tag TAG                 Install this exact release tag, bypassing manifest
  (none)                    Install the server manifest default channel
                            (server2 when the manifest sets none)

Install options:
  -y, --yes                 Non-interactive mode
      --addr HOST[:PORT]|URL Listen host, host:port, or http(s)://host:port
                            (scheme/quotes stripped; listen stays plain HTTP)
      --port PORT           Listen port used with --addr host
      --term TERM           TERM value for tmux
      --lang LANG           LANG value for tmux
      --no-service          Install binary/config without registering service
  -h, --help                Show this help

Legacy flat compatibility:
  --preview | --publish-tag TAG
  --check [--server PATH] | --uninstall
  --required-version-2      Accepted as a compatibility no-op
  Flat install options without a source use the manifest default channel.

Check source:
  check uses --server PATH when given, then an installed server if available.
  Otherwise it downloads a signed server temporarily. Check does not install it.

Environment:
  QUICKTUI_INSTALLER_RELEASES  Installer binary release base URL. Must use
                                https://, or http:// on loopback (127.0.0.1,
                                [::1], localhost). HTTPS downloads need curl;
                                wget is used only for loopback http
  QUICKTUI_INSTALLER_RELEASE_TAG
                                Installer release tag used by default
  QUICKTUI_RELEASES            Server asset release base URL inherited by installer
  QUICKTUI_UPDATE_MANIFEST_URL Server manifest URL inherited by installer

Server channel:
  With no arguments, bootstrap maps to "install"; the installer then picks
  the server manifest default channel.
  Non-empty command-tree and legacy flat arguments are passed through unchanged.
  Set QUICKTUI_INSTALLER_RELEASES only when the installer binary itself must
  come from a non-default installer release. The current default installer
  tag is ${QUICKTUI_INSTALLER_RELEASE_TAG} and is independent from server
  release tags.
EOF
}

case "${1:-}" in
    -h|--help|help)
        usage
        exit 0
        ;;
esac

# Zero-arg shortcut: plain install, so the installer applies the manifest
# default channel. Non-empty args pass through unchanged.
if [ "$#" -eq 0 ]; then
    set -- install
fi

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "$1 is required"
}

detect_platform() {
    os=$(uname -s 2>/dev/null || true)
    arch=$(uname -m 2>/dev/null || true)

    case "$os" in
        Darwin) platform_os="darwin" ;;
        Linux) platform_os="linux" ;;
        *)
            die "unsupported OS: ${os:-unknown}; Windows users should download quicktui-installer-windows-<arch>.exe"
            ;;
    esac

    case "$arch" in
        x86_64|amd64) platform_arch="amd64" ;;
        arm64|aarch64) platform_arch="arm64" ;;
        *) die "unsupported CPU architecture: ${arch:-unknown}" ;;
    esac
}

log_download_url() {
    printf 'Downloading URL: %s\n' "$1" >&2
}

is_https_url() {
    case "$1" in
        [Hh][Tt][Tt][Pp][Ss]://*) return 0 ;;
    esac
    return 1
}

# Plain http is accepted only for loopback test servers.
is_loopback_http_url() {
    case "$1" in
        [Hh][Tt][Tt][Pp]://*) ;;
        *) return 1 ;;
    esac
    authority=${1#*://}
    authority=${authority%%[/?#]*}
    case "$authority" in
        *@*) return 1 ;;
        \[*) host="${authority%%]*}]" ;;
        *) host=${authority%%:*} ;;
    esac
    port=${authority#"$host"}
    case "$port" in
        ''|:*[!0-9]*) [ -z "$port" ] || return 1 ;;
        :) return 1 ;;
        :*) ;;
        *) return 1 ;;
    esac
    case "$(printf '%s' "$host" | tr 'A-Z' 'a-z')" in
        127.0.0.1|localhost|'[::1]') return 0 ;;
    esac
    return 1
}

download_installer() {
    case "$QUICKTUI_MAX_INSTALLER_BYTES" in
        ''|*[!0-9]*) die "QUICKTUI_MAX_INSTALLER_BYTES must be a byte count" ;;
    esac
    log_download_url "$1"
    if is_https_url "$1"; then
        https_only=1
    elif is_loopback_http_url "$1"; then
        https_only=
    else
        die "refusing a non-HTTPS installer download URL; use https://, or http:// on loopback (127.0.0.1, [::1], localhost)"
    fi
    if command -v curl >/dev/null 2>&1; then
        if [ -n "$https_only" ]; then
            curl -fsSL --proto '=https' --proto-redir '=https' --max-filesize "$QUICKTUI_MAX_INSTALLER_BYTES" "$1" -o "$2"
        else
            curl -fsSL --max-filesize "$QUICKTUI_MAX_INSTALLER_BYTES" "$1" -o "$2"
        fi
    elif command -v wget >/dev/null 2>&1; then
        # GNU wget 1.x and BusyBox wget cannot refuse HTTPS-to-HTTP redirects.
        [ -z "$https_only" ] || die "wget cannot restrict redirects to HTTPS, so the installer download could fall back to plain HTTP; install curl and retry"
        wget -qO "$2" "$1"
    else
        die "curl or wget is required to download quicktui-installer"
    fi
}

check_installer_size() {
    file=$1
    size=$(wc -c < "$file" | awk '{print $1}') || die "cannot read downloaded installer size"
    case "$size" in
        ''|*[!0-9]*) die "cannot read downloaded installer size" ;;
    esac
    if [ "$size" -gt "$QUICKTUI_MAX_INSTALLER_BYTES" ]; then
        die "installer download exceeds ${QUICKTUI_MAX_INSTALLER_BYTES} bytes"
    fi
}

need_cmd uname
detect_platform

asset="quicktui-installer-${platform_os}-${platform_arch}"
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/quicktui-installer.XXXXXX") || die "mktemp failed"
cleanup() { rm -rf "$tmp_dir"; }
trap cleanup EXIT HUP INT TERM

base_url=${QUICKTUI_INSTALLER_RELEASES%/}
installer_url="${base_url}/${asset}"
installer="${tmp_dir}/${asset}"

printf 'Downloading installer asset: %s\n' "$asset" >&2
download_installer "$installer_url" "$installer" || die "download failed: $installer_url"
check_installer_size "$installer"
chmod +x "$installer"

exec "$installer" "$@"
