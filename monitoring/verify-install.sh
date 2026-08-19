#!/bin/sh
set -u

STATUS_FILE="${QT_VERIFY_STATUS_FILE:-/run/qt-verify.status}"
RESULT_FILE="${QT_VERIFY_RESULT_FILE:-/run/qt-verify-result.json}"
LOG_FILE="${QT_VERIFY_LOG_FILE:-/run/qt-verify-install.log}"
INSTALL_BIN="$HOME/.local/bin/quicktui-server"
CONFIG_FILE="$HOME/.config/quicktui-server-v2/config.toml"
SERVICE_UNIT="$HOME/.config/systemd/user/quicktui.service"
RETRY_ATTEMPTS="${QT_VERIFY_RETRY_ATTEMPTS:-3}"
MANIFEST_TIMEOUT_SECONDS="${QT_VERIFY_MANIFEST_TIMEOUT_SECONDS:-20}"
INSTALL_TIMEOUT_SECONDS="${QT_VERIFY_INSTALL_TIMEOUT_SECONDS:-300}"
SERVICE_ATTEMPTS="${QT_VERIFY_SERVICE_ATTEMPTS:-30}"
VERSION_ATTEMPTS="${QT_VERIFY_VERSION_ATTEMPTS:-100}"
START_EPOCH="$(date +%s)"
START_TIME="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

S1="SKIP"
S2="SKIP"
S3="SKIP"
S4="SKIP"
S5="SKIP"
S6="SKIP"
S7="SKIP"

install_exit_code=""
installed_tag=""
expected_tag=""
manifest_tag=""
manifest_url=""
install_url=""
install_flags=""
install_command_display=""
service_active=""
unit_exec_start=""
version_response_version=""
version_response_endpoint=""
http_addr=""
override_used="false"
failure_stage=""

sanitize_tail() {
    if [ -f "$LOG_FILE" ]; then
        tr '\r' '\n' < "$LOG_FILE" 2>/dev/null \
            | tail -n 120 \
            | sed -E 's/(Authorization: Bearer )[A-Za-z0-9._~+\/=-]+/\1[REDACTED]/g; s/(QUICKTUI_TOKEN=)[^[:space:]]+/\1[REDACTED]/g; s/(token[[:space:]]*=[[:space:]]*)"[^"]*"/\1"[REDACTED]"/g'
    fi
}

sanitize_journal_tail() {
    if command -v journalctl >/dev/null 2>&1; then
        journalctl --user -u quicktui.service -n 80 --no-pager 2>/dev/null \
            | sed -E 's/(Authorization: Bearer )[A-Za-z0-9._~+\/=-]+/\1[REDACTED]/g; s/(QUICKTUI_TOKEN=)[^[:space:]]+/\1[REDACTED]/g; s/(token[[:space:]]*=[[:space:]]*)"[^"]*"/\1"[REDACTED]"/g' \
            || true
    fi
}

status_file_value() {
    case "$1" in
        pass|PASS) printf 'PASS' ;;
        fail|FAIL) printf 'FAIL' ;;
        skip|SKIP) printf 'SKIP' ;;
        *) printf '%s' "$1" ;;
    esac
}

