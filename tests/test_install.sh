#!/bin/sh
set -e

# ============================================================
# Automated tests for install.sh
# Run inside Docker: docker build -f Dockerfile.test -t quicktui-test . && docker run --rm quicktui-test
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_SCRIPT="${SCRIPT_DIR}/../install.sh"
MOCK_PORT=18123
MOCK_DIR=""
MOCK_PID=""
TESTS_PASSED=0
TESTS_FAILED=0

# ============================================================
# Helpers
# ============================================================

pass() {
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf '\033[0;32m  PASS\033[0m %s\n' "$1"
}

fail() {
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '\033[0;31m  FAIL\033[0m %s: %s\n' "$1" "$2"
}

assert_file_exists() {
    if [ -f "$1" ]; then
        pass "$2"
    else
        fail "$2" "file not found: $1"
    fi
}

assert_file_not_exists() {
    if [ ! -f "$1" ]; then
        pass "$2"
    else
        fail "$2" "file should not exist: $1"
    fi
}

assert_file_contains() {
    if grep -q "$2" "$1" 2>/dev/null; then
        pass "$3"
    else
        fail "$3" "'$2' not found in $1"
    fi
}

assert_file_permission() {
    _actual="$(stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null)"
    if [ "$_actual" = "$2" ]; then
        pass "$3"
    else
        fail "$3" "expected permission $2, got $_actual for $1"
    fi
}

# ============================================================
# Mock HTTP server setup
# ============================================================

setup_mock_server() {
    MOCK_DIR="$(mktemp -d)"

    # Detect platform to create correct binary name
    _os="$(uname -s)"
    _arch="$(uname -m)"
    case "$_os" in
        Darwin) _platform="darwin" ;;
        Linux)  _platform="linux" ;;
    esac
    case "$_arch" in
        arm64|aarch64) _arch_name="arm64" ;;
        x86_64|amd64)  _arch_name="amd64" ;;
    esac
    MOCK_BINARY_NAME="quicktui-${_platform}-${_arch_name}"

    # Create fake binary
    printf '#!/bin/sh\necho "quicktui-mock v0.0.1-test"\n' > "${MOCK_DIR}/${MOCK_BINARY_NAME}"
    chmod +x "${MOCK_DIR}/${MOCK_BINARY_NAME}"

    # Create sha256 checksum file
    cd "$MOCK_DIR"
    sha256sum "${MOCK_BINARY_NAME}" > "${MOCK_BINARY_NAME}.sha256" 2>/dev/null || \
        shasum -a 256 "${MOCK_BINARY_NAME}" > "${MOCK_BINARY_NAME}.sha256"
    cd /

    # Start HTTP server
    python3 -m http.server "$MOCK_PORT" --directory "$MOCK_DIR" > /dev/null 2>&1 &
    MOCK_PID=$!
    sleep 1

    if ! kill -0 "$MOCK_PID" 2>/dev/null; then
        printf 'ERROR: Failed to start mock HTTP server\n'
        exit 1
    fi
}

teardown_mock_server() {
    [ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null || true
    [ -n "$MOCK_DIR" ] && rm -rf "$MOCK_DIR"
}

# Clean up test artifacts between test cases
reset_test_env() {
    rm -rf "${HOME}/.local/bin/quicktui"
    rm -rf "${HOME}/.config/quicktui"
    rm -rf "${HOME}/.config/systemd/user/quicktui.service"
    rm -f /usr/local/bin/quicktui
}

# ============================================================
# Test cases
# ============================================================

test_default_install() {
    printf '\n--- test_default_install ---\n'
    reset_test_env

    QUICKTUI_RELEASES="http://localhost:${MOCK_PORT}" \
        sh "$INSTALL_SCRIPT" -y --no-service

    assert_file_exists "${HOME}/.local/bin/quicktui" "binary installed to ~/.local/bin"
    assert_file_exists "${HOME}/.config/quicktui/config" "config file created"
    assert_file_contains "${HOME}/.config/quicktui/config" "QUICKTUI_TOKEN=" "config contains token"
    assert_file_permission "${HOME}/.config/quicktui" "700" "config dir permission 700"
    assert_file_permission "${HOME}/.config/quicktui/config" "600" "config file permission 600"
    assert_file_not_exists "${HOME}/.config/systemd/user/quicktui.service" "no systemd service with --no-service"
}

test_custom_token() {
    printf '\n--- test_custom_token ---\n'
    reset_test_env

    QUICKTUI_RELEASES="http://localhost:${MOCK_PORT}" \
        sh "$INSTALL_SCRIPT" -y --no-service --token "mytoken123"

    assert_file_contains "${HOME}/.config/quicktui/config" "QUICKTUI_TOKEN=mytoken123" "custom token saved correctly"
}

test_install_dir_2() {
    printf '\n--- test_install_dir_2 ---\n'
    reset_test_env

    QUICKTUI_RELEASES="http://localhost:${MOCK_PORT}" \
        sh "$INSTALL_SCRIPT" -y --no-service --install-dir 2

    assert_file_exists "/usr/local/bin/quicktui" "binary installed to /usr/local/bin"
    assert_file_not_exists "${HOME}/.local/bin/quicktui" "not installed to ~/.local/bin"
}

test_service_config() {
    printf '\n--- test_service_config ---\n'
    reset_test_env

    QUICKTUI_RELEASES="http://localhost:${MOCK_PORT}" \
        sh "$INSTALL_SCRIPT" -y --addr 127.0.0.1 --port 8080

    _service_file="${HOME}/.config/systemd/user/quicktui.service"
    # On Linux (Docker), systemd service file should be created
    _os="$(uname -s)"
    if [ "$_os" = "Linux" ]; then
        assert_file_exists "$_service_file" "systemd service file created"
        assert_file_contains "$_service_file" "QUICKTUI_ADDR=127.0.0.1:8080" "service has correct addr:port"
        assert_file_contains "$_service_file" "ExecStart=${HOME}/.local/bin/quicktui" "service has correct ExecStart"
    else
        pass "skipped systemd test on non-Linux"
    fi
}

test_help_flag() {
    printf '\n--- test_help_flag ---\n'

    _output="$(sh "$INSTALL_SCRIPT" --help 2>&1)"
    if echo "$_output" | grep -q "Non-interactive mode"; then
        pass "--help shows usage info"
    else
        fail "--help shows usage info" "help output missing expected text"
    fi
}

test_binary_executable() {
    printf '\n--- test_binary_executable ---\n'
    reset_test_env

    QUICKTUI_RELEASES="http://localhost:${MOCK_PORT}" \
        sh "$INSTALL_SCRIPT" -y --no-service

    _output="$("${HOME}/.local/bin/quicktui" 2>&1 || true)"
    if echo "$_output" | grep -q "quicktui-mock"; then
        pass "installed binary is executable"
    else
        fail "installed binary is executable" "unexpected output: $_output"
    fi
}

# ============================================================
# Main
# ============================================================

main() {
    printf '\n\033[1m=== QuickTUI install.sh Test Suite ===\033[0m\n'

    setup_mock_server
    trap teardown_mock_server EXIT INT TERM

    test_help_flag
    test_default_install
    test_custom_token
    test_install_dir_2
    test_service_config
    test_binary_executable

    printf '\n\033[1m=== Results: %d passed, %d failed ===\033[0m\n\n' "$TESTS_PASSED" "$TESTS_FAILED"

    if [ "$TESTS_FAILED" -gt 0 ]; then
        exit 1
    fi
}

main
