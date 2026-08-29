#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
IMAGE="${QT_VERIFY_IMAGE:-quicktui-install-verifier}"
NAME="${QT_VERIFY_CONTAINER:-quicktui-install-verifier-$$}"
TIMEOUT_SECONDS="${QT_VERIFY_TIMEOUT_SECONDS:-900}"
ARTIFACT_DIR="${QT_VERIFY_ARTIFACT_DIR:-$REPO_ROOT/.verify-artifacts}"
CID=""
ENV_FILE=""

usage() {
    cat <<'EOF'
Usage:
  sh monitoring/run-verify-docker.sh --site quicktui.ai --script q.sh --channel stable

Options:
  --site HOST          Public site hostname, without scheme or path.
  --script NAME       Installer script basename, for example q.sh.
  --channel CHANNEL   stable or preview.

Test-only environment:
  QT_VERIFY_TEST_MODE=1 QT_VERIFY_EXPECTED_TAG_OVERRIDE=bad-tag
  QT_VERIFY_TEST_MODE=1 QT_VERIFY_PLAN_ONLY=1
EOF
}

die() {
    printf 'quicktui verify docker: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    if [ -n "${CID:-}" ]; then
        docker rm -f "$CID" >/dev/null 2>&1 || true
    fi
    if [ -n "${ENV_FILE:-}" ]; then
        rm -f "$ENV_FILE"
    fi
}

show_journal() {
    if [ -n "${CID:-}" ]; then
        docker exec "$CID" journalctl -u qt-verify.service --no-pager 2>/dev/null || true
    fi
}

show_result() {
    if [ -f "$ARTIFACT_DIR/qt-verify-result.json" ]; then
        jq . "$ARTIFACT_DIR/qt-verify-result.json" || true
    fi
}

copy_result() {
    if [ -z "${CID:-}" ]; then
        return 0
    fi
    mkdir -p "$ARTIFACT_DIR"
    i=0
    while [ "$i" -lt 25 ]; do
        if docker exec "$CID" sh -c 'test -s /run/qt-verify-result.json && jq -e . /run/qt-verify-result.json >/dev/null 2>&1' >/dev/null 2>&1; then
            break
        fi
        sleep 0.2
        i=$((i + 1))
    done
    docker exec "$CID" cat /run/qt-verify-result.json > "$ARTIFACT_DIR/qt-verify-result.json" 2>/dev/null || true
    docker exec "$CID" cat /run/qt-verify-install.log > "$ARTIFACT_DIR/qt-verify-install.log" 2>/dev/null || true
}

require_value() {
    [ "$#" -ge 2 ] || die "$1 requires a value"
    [ -n "$2" ] || die "$1 requires a non-empty value"
}

SITE=""
SCRIPT=""
CHANNEL=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --site)
            require_value "$@"
            SITE=$2
            shift 2
            ;;
        --script)
            require_value "$@"
            SCRIPT=$2
            shift 2
            ;;
        --channel)
            require_value "$@"
            CHANNEL=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
done

[ -n "$SITE" ] || die "--site is required"
[ -n "$SCRIPT" ] || die "--script is required"
[ -n "$CHANNEL" ] || die "--channel is required"

case "$SITE" in
    quicktui.ai|dl.quicktui.cn) ;;
    *) die "--site must be quicktui.ai or dl.quicktui.cn" ;;
esac

case "$SCRIPT" in
    q.sh|q2.sh) ;;
    *) die "--script must be q.sh or q2.sh" ;;
esac

case "$CHANNEL" in
    stable|preview) ;;
    *) die "--channel must be stable or preview" ;;
esac

if [ "$SCRIPT:$CHANNEL" = "q2.sh:stable" ]; then
    die "q2.sh stable is not a supported monitor cell; q2.sh currently supports preview only"
fi

case "$TIMEOUT_SECONDS" in
    ''|*[!0-9]*) die "QT_VERIFY_TIMEOUT_SECONDS must be an integer number of seconds" ;;
esac

case "${QT_VERIFY_TEST_MODE:-}" in
    ""|0|1) ;;
    *) die "QT_VERIFY_TEST_MODE must be 1 when set" ;;
esac
case "${QT_VERIFY_PLAN_ONLY:-}" in
    ""|0|1) ;;
    *) die "QT_VERIFY_PLAN_ONLY must be 1 when set" ;;
esac
if [ "${QT_VERIFY_PLAN_ONLY:-}" = "1" ] && [ "${QT_VERIFY_TEST_MODE:-}" != "1" ]; then
    die "QT_VERIFY_PLAN_ONLY requires QT_VERIFY_TEST_MODE=1"
fi