write_result() {
    result_status=$1
    failed_assertion=$2
    reason=$3
    finish_epoch="$(date +%s)"
    finish_time="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    elapsed_seconds=$((finish_epoch - START_EPOCH))
    log_tail="$(sanitize_tail)"
    journal_tail="$(sanitize_journal_tail)"
    jq -n \
        --arg status "$result_status" \
        --arg failed_assertion "$failed_assertion" \
        --arg reason "$reason" \
        --arg failure_stage "$failure_stage" \
        --arg site "${SITE:-}" \
        --arg script "${SCRIPT:-}" \
        --arg channel "${CHANNEL:-}" \
        --arg manifest_url "$manifest_url" \
        --arg install_url "$install_url" \
        --arg install_flags "$install_flags" \
        --arg install_command "$install_command_display" \
        --arg expected_tag "$expected_tag" \
        --arg manifest_tag "$manifest_tag" \
        --arg installed_tag "$installed_tag" \
        --arg override_used "$override_used" \
        --arg install_exit_code "$install_exit_code" \
        --arg installed_binary "$INSTALL_BIN" \
        --arg config_file "$CONFIG_FILE" \
        --arg service_active "$service_active" \
        --arg unit_exec_start "$unit_exec_start" \
        --arg http_addr "$http_addr" \
        --arg version_response_version "$version_response_version" \
        --arg version_response_endpoint "$version_response_endpoint" \
        --arg s1 "$S1" \
        --arg s2 "$S2" \
        --arg s3 "$S3" \
        --arg s4 "$S4" \
        --arg s5 "$S5" \
        --arg s6 "$S6" \
        --arg s7 "$S7" \
        --arg log_tail "$log_tail" \
        --arg journal_tail "$journal_tail" \
        --arg start_time "$START_TIME" \
        --arg finish_time "$finish_time" \
        --arg elapsed_seconds "$elapsed_seconds" \
        '{
          status: $status,
          failed_assertion: $failed_assertion,
          reason: $reason,
          failure_stage: $failure_stage,
          site: $site,
          script: $script,
          channel: $channel,
          manifest_url: $manifest_url,
          install_url: $install_url,
          install_flags: $install_flags,
          install_command: $install_command,
          expected_tag: $expected_tag,
          manifest_tag: $manifest_tag,
          installed_tag: $installed_tag,
          override_used: ($override_used == "true"),
          install_exit_code: (if $install_exit_code == "" then null else ($install_exit_code | tonumber?) end),
          installed_binary: $installed_binary,
          config_file: $config_file,
          service_active: $service_active,
          unit_exec_start: $unit_exec_start,
          http_addr: $http_addr,
          version_response_version: $version_response_version,
          version_response_endpoint: $version_response_endpoint,
          expected: {
            tag: $expected_tag,
            manifest_tag: $manifest_tag,
            manifest_url: $manifest_url,
            install_url: $install_url,
            install_flags: $install_flags,
            install_command: $install_command
          },
          installed: {
            tag: $installed_tag,
            binary: $installed_binary,
            install_exit_code: (if $install_exit_code == "" then null else ($install_exit_code | tonumber?) end),
            service_active: $service_active,
            unit_exec_start: $unit_exec_start,
            http_addr: $http_addr,
            version_response_version: $version_response_version,
            version_response_endpoint: $version_response_endpoint
          },
          timing: {
            start_time: $start_time,
            finish_time: $finish_time,
            elapsed_seconds: ($elapsed_seconds | tonumber)
          },
          assertions: {
            S1: $s1,
            S2: $s2,
            S3: $s3,
            S4: $s4,
            S5: $s5,
            S6: $s6,
            S7: $s7
          },
          log_tail: $log_tail,
          journal_tail: $journal_tail
        }' > "$RESULT_FILE"
    status_value="$(status_file_value "$result_status")"
    printf '%s\n' "$status_value" > "$STATUS_FILE"
}

fail_assertion() {
    assertion=$1
    reason=$2
    write_result "fail" "$assertion" "$reason"
    exit 1
}

skip_cell() {
    reason=$1
    write_result "skip" "" "$reason"
    exit 0
}

pass_assertion() {
    case "$1" in
        S1) S1="PASS" ;;
        S2) S2="PASS" ;;
        S3) S3="PASS" ;;
        S4) S4="PASS" ;;
        S5) S5="PASS" ;;
        S6) S6="PASS" ;;
        S7) S7="PASS" ;;
    esac
}

require_env() {
    name=$1
    value=$(eval "printf '%s' \"\${$name:-}\"")
    [ -n "$value" ] || fail_assertion "INPUT" "$name is required"
}

require_positive_int() {
    name=$1
    value=$2
    case "$value" in
        ''|*[!0-9]*) failure_stage="input"; fail_assertion "INPUT" "$name must be a positive integer" ;;
        0) failure_stage="input"; fail_assertion "INPUT" "$name must be greater than zero" ;;
    esac
}

is_stable_tag() {
    printf '%s\n' "$1" | grep -Eq '^[0-9]{8}-[0-9]{2}$'
}

is_preview_tag() {
    printf '%s\n' "$1" | grep -Eq '^server2?-preview-[0-9]{8}-[0-9]{6}-[A-Za-z0-9._-]+$'
}

