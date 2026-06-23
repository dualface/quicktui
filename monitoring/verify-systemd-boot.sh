#!/bin/sh
set -eu

TEST_USER="${QT_VERIFY_USER:-qtuser}"
STATUS_FILE="${QT_VERIFY_STATUS_FILE:-/run/qt-verify.status}"
RESULT_FILE="${QT_VERIFY_RESULT_FILE:-/run/qt-verify-result.json}"
LOG_FILE="${QT_VERIFY_LOG_FILE:-/run/qt-verify-install.log}"
START_EPOCH="$(date +%s)"
START_TIME="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

json_fail() {
    reason=$1
    detail=${2:-}
    finish_epoch="$(date +%s)"
    finish_time="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    elapsed_seconds=$((finish_epoch - START_EPOCH))
    log_tail=""
    if [ -f "$LOG_FILE" ]; then
        log_tail="$(tr '\r' '\n' < "$LOG_FILE" 2>/dev/null | tail -n 120 | sed -E 's/(Authorization: Bearer )[A-Za-z0-9._~+\/=-]+/\1[REDACTED]/g; s/(QUICKTUI_TOKEN=)[^[:space:]]+/\1[REDACTED]/g' || true)"
    fi
    jq -n \
        --arg status "fail" \
        --arg failed_assertion "BOOT" \
        --arg reason "$reason" \
        --arg detail "$detail" \
        --arg site "${SITE:-}" \
        --arg script "${SCRIPT:-}" \
        --arg channel "${CHANNEL:-}" \
        --arg log_tail "$log_tail" \
        --arg start_time "$START_TIME" \
        --arg finish_time "$finish_time" \
        --arg elapsed_seconds "$elapsed_seconds" \
        '{
          status: $status,
          failed_assertion: $failed_assertion,
          reason: $reason,
          detail: $detail,
          failure_stage: "boot",
          site: $site,
          script: $script,
          channel: $channel,
          manifest_url: (if $site == "" then "" else "https://" + $site + "/server-manifest.json" end),
          install_url: (if $site == "" or $script == "" then "" else "https://" + $site + "/" + $script end),
          install_flags: "",
          install_command: "",
          expected_tag: "",
          manifest_tag: "",
          installed_tag: "",
          override_used: false,
          install_exit_code: null,
          installed_binary: "",
          config_file: "",
          service_active: "",
          unit_exec_start: "",
          http_addr: "",
          version_response_version: "",
          expected: {
            tag: "",
            manifest_tag: "",
            manifest_url: (if $site == "" then "" else "https://" + $site + "/server-manifest.json" end),
            install_url: (if $site == "" or $script == "" then "" else "https://" + $site + "/" + $script end),
            install_flags: "",
            install_command: ""
          },
          installed: {
            tag: "",
            binary: "",
            install_exit_code: null,
            service_active: "",
            unit_exec_start: "",
            http_addr: "",
            version_response_version: ""
          },
          timing: {
            start_time: $start_time,
            finish_time: $finish_time,
            elapsed_seconds: ($elapsed_seconds | tonumber)
          },
          assertions: {
            S1: "SKIP",
            S2: "SKIP",
            S3: "SKIP",
            S4: "SKIP",
            S5: "SKIP",
            S6: "SKIP",
            S7: "SKIP"
          },
          log_tail: $log_tail,
          journal_tail: ""
        }' > "$RESULT_FILE" || true
    printf 'FAIL\n' > "$STATUS_FILE" || true
}

[ "$(id -u)" -eq 0 ] || {
    printf 'verify-systemd-boot.sh must run as root\n' >&2
    exit 1
}

if ! id "$TEST_USER" >/dev/null 2>&1; then
    json_fail "test user does not exist" "$TEST_USER"
    exit 1
fi

TEST_UID="$(id -u "$TEST_USER")"
TEST_HOME="$(getent passwd "$TEST_USER" | awk -F: '{print $6}')"
RUNTIME_DIR="/run/user/$TEST_UID"
BUS_ADDRESS="unix:path=$RUNTIME_DIR/bus"

: > "$STATUS_FILE"
: > "$RESULT_FILE"
: > "$LOG_FILE"
chown "$TEST_USER:$TEST_USER" "$STATUS_FILE" "$RESULT_FILE" "$LOG_FILE"

mkdir -p "$RUNTIME_DIR"
chown "$TEST_USER:$TEST_USER" "$RUNTIME_DIR"
chmod 700 "$RUNTIME_DIR"

if ! loginctl enable-linger "$TEST_USER"; then
    json_fail "failed to enable linger for verifier user" "$TEST_USER"
    exit 1
fi

if ! systemctl start "user@$TEST_UID.service"; then
    detail="$(systemctl status "user@$TEST_UID.service" --no-pager 2>&1 || true)"
    json_fail "failed to start user systemd service" "$detail"
    exit 1
fi

i=0
while [ "$i" -lt 100 ]; do
    if runuser -u "$TEST_USER" -- env \
        HOME="$TEST_HOME" \
        XDG_RUNTIME_DIR="$RUNTIME_DIR" \
        DBUS_SESSION_BUS_ADDRESS="$BUS_ADDRESS" \
        systemctl --user list-units >/dev/null 2>&1; then
        break
    fi
    sleep 0.1
    i=$((i + 1))
done

if [ "$i" -ge 100 ]; then
    detail="$(systemctl status "user@$TEST_UID.service" --no-pager 2>&1 || true)"
    json_fail "timed out waiting for user systemd readiness" "$detail"
    exit 1
fi

set +e
runuser -u "$TEST_USER" -- env \
    HOME="$TEST_HOME" \
    USER="$TEST_USER" \
    LOGNAME="$TEST_USER" \
    SITE="${SITE:-}" \
    SCRIPT="${SCRIPT:-}" \
    CHANNEL="${CHANNEL:-}" \
    QT_VERIFY_TEST_MODE="${QT_VERIFY_TEST_MODE:-}" \
    QT_VERIFY_EXPECTED_TAG_OVERRIDE="${QT_VERIFY_EXPECTED_TAG_OVERRIDE:-}" \
    QT_VERIFY_PLAN_ONLY="${QT_VERIFY_PLAN_ONLY:-}" \
    QT_VERIFY_STATUS_FILE="$STATUS_FILE" \
    QT_VERIFY_RESULT_FILE="$RESULT_FILE" \
    QT_VERIFY_LOG_FILE="$LOG_FILE" \
    XDG_RUNTIME_DIR="$RUNTIME_DIR" \
    DBUS_SESSION_BUS_ADDRESS="$BUS_ADDRESS" \
    PATH="$TEST_HOME/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    /bin/sh /usr/local/bin/verify-install.sh
status=$?
set -e

if [ ! -s "$RESULT_FILE" ]; then
    json_fail "verifier exited without a result file" "exit_status=$status"
fi

if [ ! -s "$STATUS_FILE" ]; then
    if [ "$status" -eq 0 ]; then
        printf 'PASS\n' > "$STATUS_FILE" || true
    else
        printf 'FAIL\n' > "$STATUS_FILE" || true
    fi
fi

exit "$status"