if [ -n "${QT_VERIFY_EXPECTED_TAG_OVERRIDE:-}" ] && [ "${QT_VERIFY_TEST_MODE:-}" != "1" ]; then
    die "QT_VERIFY_EXPECTED_TAG_OVERRIDE requires QT_VERIFY_TEST_MODE=1"
fi
case "${QT_VERIFY_EXPECTED_TAG_OVERRIDE:-}" in
    *[!A-Za-z0-9._-]*) die "QT_VERIFY_EXPECTED_TAG_OVERRIDE contains unsupported characters" ;;
esac

command -v docker >/dev/null 2>&1 || die "docker is required"

mkdir -p "$ARTIFACT_DIR"
rm -f "$ARTIFACT_DIR/qt-verify-result.json" "$ARTIFACT_DIR/qt-verify-install.log"

ENV_FILE="$(mktemp "${TMPDIR:-/tmp}/qt-verify-env.XXXXXX")"
case "$ENV_FILE" in
    "$REPO_ROOT"/*) die "temporary environment file resolved inside repository: $ENV_FILE" ;;
esac
{
    printf 'SITE=%s\n' "$SITE"
    printf 'SCRIPT=%s\n' "$SCRIPT"
    printf 'CHANNEL=%s\n' "$CHANNEL"
    printf 'QT_VERIFY_TEST_MODE=%s\n' "${QT_VERIFY_TEST_MODE:-}"
    printf 'QT_VERIFY_EXPECTED_TAG_OVERRIDE=%s\n' "${QT_VERIFY_EXPECTED_TAG_OVERRIDE:-}"
    printf 'QT_VERIFY_PLAN_ONLY=%s\n' "${QT_VERIFY_PLAN_ONLY:-}"
} > "$ENV_FILE"

printf 'quicktui verify docker: building image %s\n' "$IMAGE"
docker build -f "$REPO_ROOT/monitoring/Dockerfile.verify" -t "$IMAGE" "$REPO_ROOT"

printf 'quicktui verify docker: running site=%s script=%s channel=%s\n' "$SITE" "$SCRIPT" "$CHANNEL"
CID="$(docker run -d \
    --name "$NAME" \
    --privileged \
    --cgroupns=host \
    --tmpfs /run \
    --tmpfs /run/lock \
    -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
    -v "$ENV_FILE:/etc/qt-verify.env:ro" \
    -e "SITE=$SITE" \
    -e "SCRIPT=$SCRIPT" \
    -e "CHANNEL=$CHANNEL" \
    -e "QT_VERIFY_TEST_MODE=${QT_VERIFY_TEST_MODE:-}" \
    -e "QT_VERIFY_EXPECTED_TAG_OVERRIDE=${QT_VERIFY_EXPECTED_TAG_OVERRIDE:-}" \
    -e "QT_VERIFY_PLAN_ONLY=${QT_VERIFY_PLAN_ONLY:-}" \
    "$IMAGE")"
trap cleanup EXIT HUP INT TERM

deadline=$(($(date +%s) + TIMEOUT_SECONDS))
while [ "$(date +%s)" -lt "$deadline" ]; do
    if [ "$(docker inspect -f '{{.State.Running}}' "$CID" 2>/dev/null || printf false)" != "true" ]; then
        copy_result
        show_journal
        exit_code="$(docker inspect -f '{{.State.ExitCode}}' "$CID" 2>/dev/null || printf 1)"
        die "container exited before verifier status was written (exit $exit_code)"
    fi

    if docker exec "$CID" test -s /run/qt-verify.status >/dev/null 2>&1; then
        status="$(docker exec "$CID" cat /run/qt-verify.status | tr -d '\r\n')"
        copy_result
        show_journal
        show_result
        case "$status" in
            PASS) exit 0 ;;
            SKIP) exit 0 ;;
            FAIL) exit 1 ;;
            ''|*[!A-Z]*) die "invalid verifier status: ${status:-empty}" ;;
            *) die "unknown verifier status: $status" ;;
        esac
    fi

    props="$(docker exec "$CID" systemctl show qt-verify.service -p ActiveState -p Result --no-pager 2>/dev/null || true)"
    active="$(printf '%s\n' "$props" | awk -F= '$1 == "ActiveState" { print $2; exit }')"
    result="$(printf '%s\n' "$props" | awk -F= '$1 == "Result" { print $2; exit }')"
    if [ "$active" = "failed" ] || { [ "$active" = "inactive" ] && [ -n "$result" ] && [ "$result" != "success" ]; }; then
        copy_result
        show_journal
        show_result
        die "qt-verify.service failed: ActiveState=${active:-unknown} Result=${result:-unknown}"
    fi

    sleep 1
done

copy_result
show_journal
show_result
die "timed out waiting for qt-verify.service"