config_value() {
    key=$1
    [ -f "$CONFIG_FILE" ] || return 0
    case "$key" in
        QUICKTUI_ADDR) toml_key=addr ;;
        QUICKTUI_UPDATE_CHANNEL) toml_key=update_channel ;;
        *) fail_assertion "CONFIG" "unsupported config key: $key" ;;
    esac
    awk -F' = ' -v key="$toml_key" '$1 == key {
        value = substr($0, length(key) + 4)
        if (value ~ /^".*"$/) value = substr(value, 2, length(value) - 2)
        print value
        exit
    }' "$CONFIG_FILE"
}

config_token() {
    "$INSTALL_BIN" config token show --config "$CONFIG_FILE"
}

require_env SITE
require_env SCRIPT
require_env CHANNEL
require_positive_int QT_VERIFY_RETRY_ATTEMPTS "$RETRY_ATTEMPTS"
require_positive_int QT_VERIFY_MANIFEST_TIMEOUT_SECONDS "$MANIFEST_TIMEOUT_SECONDS"
require_positive_int QT_VERIFY_INSTALL_TIMEOUT_SECONDS "$INSTALL_TIMEOUT_SECONDS"
require_positive_int QT_VERIFY_SERVICE_ATTEMPTS "$SERVICE_ATTEMPTS"
require_positive_int QT_VERIFY_VERSION_ATTEMPTS "$VERSION_ATTEMPTS"

case "$SITE" in
    quicktui.ai|dl.quicktui.cn) ;;
    *) fail_assertion "INPUT" "SITE must be quicktui.ai or dl.quicktui.cn" ;;
esac

case "$SCRIPT" in
    q.sh) ;;
    *) fail_assertion "INPUT" "SCRIPT must be q.sh" ;;
esac

case "$CHANNEL" in
    stable|preview) ;;
    *) fail_assertion "INPUT" "CHANNEL must be stable or preview" ;;
esac

install_url="https://${SITE}/${SCRIPT}"
manifest_url="https://${SITE}/server-manifest.json"
if [ "${QT_VERIFY_TEST_MODE:-}" = "1" ] && [ -n "${QT_VERIFY_EXPECTED_TAG_OVERRIDE:-}" ]; then
    expected_tag="$QT_VERIFY_EXPECTED_TAG_OVERRIDE"
    override_used="true"
fi

case "$SCRIPT:$CHANNEL" in
    q.sh:stable)
        install_flags="install --channel stable -y"
        install_command_display="curl -fsSL ${install_url} | sh -s -- ${install_flags}"
        ;;
    q.sh:preview)
        install_flags="install --channel preview -y"
        install_command_display="curl -fsSL ${install_url} | sh -s -- ${install_flags}"
        ;;
esac

run_install_command() {
    if [ "${QT_VERIFY_TEST_MODE:-}" = "1" ] && [ "${QT_VERIFY_FORCE_INSTALL_FAILURE:-}" = "1" ]; then
        printf 'forced install execution failure for verifier test mode\n' >&2
        return 42
    fi
    case "$SCRIPT:$CHANNEL" in
        q.sh:stable)
            timeout "$INSTALL_TIMEOUT_SECONDS" bash -o pipefail -c 'curl -fsSL "$1" | sh -s -- install --channel stable -y' sh "$install_url"
            ;;
        q.sh:preview)
            timeout "$INSTALL_TIMEOUT_SECONDS" bash -o pipefail -c 'curl -fsSL "$1" | sh -s -- install --channel preview -y' sh "$install_url"
            ;;
    esac
}

fetch_manifest_once() {
    manifest_path=$1
    if [ "${QT_VERIFY_TEST_MODE:-}" = "1" ] && [ "${QT_VERIFY_FORCE_MANIFEST_FAILURE:-}" = "1" ]; then
        printf 'forced manifest fetch failure for verifier test mode\n' >&2
        return 42
    fi
    if [ "${QT_VERIFY_TEST_MODE:-}" = "1" ] && [ -n "${QT_VERIFY_MANIFEST_FILE:-}" ]; then
        cp "$QT_VERIFY_MANIFEST_FILE" "$manifest_path"
        return $?
    fi
    timeout "$MANIFEST_TIMEOUT_SECONDS" curl -fsSL "$manifest_url" -o "$manifest_path"
}

