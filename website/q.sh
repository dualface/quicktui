#!/bin/sh
# QuickTUI Unix bootstrap.
# This script only selects, verifies when possible, and launches the native
# quicktui-installer binary. Installation logic lives in the Rust installer and
# the downloaded quicktui-server setup entry.

set -eu

QUICKTUI_REPO="${QUICKTUI_REPO:-dualface/quicktui}"
QUICKTUI_RELEASES="${QUICKTUI_RELEASES:-https://github.com/${QUICKTUI_REPO}/releases/latest/download}"
QUICKTUI_INSTALLER_RELEASE_TAG="${QUICKTUI_INSTALLER_RELEASE_TAG:-installer-20260927-01}"
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
  --channel stable|preview|server2
                            Install from the stable (legacy server), server2
                            (new server stable), or preview channel
  --tag TAG                 Install this exact release tag, bypassing manifest
  (none)                    Install the server manifest default channel
                            (stable when the manifest sets none)

Install options:
  -y, --yes                 Non-interactive mode
      --token TOKEN         Set a schema v1 server access token
      --rotate-token        Generate a new schema v1 server access token
      --addr HOST[:PORT]|URL Listen host, host:port, or http(s)://host:port
                            (scheme/quotes stripped; listen stays plain HTTP)
      --port PORT           Listen port used with --addr host
      --term TERM           TERM value for tmux
      --lang LANG           LANG value for tmux
      --no-service          Install binary/config without registering service
  -h, --help                Show this help

Legacy flat compatibility:
  --release | --preview | --publish-tag TAG
  --check [--server PATH] | --uninstall
  --required-version-2      Accepted as a compatibility no-op
  Flat install options without a source use the manifest default channel.
  Token options fail explicitly when the selected server uses tokenless schema v2.

Check source:
  check uses --server PATH when given, then an installed server if available.
  Otherwise it downloads a signed server temporarily. Check does not install it.

Environment:
  QUICKTUI_INSTALLER_RELEASES  Installer binary release base URL
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

download() {
    log_download_url "$1"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$1" -o "$2"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$2" "$1"
    else
        die "curl or wget is required to download quicktui-installer"
    fi
}

download_installer() {
    case "$QUICKTUI_MAX_INSTALLER_BYTES" in
        ''|*[!0-9]*) die "QUICKTUI_MAX_INSTALLER_BYTES must be a byte count" ;;
    esac
    if command -v curl >/dev/null 2>&1; then
        log_download_url "$1"
        curl -fsSL --max-filesize "$QUICKTUI_MAX_INSTALLER_BYTES" "$1" -o "$2"
    else
        download "$1" "$2"
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

sha256_file() {
    file=$1
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$file" | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "$file" | awk '{print $NF}'
    else
        return 127
    fi
}

verify_installer_if_possible() {
    file=$1
    sha_file=$2
    checksum_available=${3:-0}
    if [ "$checksum_available" != "1" ]; then
        printf 'quicktui bootstrap: warning: installer checksum not available; continuing without local verification\n' >&2
        return 0
    fi
    expected=$(awk '{print $1; exit}' "$sha_file")
    case "$expected" in
        ''|*[!0-9a-fA-F]*) die "invalid installer checksum file" ;;
    esac
    [ "${#expected}" -eq 64 ] || die "invalid installer checksum file"
    if actual=$(sha256_file "$file" 2>/dev/null); then
        expected=$(printf '%s' "$expected" | tr 'A-F' 'a-f')
        actual=$(printf '%s' "$actual" | tr 'A-F' 'a-f')
        [ "$actual" = "$expected" ] || die "installer sha256 mismatch"
    else
        printf 'quicktui bootstrap: warning: no local sha256 tool found; continuing without local verification\n' >&2
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
sha_url="${installer_url}.sha256"

installer="${tmp_dir}/${asset}"
sha_file="${installer}.sha256"

printf 'Downloading installer asset: %s\n' "$asset" >&2
download_installer "$installer_url" "$installer" || die "download failed: $installer_url"
check_installer_size "$installer"
checksum_available=0
if download "$sha_url" "$sha_file"; then
    checksum_available=1
else
    : > "$sha_file"
fi
verify_installer_if_possible "$installer" "$sha_file" "$checksum_available"
chmod +x "$installer"

exec "$installer" "$@"
