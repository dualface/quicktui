#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
REPO_DIR="$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)"
INSTALL_SCRIPT="${REPO_DIR}/q.sh"
SNAPSHOT_DIR="${SCRIPT_DIR}/snapshots"
WRITE_MODE=""

usage() {
    printf 'Usage: %s [--write-snapshots]\n' "$0" >&2
}

if [ "${1:-}" = "--write-snapshots" ]; then
    WRITE_MODE=1
    shift
fi

if [ "$#" -ne 0 ]; then
    usage
    exit 1
fi

TMP_ROOT="$(mktemp -d)"
TMP_HOME="${TMP_ROOT}/home"
TMP_OUTPUT_DIR="${TMP_ROOT}/outputs"
mkdir -p "$TMP_HOME" "$TMP_OUTPUT_DIR" "$SNAPSHOT_DIR"

cleanup() {
    rm -rf "$TMP_ROOT"
}

trap cleanup EXIT INT TERM HUP

capture_snapshot() {
    _name="$1"
    shift

    env -i \
        PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
        HOME="$TMP_HOME" \
        SHELL="/bin/sh" \
        LANG="en_US.UTF-8" \
        LC_ALL="en_US.UTF-8" \
        TERM="xterm-256color" \
        "$@" > "${TMP_OUTPUT_DIR}/${_name}" 2>&1
}

capture_snapshot "q-sh-help.txt" sh "$INSTALL_SCRIPT" --help
capture_snapshot "q-sh-check.txt" sh "$INSTALL_SCRIPT" --check

if [ -n "$WRITE_MODE" ]; then
    cp "${TMP_OUTPUT_DIR}/q-sh-help.txt" "${SNAPSHOT_DIR}/q-sh-help.txt"
    cp "${TMP_OUTPUT_DIR}/q-sh-check.txt" "${SNAPSHOT_DIR}/q-sh-check.txt"
    printf 'Wrote snapshot: %s\n' "${SNAPSHOT_DIR}/q-sh-help.txt"
    printf 'Wrote snapshot: %s\n' "${SNAPSHOT_DIR}/q-sh-check.txt"
    exit 0
fi

SNAPSHOT_FAILURES=0
for _snapshot in q-sh-help.txt q-sh-check.txt; do
    if [ ! -f "${SNAPSHOT_DIR}/${_snapshot}" ]; then
        printf 'Missing snapshot: %s\n' "${SNAPSHOT_DIR}/${_snapshot}" >&2
        SNAPSHOT_FAILURES=1
        continue
    fi

    if ! cmp -s "${TMP_OUTPUT_DIR}/${_snapshot}" "${SNAPSHOT_DIR}/${_snapshot}"; then
        printf 'Snapshot mismatch: %s\n' "$_snapshot" >&2
        diff -u "${SNAPSHOT_DIR}/${_snapshot}" "${TMP_OUTPUT_DIR}/${_snapshot}" || true
        SNAPSHOT_FAILURES=1
    fi
done

if [ "$SNAPSHOT_FAILURES" -ne 0 ]; then
    exit 1
fi

printf 'Snapshot baselines match.\n'