fetch_manifest_with_retry() {
    manifest_path=$1
    i=1
    last_exit=0
    while [ "$i" -le "$RETRY_ATTEMPTS" ]; do
        printf 'manifest_fetch attempt %s/%s with timeout %ss\n' "$i" "$RETRY_ATTEMPTS" "$MANIFEST_TIMEOUT_SECONDS" >> "$LOG_FILE"
        set +e
        fetch_manifest_once "$manifest_path" >> "$LOG_FILE" 2>&1
        last_exit=$?
        set +e
        if [ "$last_exit" -eq 0 ]; then
            printf 'manifest_fetch attempt %s/%s succeeded\n' "$i" "$RETRY_ATTEMPTS" >> "$LOG_FILE"
            return 0
        fi
        printf 'manifest_fetch attempt %s/%s failed with exit %s\n' "$i" "$RETRY_ATTEMPTS" "$last_exit" >> "$LOG_FILE"
        i=$((i + 1))
    done
    return "$last_exit"
}

run_install_with_retry() {
    i=1
    install_exit_code=0
    while [ "$i" -le "$RETRY_ATTEMPTS" ]; do
        printf 'install_execution attempt %s/%s with timeout %ss\n' "$i" "$RETRY_ATTEMPTS" "$INSTALL_TIMEOUT_SECONDS" >> "$LOG_FILE"
        set +e
        run_install_command >> "$LOG_FILE" 2>&1
        install_exit_code=$?
        set +e
        if [ "$install_exit_code" -eq 0 ]; then
            printf 'install_execution attempt %s/%s succeeded\n' "$i" "$RETRY_ATTEMPTS" >> "$LOG_FILE"
            return 0
        fi
        printf 'install_execution attempt %s/%s failed with exit %s\n' "$i" "$RETRY_ATTEMPTS" "$install_exit_code" >> "$LOG_FILE"
        i=$((i + 1))
    done
    return "$install_exit_code"
}

: > "$LOG_FILE"
printf 'Running install command: %s\n' "$install_command_display" >> "$LOG_FILE"

if [ "${QT_VERIFY_TEST_MODE:-}" = "1" ] && [ "${QT_VERIFY_PLAN_ONLY:-}" = "1" ]; then
    write_result "pass" "" "plan-only command construction completed"
    exit 0
fi

manifest_file="$(mktemp "${TMPDIR:-/tmp}/qt-verify-manifest.XXXXXX")"
if fetch_manifest_with_retry "$manifest_file"; then
    manifest_tag="$(jq -r --arg channel "$CHANNEL" '.[$channel].tag // empty' "$manifest_file" 2>>"$LOG_FILE" || true)"
    rm -f "$manifest_file"
else
    rm -f "$manifest_file"
    S4="FAIL"
    failure_stage="manifest_fetch"
    fail_assertion "S4" "manifest fetch exhausted after $RETRY_ATTEMPTS attempts: $manifest_url"
fi

if [ -z "$manifest_tag" ] || [ "$manifest_tag" = "null" ]; then
    S4="SKIP"
    case "$CHANNEL" in
        preview)
            failure_stage="preview_skip"
            skip_cell "preview manifest tag missing for $CHANNEL"
            ;;
        stable)
            S4="FAIL"
            failure_stage="manifest_fetch"
            fail_assertion "S4" "manifest channel tag missing for $CHANNEL"
            ;;
    esac
fi

case "$CHANNEL" in
    stable)
        if ! is_stable_tag "$manifest_tag"; then
            S4="FAIL"
            failure_stage="manifest_fetch"
            fail_assertion "S4" "manifest stable tag has invalid shape: $manifest_tag"
        fi
        ;;
    preview)
        if ! is_preview_tag "$manifest_tag"; then
            S4="FAIL"
            failure_stage="manifest_fetch"
            fail_assertion "S4" "manifest preview tag has invalid shape: $manifest_tag"
        fi
        ;;
esac

if [ "$override_used" != "true" ]; then
    expected_tag="$manifest_tag"
fi
pass_assertion S4

set +e
run_install_with_retry
install_status=$?
set +e

if [ "$install_status" -eq 0 ]; then
    pass_assertion S1
else
    S1="FAIL"
    failure_stage="install_execution"
    fail_assertion "S1" "install command exhausted after $RETRY_ATTEMPTS attempts; final exit $install_exit_code"
fi

if [ -x "$INSTALL_BIN" ]; then
    pass_assertion S2
else
    S2="FAIL"
    fail_assertion "S2" "installed server binary is missing or not executable: $INSTALL_BIN"
fi

version_output="$("$INSTALL_BIN" version 2>>"$LOG_FILE" || true)"
installed_tag="$(printf '%s\n' "$version_output" | awk '$1 == "quicktui" { print $2; exit }')"
if [ -z "$installed_tag" ]; then
    S3="FAIL"
    failure_stage="version_parsing"
    fail_assertion "S3" "cannot parse installed server version from: $version_output"
fi

case "$CHANNEL" in
    stable)
        if is_stable_tag "$installed_tag"; then
            pass_assertion S3
        else
            S3="FAIL"
            failure_stage="version_parsing"
            fail_assertion "S3" "stable installed tag has invalid shape: $installed_tag"
        fi
        ;;
    preview)
        if is_preview_tag "$installed_tag"; then
            pass_assertion S3
        else
            S3="FAIL"
            failure_stage="version_parsing"
            fail_assertion "S3" "preview installed tag has invalid shape: $installed_tag"
        fi
        ;;
esac

if [ "$installed_tag" = "$expected_tag" ]; then
    pass_assertion S5
else
    S5="FAIL"
    failure_stage="version_mismatch"
    fail_assertion "S5" "installed tag $installed_tag does not match expected tag $expected_tag"
fi

i=0
while [ "$i" -lt "$SERVICE_ATTEMPTS" ]; do
    service_active="$(systemctl --user is-active quicktui.service 2>>"$LOG_FILE" || true)"
    unit_exec_start="$(systemctl --user show quicktui.service -p ExecStart --value 2>>"$LOG_FILE" || true)"
    if [ -f "$SERVICE_UNIT" ]; then
        unit_file_exec="$(awk -F= '$1 == "ExecStart" { print substr($0, length("ExecStart") + 2); exit }' "$SERVICE_UNIT")"
        unit_exec_start="${unit_exec_start}${unit_exec_start:+ }${unit_file_exec}"
    fi
    case "$service_active:$unit_exec_start" in
        active:*"$INSTALL_BIN"*) break ;;
    esac
    sleep 1
    i=$((i + 1))
done

case "$service_active" in
    active) ;;
    *)
        S6="FAIL"
        failure_stage="service_validation"
        fail_assertion "S6" "quicktui.service is not active after $SERVICE_ATTEMPTS attempts: ${service_active:-unknown}"
        ;;
esac

case "$unit_exec_start" in
    *"$INSTALL_BIN"*) pass_assertion S6 ;;
    *)
        S6="FAIL"
        failure_stage="service_validation"
        fail_assertion "S6" "quicktui.service ExecStart does not point at $INSTALL_BIN"
        ;;
esac

addr="$(config_value QUICKTUI_ADDR)"
token="$(config_token)"
[ -n "$addr" ] || {
    S7="FAIL"
    failure_stage="service_validation"
    fail_assertion "S7" "QUICKTUI_ADDR missing from config"
}
[ -n "$token" ] || {
    S7="FAIL"
    failure_stage="service_validation"
    fail_assertion "S7" "QUICKTUI_TOKEN missing from config"
}

case "$addr" in
    0.0.0.0:*) http_addr="127.0.0.1:${addr#0.0.0.0:}" ;;
    "[::]:"*) http_addr="127.0.0.1:${addr#"[::]:"}" ;;
    *) http_addr="$addr" ;;
esac

version_json=""
i=0
while [ "$i" -lt "$VERSION_ATTEMPTS" ]; do
    version_endpoint=/v3/version
    version_json="$(curl -fsS -H "Authorization: Bearer ${token}" "http://${http_addr}${version_endpoint}" 2>>"$LOG_FILE" || true)"
    version_response_version="$(printf '%s\n' "$version_json" | jq -r '.version // empty' 2>>"$LOG_FILE" || true)"
    if [ -n "$version_response_version" ]; then
        version_response_endpoint="$version_endpoint"
    fi
    if [ -n "$version_response_version" ]; then
        break
    fi
    sleep 0.2
    i=$((i + 1))
done

if [ "$version_response_version" = "$installed_tag" ]; then
    pass_assertion S7
else
    S7="FAIL"
    if [ -z "$version_response_version" ]; then
        failure_stage="service_validation"
        fail_assertion "S7" "/v3/version did not return a version after $VERSION_ATTEMPTS attempts"
    fi
    failure_stage="version_mismatch"
    fail_assertion "S7" "${version_response_endpoint:-version API} returned ${version_response_version:-empty}, expected $installed_tag"
fi

write_result "pass" "" "all assertions passed"
exit 0
