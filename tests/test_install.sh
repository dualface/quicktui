#!/bin/sh
set -e

# ============================================================
# Automated tests for q.sh
# Run inside Docker: docker build -f Dockerfile.test -t quicktui-test . && docker run --rm quicktui-test
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_SCRIPT="${SCRIPT_DIR}/../q.sh"
SHELL_BIN="$(command -v sh)"
ENV_BIN="$(command -v env)"
PYTHON3_BIN="$(command -v python3)"
REAL_PATH="${PATH}"
CURRENT_OS="$(uname -s)"
MOCK_PORT=""
MOCK_DIR=""
MOCK_PID=""
TEST_TMPDIRS=""
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

remember_tmpdir() {
    if [ -z "$TEST_TMPDIRS" ]; then
        TEST_TMPDIRS="$1"
    else
        TEST_TMPDIRS="${TEST_TMPDIRS}
$1"
    fi
}

make_tmpdir() {
    _dir="$(mktemp -d)"
    remember_tmpdir "$_dir"
    printf '%s\n' "$_dir"
}

cleanup_tmpdirs() {
    if [ -n "$TEST_TMPDIRS" ]; then
        printf '%s\n' "$TEST_TMPDIRS" | while IFS= read -r _dir; do
            [ -n "$_dir" ] && rm -rf "$_dir"
        done
    fi
}

assert_file_exists() {
    if [ -f "$1" ]; then
        pass "$2"
    else
        fail "$2" "file not found: $1"
    fi
}

assert_path_not_exists() {
    if [ ! -e "$1" ] && [ ! -L "$1" ]; then
        pass "$2"
    else
        fail "$2" "path should not exist: $1"
    fi
}

assert_file_contains() {
    if grep -Fq -- "$2" "$1" 2>/dev/null; then
        pass "$3"
    else
        fail "$3" "'$2' not found in $1"
    fi
}

assert_file_not_contains() {
    if grep -Fq -- "$2" "$1" 2>/dev/null; then
        fail "$3" "unexpected '$2' found in $1"
    else
        pass "$3"
    fi
}

assert_output_contains() {
    if grep -Fq -- "$2" "$1" 2>/dev/null; then
        pass "$3"
    else
        fail "$3" "'$2' not found in output"
    fi
}

assert_output_not_contains() {
    if grep -Fq -- "$2" "$1" 2>/dev/null; then
        fail "$3" "unexpected '$2' found in output"
    else
        pass "$3"
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

run_installer() {
    QUICKTUI_RELEASES="http://127.0.0.1:${MOCK_PORT}" "$SHELL_BIN" "$INSTALL_SCRIPT" "$@"
}

run_command_interactive() {
    _outfile="$1"
    _input="$2"
    shift 2

    TTY_OUTPUT_FILE="$_outfile" TTY_INPUT_TEXT="$_input" "$PYTHON3_BIN" - "$@" <<'PY'
import os
import select
import sys
import time
import pty

outfile = os.environ["TTY_OUTPUT_FILE"]
input_text = os.environ.get("TTY_INPUT_TEXT", "")
if input_text:
    input_text = input_text + "\n\n"
input_bytes = input_text.encode()
cmd = sys.argv[1:]

pid, master = pty.fork()
if pid == 0:
    os.execvpe(cmd[0], cmd, os.environ.copy())

if input_bytes:
    os.write(master, input_bytes)

chunks = []
deadline = time.time() + 40
exited = False
idle_after_exit = 0
reaped = False
status = None
while True:
    ready, _, _ = select.select([master], [], [], 0.1)
    if ready:
        try:
            data = os.read(master, 4096)
        except OSError:
            data = b""
        if data:
            chunks.append(data)
        else:
            break

    if not reaped:
        try:
            waited_pid, status = os.waitpid(pid, os.WNOHANG)
        except ChildProcessError:
            waited_pid = pid
            reaped = True
            exited = True
        else:
            if waited_pid == pid:
                reaped = True
                exited = True

    if exited and not ready:
        idle_after_exit += 1
        if idle_after_exit >= 5:
            break
    elif ready:
        idle_after_exit = 0

    if time.time() > deadline and not exited:
        os.kill(pid, 15)
        _, status = os.waitpid(pid, 0)
        reaped = True
        exited = True
        break

if not reaped:
    _, status = os.waitpid(pid, 0)
    reaped = True

rc = os.waitstatus_to_exitcode(status)
with open(outfile, "wb") as fh:
    fh.write(b"".join(chunks))

os.close(master)
sys.exit(rc)
PY
}

link_existing_commands() {
    _dir="$1"
    shift
    for _cmd in "$@"; do
        _path="$(command -v "$_cmd" 2>/dev/null || true)"
        if [ -n "$_path" ]; then
            ln -sf "$_path" "${_dir}/${_cmd}"
        fi
    done
}

write_fake_tmux() {
    _dir="$1"
    _version="$2"
    cat > "${_dir}/tmux" <<EOF
#!/bin/sh
if [ "\${1:-}" = "-V" ]; then
    printf 'tmux %s\n' "${_version}"
    exit 0
fi
printf 'fake tmux\n'
EOF
    chmod +x "${_dir}/tmux"
}

write_fake_uname() {
    _dir="$1"
    _os="$2"
    _arch="$3"
    cat > "${_dir}/uname" <<EOF
#!/bin/sh
case "\${1:-}" in
    -s) printf '%s\n' "${_os}" ;;
    -m) printf '%s\n' "${_arch}" ;;
    *) printf '%s\n' "${_os}" ;;
esac
EOF
    chmod +x "${_dir}/uname"
}

write_fake_id_zero() {
    _dir="$1"
    cat > "${_dir}/id" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "-u" ]; then
    printf '0\n'
else
    printf '0\n'
fi
EOF
    chmod +x "${_dir}/id"
}

write_fake_sudo_passthrough() {
    _dir="$1"
    cat > "${_dir}/sudo" <<'EOF'
#!/bin/sh
# Strip -n flag so passthrough works for both interactive and non-interactive
case "$1" in -n) shift ;; esac
exec "$@"
EOF
    chmod +x "${_dir}/sudo"
}

write_fake_sudo_password_required() {
    _dir="$1"
    cat > "${_dir}/sudo" <<'EOF'
#!/bin/sh
# Simulate sudo that requires a password: -n fails, without -n hangs
if [ "$1" = "-n" ]; then
    printf 'sudo: a password is required\n' >&2
    exit 1
fi
exec "$@"
EOF
    chmod +x "${_dir}/sudo"
}

write_fake_id_nonroot() {
    _dir="$1"
    cat > "${_dir}/id" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "-u" ]; then
    printf '1000\n'
else
    printf '1000\n'
fi
EOF
    chmod +x "${_dir}/id"
}

write_fake_pkg_manager_success() {
    _dir="$1"
    if [ "$CURRENT_OS" = "Darwin" ]; then
        _name="brew"
    else
        _name="apt-get"
    fi

    cat > "${_dir}/${_name}" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "${_dir}/${_name}"

    if [ "$CURRENT_OS" != "Darwin" ]; then
        write_fake_id_zero "$_dir"
        write_fake_sudo_passthrough "$_dir"
    fi
}

write_mock_checksum_good() {
    cd "$MOCK_DIR"
    sha256sum "$MOCK_BINARY_NAME" > "${MOCK_BINARY_NAME}.sha256" 2>/dev/null || \
        shasum -a 256 "$MOCK_BINARY_NAME" > "${MOCK_BINARY_NAME}.sha256"
    cd /
}

write_mock_checksum_bad() {
    printf '0000000000000000000000000000000000000000000000000000000000000000  %s\n' \
        "$MOCK_BINARY_NAME" > "${MOCK_DIR}/${MOCK_BINARY_NAME}.sha256"
}

choose_mock_port() {
    "$PYTHON3_BIN" - <<'PY'
import socket

sock = socket.socket()
sock.bind(("127.0.0.1", 0))
print(sock.getsockname()[1])
sock.close()
PY
}

# ============================================================
# Mock HTTP server setup
# ============================================================

setup_mock_server() {
    MOCK_DIR="$(make_tmpdir)"
    MOCK_PORT="$(choose_mock_port)"

    _os="$(uname -s)"
    _arch="$(uname -m)"
    case "$_os" in
        Darwin) _platform="darwin" ;;
        Linux) _platform="linux" ;;
        *)
            printf 'ERROR: Unsupported OS for tests: %s\n' "$_os"
            exit 1
            ;;
    esac
    case "$_arch" in
        arm64|aarch64) _arch_name="arm64" ;;
        x86_64|amd64) _arch_name="amd64" ;;
        *)
            printf 'ERROR: Unsupported architecture for tests: %s\n' "$_arch"
            exit 1
            ;;
    esac
    MOCK_BINARY_NAME="quicktui-server-${_platform}-${_arch_name}"

    cat > "${MOCK_DIR}/${MOCK_BINARY_NAME}" <<'EOF'
#!/bin/sh
set -e

case "${1:-}" in
    --version)
        echo "quicktui-mock v0.0.1-test"
        ;;
    --install-service)
        shift
        if [ "${QUICKTUI_MOCK_INSTALL_SERVICE_FAIL:-}" = "1" ]; then
            exit 1
        fi

        addr=""
        term=""
        lang=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --addr)
                    addr="$2"
                    shift 2
                    ;;
                --term)
                    term="$2"
                    shift 2
                    ;;
                --lang)
                    lang="$2"
                    shift 2
                    ;;
                *)
                    echo "unexpected arg: $1" >&2
                    exit 1
                    ;;
            esac
        done

        mkdir -p "$HOME/.quicktui-test"
        {
            printf 'ADDR=%s\n' "$addr"
            printf 'TERM=%s\n' "$term"
            printf 'LANG=%s\n' "$lang"
        } > "$HOME/.quicktui-test/install-service.log"

        case "$(uname -s)" in
            Darwin)
                mkdir -p "$HOME/Library/LaunchAgents"
                {
                    printf 'Label=ai.quicktui\n'
                    printf 'Addr=%s\n' "$addr"
                } > "$HOME/Library/LaunchAgents/ai.quicktui.plist"
                ;;
            Linux)
                mkdir -p "$HOME/.config/systemd/user/default.target.wants"
                {
                    printf '[Service]\n'
                    printf 'Environment=QUICKTUI_ADDR=%s\n' "$addr"
                    printf 'ExecStart=%s/.local/bin/quicktui-server\n' "$HOME"
                } > "$HOME/.config/systemd/user/quicktui.service"
                ln -sf ../quicktui.service "$HOME/.config/systemd/user/default.target.wants/quicktui.service"
                ;;
        esac

        if [ "${QUICKTUI_MOCK_SKIP_SERVICE_START:-}" != "1" ]; then
            python3 - "$addr" >"$HOME/.quicktui-test/mock-service.log" 2>&1 <<'PY' &
import http.server
import socket
import sys

listen = sys.argv[1]
if listen.startswith("["):
    host, rest = listen[1:].split("]", 1)
    port = int(rest[1:])
else:
    host, port_text = listen.rsplit(":", 1)
    port = int(port_text)

if host in ("", "0.0.0.0"):
    host = "127.0.0.1"
elif host == "::":
    host = "::1"

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"quicktui mock service")

    def log_message(self, fmt, *args):
        return

class Server(http.server.ThreadingHTTPServer):
    allow_reuse_address = True

Server.address_family = socket.AF_INET6 if ":" in host else socket.AF_INET
httpd = Server((host, port), Handler)
httpd.serve_forever()
PY
            printf '%s\n' "$!" > "$HOME/.quicktui-test/mock-service.pid"
            sleep 1
        fi
        ;;
    --uninstall-service)
        mkdir -p "$HOME/.quicktui-test"
        printf 'uninstall-service called\n' >> "$HOME/.quicktui-test/uninstall-service.log"
        if [ -f "$HOME/.quicktui-test/mock-service.pid" ]; then
            _mock_pid="$(cat "$HOME/.quicktui-test/mock-service.pid" 2>/dev/null || true)"
            [ -n "$_mock_pid" ] && kill "$_mock_pid" 2>/dev/null || true
            rm -f "$HOME/.quicktui-test/mock-service.pid"
        fi
        rm -f "$HOME/Library/LaunchAgents/ai.quicktui.plist"
        rm -f "$HOME/.config/systemd/user/quicktui.service"
        rm -f "$HOME/.config/systemd/user/default.target.wants/quicktui.service"
        ;;
    *)
        echo "quicktui-mock v0.0.1-test"
        ;;
esac
EOF
    chmod +x "${MOCK_DIR}/${MOCK_BINARY_NAME}"
    write_mock_checksum_good

    # Create mock tmux tarball for install_tmux_from_builds tests
    _tmux_os="$_platform"
    [ "$_tmux_os" = "darwin" ] && _tmux_os="macos"
    _tmux_arch_name="$_arch_name"
    [ "$_tmux_arch_name" = "amd64" ] && _tmux_arch_name="x86_64"
    MOCK_TMUX_TARBALL="tmux-0.0.1-test-${_tmux_os}-${_tmux_arch_name}.tar.gz"

    _tmux_stage="$(make_tmpdir)"
    cat > "${_tmux_stage}/tmux" <<'TMUXEOF'
#!/bin/sh
case "${1:-}" in
    -V) printf 'tmux 3.6a\n' ;;
    *)  printf 'mock-tmux\n' ;;
esac
TMUXEOF
    chmod +x "${_tmux_stage}/tmux"
    tar -czf "${MOCK_DIR}/${MOCK_TMUX_TARBALL}" -C "$_tmux_stage" tmux

    "$PYTHON3_BIN" -m http.server "$MOCK_PORT" --bind 127.0.0.1 --directory "$MOCK_DIR" > /dev/null 2>&1 &
    MOCK_PID=$!
    sleep 1

    if ! kill -0 "$MOCK_PID" 2>/dev/null; then
        printf 'ERROR: Failed to start mock HTTP server\n'
        exit 1
    fi
}

teardown_mock_server() {
    [ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null || true
}

cleanup_all() {
    teardown_mock_server
    cleanup_tmpdirs
}

kill_mock_service() {
    if [ -f "${HOME}/.quicktui-test/mock-service.pid" ]; then
        _mock_pid="$(cat "${HOME}/.quicktui-test/mock-service.pid" 2>/dev/null || true)"
        [ -n "$_mock_pid" ] && kill "$_mock_pid" 2>/dev/null || true
        rm -f "${HOME}/.quicktui-test/mock-service.pid"
    fi
}

cleanup_test_tmux_install() {
    _tmux_symlink="${HOME}/.local/bin/tmux"
    _tmux_dir="${HOME}/.local/tmux"

    if [ -L "$_tmux_symlink" ]; then
        _tmux_target="$(readlink "$_tmux_symlink" 2>/dev/null || true)"
        case "$_tmux_target" in
            "${HOME}/.local/tmux/tmux"|../tmux/tmux)
                rm -f "$_tmux_symlink"
                ;;
        esac
    fi

    if [ -f "${_tmux_dir}/tmux" ] && grep -Fq "mock-tmux" "${_tmux_dir}/tmux" 2>/dev/null; then
        rm -rf "$_tmux_dir"
    fi
}

reset_test_env() {
    kill_mock_service
    cleanup_test_tmux_install
    rm -rf "${HOME}/.local/bin/quicktui-server"
    rm -rf "${HOME}/.config/quicktui"
    rm -rf "${HOME}/.config/systemd/user"
    rm -rf "${HOME}/.quicktui-test"
    rm -rf "${HOME}/Library/LaunchAgents/ai.quicktui.plist"
    rm -rf "${HOME}/Library/Logs/QuickTUI"
}

# ============================================================
# Test cases
# ============================================================

test_help_flag() {
    printf '\n--- test_help_flag ---\n'

    _tmp="$(make_tmpdir)"
    _out="${_tmp}/out"
    if "$SHELL_BIN" "$INSTALL_SCRIPT" --help >"${_out}" 2>&1; then
        assert_output_contains "${_out}" "Non-interactive mode" "--help shows usage info"
        assert_output_contains "${_out}" "--check" "--help documents --check flag"
    else
        fail "--help shows usage info" "help command failed"
    fi
}

test_unknown_option() {
    printf '\n--- test_unknown_option ---\n'

    _tmp="$(make_tmpdir)"
    _out="${_tmp}/out"
    if "$SHELL_BIN" "$INSTALL_SCRIPT" --bogus >"${_out}" 2>&1; then
        fail "unknown option is rejected" "installer unexpectedly succeeded"
    else
        assert_output_contains "${_out}" "Unknown option: --bogus" "unknown option is rejected"
    fi
}

test_missing_option_value() {
    printf '\n--- test_missing_option_value ---\n'

    _tmp="$(make_tmpdir)"
    _out="${_tmp}/out"
    if "$SHELL_BIN" "$INSTALL_SCRIPT" --addr >"${_out}" 2>&1; then
        fail "missing option value is reported clearly" "installer unexpectedly succeeded"
    else
        assert_output_contains "${_out}" "Missing value for --addr" "missing option value is reported clearly"
    fi
}

test_unsupported_platform() {
    printf '\n--- test_unsupported_platform ---\n'

    _bin_dir="$(make_tmpdir)"
    write_fake_uname "$_bin_dir" "Solaris" "x86_64"
    _out="${_bin_dir}/out"

    if PATH="${_bin_dir}" "$SHELL_BIN" "$INSTALL_SCRIPT" -y >"${_out}" 2>&1; then
        fail "unsupported platform is rejected" "installer unexpectedly succeeded"
    else
        assert_output_contains "${_out}" "Unsupported operating system: Solaris" "unsupported platform is rejected"
    fi
}

test_unsupported_architecture() {
    printf '\n--- test_unsupported_architecture ---\n'

    _bin_dir="$(make_tmpdir)"
    write_fake_uname "$_bin_dir" "Darwin" "mips64"
    _out="${_bin_dir}/out"

    if PATH="${_bin_dir}" "$SHELL_BIN" "$INSTALL_SCRIPT" -y >"${_out}" 2>&1; then
        fail "unsupported architecture is rejected" "installer unexpectedly succeeded"
    else
        assert_output_contains "${_out}" "Unsupported architecture: mips64" "unsupported architecture is rejected"
    fi
}

test_tmux_missing_noninteractive() {
    printf '\n--- test_tmux_missing_noninteractive ---\n'

    # Skip when tmux exists at well-known absolute paths — the installer
    # would find it even with a restricted PATH.
    if [ -x /usr/local/bin/tmux ] || [ -x /usr/bin/tmux ]; then
        pass "missing tmux is reported (skipped: tmux at well-known path)"
        pass "non-interactive does not show manual-install hint (skipped: tmux at well-known path)"
        return
    fi

    _bin_dir="$(make_tmpdir)"
    link_existing_commands "$_bin_dir" uname
    _out="${_bin_dir}/out"

    # Non-interactive mode now auto-installs tmux (default=y).
    # With restricted PATH (no curl/wget/brew), the install attempt fails.
    if PATH="${_bin_dir}" QUICKTUI_RELEASES="http://127.0.0.1:${MOCK_PORT}" \
        "$SHELL_BIN" "$INSTALL_SCRIPT" -y >"${_out}" 2>&1; then
        fail "missing tmux triggers auto-install attempt" "installer unexpectedly succeeded"
    else
        assert_output_contains "${_out}" "tmux is not installed." "missing tmux is reported"
        assert_output_not_contains "${_out}" "Please install tmux 3.2 or later and run this installer again." "non-interactive does not show manual-install hint"
    fi
}

test_tmux_install_reports_missing_after_package_manager_returns_success() {
    printf '\n--- test_tmux_install_reports_missing_after_package_manager_returns_success ---\n'

    # Skip when tmux exists at well-known absolute paths (e.g. Docker image
    # with tmux pre-installed at /usr/bin/tmux) — the installer would
    # legitimately find and use it even with a restricted PATH.
    if [ -x /usr/local/bin/tmux ] || [ -x /usr/bin/tmux ]; then
        pass "tmux install verifies command becomes available (skipped: tmux at well-known path)"
        return
    fi

    _bin_dir="$(make_tmpdir)"
    link_existing_commands "$_bin_dir" uname
    write_fake_pkg_manager_success "$_bin_dir"
    _out="${_bin_dir}/out"

    _input="$(printf 'y\n')"
    if run_command_interactive "${_out}" "${_input}" \
        "$ENV_BIN" "PATH=${_bin_dir}" "$SHELL_BIN" "$INSTALL_SCRIPT"; then
        fail "tmux install verifies command becomes available" "installer unexpectedly succeeded"
    else
        assert_output_contains "${_out}" "tmux installation completed, but tmux is still not found." "tmux install verifies command becomes available"
    fi
}

test_tmux_old_version_noninteractive() {
    printf '\n--- test_tmux_old_version_noninteractive ---\n'

    _bin_dir="$(make_tmpdir)"
    link_existing_commands "$_bin_dir" uname sed cut
    write_fake_tmux "$_bin_dir" "3.1"
    _out="${_bin_dir}/out"

    if PATH="${_bin_dir}" QUICKTUI_RELEASES="http://127.0.0.1:${MOCK_PORT}" \
        "$SHELL_BIN" "$INSTALL_SCRIPT" -y >"${_out}" 2>&1; then
        fail "old tmux stops non-interactive install" "installer unexpectedly succeeded"
    else
        assert_output_contains "${_out}" "QuickTUI requires tmux 3.2 or later." "old tmux warning is shown"
    fi
}

test_tmux_old_version_interactive_continue() {
    printf '\n--- test_tmux_old_version_interactive_continue ---\n'
    reset_test_env

    _bin_dir="$(make_tmpdir)"
    write_fake_tmux "$_bin_dir" "3.1"
    _out="${_bin_dir}/out"
    _input="$(printf 'y\n\n\n\n\n\nn\n')"

    if run_command_interactive "${_out}" "${_input}" \
        "$ENV_BIN" \
        "PATH=${_bin_dir}:${REAL_PATH}" \
        "QUICKTUI_RELEASES=http://127.0.0.1:${MOCK_PORT}" \
        "$SHELL_BIN" "$INSTALL_SCRIPT"; then
        assert_output_contains "${_out}" "QuickTUI requires tmux 3.2 or later." "interactive old tmux warning is shown"
        assert_file_exists "${HOME}/.config/quicktui/config" "interactive continue with old tmux still installs"
    else
        fail "interactive continue with old tmux still installs" "installer unexpectedly failed"
    fi
}

test_no_download_tool() {
    printf '\n--- test_no_download_tool ---\n'

    _bin_dir="$(make_tmpdir)"
    link_existing_commands "$_bin_dir" uname sed cut mktemp rm
    write_fake_tmux "$_bin_dir" "3.6"
    _out="${_bin_dir}/out"

    if PATH="${_bin_dir}" "$SHELL_BIN" "$INSTALL_SCRIPT" -y --no-service >"${_out}" 2>&1; then
        fail "missing curl and wget is rejected" "installer unexpectedly succeeded"
    else
        assert_output_contains "${_out}" "Neither curl nor wget found" "missing curl and wget is rejected"
    fi
}

test_checksum_failure() {
    printf '\n--- test_checksum_failure ---\n'
    reset_test_env

    write_mock_checksum_bad
    _tmp="$(make_tmpdir)"
    _out="${_tmp}/out"

    if run_installer -y --no-service >"${_out}" 2>&1; then
        fail "checksum mismatch aborts install" "installer unexpectedly succeeded"
    else
        assert_output_contains "${_out}" "Checksum verification failed" "checksum mismatch aborts install"
    fi

    write_mock_checksum_good
}

test_default_install() {
    printf '\n--- test_default_install ---\n'
    reset_test_env

    run_installer -y --no-service

    assert_file_exists "${HOME}/.local/bin/quicktui-server" "binary installed to ~/.local/bin"
    assert_file_exists "${HOME}/.config/quicktui/config" "config file created"
    assert_file_contains "${HOME}/.config/quicktui/config" "QUICKTUI_TOKEN=" "config contains token"
    assert_file_contains "${HOME}/.config/quicktui/config" "QUICKTUI_ADDR=0.0.0.0:8022" "default listen address saved to config"
    assert_file_not_contains "${HOME}/.config/quicktui/config" "QUICKTUI_TMUX_BIN=" "system tmux install does not force QUICKTUI_TMUX_BIN"
    assert_file_permission "${HOME}/.config/quicktui" "700" "config dir permission 700"
    assert_file_permission "${HOME}/.config/quicktui/config" "600" "config file permission 600"
    assert_path_not_exists "${HOME}/.config/systemd/user/quicktui.service" "no systemd service with --no-service"
    assert_path_not_exists "${HOME}/Library/LaunchAgents/ai.quicktui.plist" "no launchd service with --no-service"
}

test_no_service_message() {
    printf '\n--- test_no_service_message ---\n'
    reset_test_env

    _tmp="$(make_tmpdir)"
    _out="${_tmp}/out"
    if run_installer -y --no-service --token message-test >"${_out}" 2>&1; then
        assert_output_contains "${_out}" "To start QuickTUI, run:" "--no-service keeps the success message in the manual-start path"
        assert_output_not_contains "${_out}" "Service registration failed" "--no-service does not print service failure"
    else
        fail "--no-service keeps the success message in the manual-start path" "installer unexpectedly failed"
    fi
}

test_custom_token() {
    printf '\n--- test_custom_token ---\n'
    reset_test_env

    run_installer -y --no-service --token "mytoken123"

    assert_file_contains "${HOME}/.config/quicktui/config" "QUICKTUI_TOKEN=mytoken123" "custom token saved correctly"
}

test_custom_addr_no_service() {
    printf '\n--- test_custom_addr_no_service ---\n'
    reset_test_env

    run_installer -y --no-service --addr 127.0.0.1 --port 9000

    assert_file_contains "${HOME}/.config/quicktui/config" "QUICKTUI_ADDR=127.0.0.1:9000" "custom listen address saved without service registration"
}

test_ipv6_addr_no_service() {
    printf '\n--- test_ipv6_addr_no_service ---\n'
    reset_test_env

    run_installer -y --no-service --addr "[::1]" --port 9000

    assert_file_contains "${HOME}/.config/quicktui/config" "QUICKTUI_ADDR=[::1]:9000" "IPv6 listen address is accepted"
}

test_invalid_noninteractive_addr() {
    printf '\n--- test_invalid_noninteractive_addr ---\n'
    reset_test_env

    _tmp="$(make_tmpdir)"
    _out="${_tmp}/out"
    if run_installer -y --no-service --addr "bad addr" >"${_out}" 2>&1; then
        fail "invalid listen address is rejected" "installer unexpectedly succeeded"
    else
        assert_output_contains "${_out}" "Invalid listen address: 'bad addr'" "invalid listen address is rejected"
    fi
}

test_invalid_noninteractive_port() {
    printf '\n--- test_invalid_noninteractive_port ---\n'
    reset_test_env

    _tmp="$(make_tmpdir)"
    _out="${_tmp}/out"
    if run_installer -y --no-service --port 70000 >"${_out}" 2>&1; then
        fail "invalid listen port is rejected" "installer unexpectedly succeeded"
    else
        assert_output_contains "${_out}" "Invalid port: '70000'" "invalid listen port is rejected"
    fi
}

test_service_config() {
    printf '\n--- test_service_config ---\n'
    reset_test_env

    run_installer -y --token test-token --addr 127.0.0.1 --port 8080 --term screen --lang C.UTF-8

    assert_file_contains "${HOME}/.config/quicktui/config" "QUICKTUI_ADDR=127.0.0.1:8080" "custom listen address saved to config"
    assert_file_exists "${HOME}/.quicktui-test/install-service.log" "install-service invocation recorded"
    assert_file_contains "${HOME}/.quicktui-test/install-service.log" "ADDR=127.0.0.1:8080" "service installer received addr:port"
    assert_file_contains "${HOME}/.quicktui-test/install-service.log" "TERM=screen" "service installer received TERM"
    assert_file_contains "${HOME}/.quicktui-test/install-service.log" "LANG=C.UTF-8" "service installer received LANG"

    if [ "$CURRENT_OS" = "Linux" ]; then
        assert_file_exists "${HOME}/.config/systemd/user/quicktui.service" "systemd service file created"
        assert_file_contains "${HOME}/.config/systemd/user/quicktui.service" "Environment=QUICKTUI_ADDR=127.0.0.1:8080" "service file stores custom addr:port"
        assert_file_contains "${HOME}/.config/systemd/user/quicktui.service" "ExecStart=${HOME}/.local/bin/quicktui-server" "service file uses quicktui-server"
    else
        assert_file_exists "${HOME}/Library/LaunchAgents/ai.quicktui.plist" "launchd plist created"
        assert_file_contains "${HOME}/Library/LaunchAgents/ai.quicktui.plist" "Addr=127.0.0.1:8080" "launchd plist stores custom addr:port"
    fi
}

test_service_registration_failure() {
    printf '\n--- test_service_registration_failure ---\n'
    reset_test_env

    _tmp="$(make_tmpdir)"
    _out="${_tmp}/out"
    if QUICKTUI_MOCK_INSTALL_SERVICE_FAIL=1 QUICKTUI_RELEASES="http://127.0.0.1:${MOCK_PORT}" \
        "$SHELL_BIN" "$INSTALL_SCRIPT" -y --token fail-token --addr 127.0.0.1 --port 8081 >"${_out}" 2>&1; then
        assert_output_contains "${_out}" "Service registration failed. Start manually:" "service failure path is shown"
        assert_output_contains "${_out}" "--install-service --addr 127.0.0.1:8081" "service retry command is printed"
        assert_path_not_exists "${HOME}/.quicktui-test/install-service.log" "failed service registration does not create success artifact"
    else
        fail "service failure path is shown" "installer unexpectedly failed"
    fi
}

test_service_startup_failure_after_registration() {
    printf '\n--- test_service_startup_failure_after_registration ---\n'
    reset_test_env

    _tmp="$(make_tmpdir)"
    _out="${_tmp}/out"
    if QUICKTUI_MOCK_SKIP_SERVICE_START=1 QUICKTUI_RELEASES="http://127.0.0.1:${MOCK_PORT}" \
        "$SHELL_BIN" "$INSTALL_SCRIPT" -y --token fail-token --addr 127.0.0.1 --port 8082 >"${_out}" 2>&1; then
        assert_output_contains "${_out}" "Service was registered but did not start successfully. Start manually:" "startup-check failure path is shown"
        assert_output_contains "${_out}" "--install-service --addr 127.0.0.1:8082" "startup-check failure prints retry command"
        assert_file_exists "${HOME}/.quicktui-test/install-service.log" "startup-check failure happens after registration"
    else
        fail "startup-check failure path is shown" "installer unexpectedly failed"
    fi
}

test_interactive_invalid_token_choice() {
    printf '\n--- test_interactive_invalid_token_choice ---\n'
    reset_test_env

    _tmp="$(make_tmpdir)"
    _out="${_tmp}/out"
    _input="$(printf '\n\n3\n')"

    if run_command_interactive "${_out}" "${_input}" \
        "$ENV_BIN" "QUICKTUI_RELEASES=http://127.0.0.1:${MOCK_PORT}" \
        "$SHELL_BIN" "$INSTALL_SCRIPT"; then
        fail "interactive invalid token choice is rejected" "installer unexpectedly succeeded"
    else
        assert_output_contains "${_out}" "Invalid choice: 3" "interactive invalid token choice is rejected"
    fi
}

test_interactive_empty_custom_token() {
    printf '\n--- test_interactive_empty_custom_token ---\n'
    reset_test_env

    _tmp="$(make_tmpdir)"
    _out="${_tmp}/out"
    _input="$(printf '\n\n2\n\n')"

    if run_command_interactive "${_out}" "${_input}" \
        "$ENV_BIN" "QUICKTUI_RELEASES=http://127.0.0.1:${MOCK_PORT}" \
        "$SHELL_BIN" "$INSTALL_SCRIPT"; then
        fail "interactive empty custom token is rejected" "installer unexpectedly succeeded"
    else
        assert_output_contains "${_out}" "Invalid token: only printable non-whitespace characters are allowed." "interactive empty custom token is rejected"
    fi
}

test_interactive_custom_token_and_decline_service() {
    printf '\n--- test_interactive_custom_token_and_decline_service ---\n'
    reset_test_env

    _tmp="$(make_tmpdir)"
    _out="${_tmp}/out"
    _service_port="$(choose_mock_port)"
    _input="$(printf '\n\n2\ncustom-interactive-token\nn\n')"

    if run_command_interactive "${_out}" "${_input}" \
        "$ENV_BIN" "QUICKTUI_RELEASES=http://127.0.0.1:${MOCK_PORT}" \
        "$SHELL_BIN" "$INSTALL_SCRIPT" --addr 127.0.0.1 --port "${_service_port}"; then
        assert_file_contains "${HOME}/.config/quicktui/config" "QUICKTUI_TOKEN=custom-interactive-token" "interactive custom token is saved"
        assert_path_not_exists "${HOME}/Library/LaunchAgents/ai.quicktui.plist" "interactive decline leaves no launchd service"
        assert_path_not_exists "${HOME}/.config/systemd/user/quicktui.service" "interactive decline leaves no systemd service"
    else
        fail "interactive custom token is saved" "installer unexpectedly failed"
    fi
}

test_interactive_service_prompt_defaults_yes() {
    printf '\n--- test_interactive_service_prompt_defaults_yes ---\n'
    reset_test_env

    _tmp="$(make_tmpdir)"
    _out="${_tmp}/out"
    _service_port="$(choose_mock_port)"
    _input='



y
'

    if run_command_interactive "${_out}" "${_input}" \
        "$ENV_BIN" "QUICKTUI_RELEASES=http://127.0.0.1:${MOCK_PORT}" \
        "$SHELL_BIN" "$INSTALL_SCRIPT" --addr 127.0.0.1 --port "${_service_port}"; then
        if [ "$CURRENT_OS" = "Linux" ]; then
            assert_file_exists "${HOME}/.config/systemd/user/quicktui.service" "blank service prompt defaults to yes on Linux"
        else
            assert_file_exists "${HOME}/Library/LaunchAgents/ai.quicktui.plist" "blank service prompt defaults to yes on macOS"
        fi
    else
        fail "blank service prompt defaults to yes" "installer unexpectedly failed"
    fi
}

test_interactive_provided_addr_port_not_prompted() {
    printf '\n--- test_interactive_provided_addr_port_not_prompted ---\n'
    reset_test_env

    _tmp="$(make_tmpdir)"
    _out="${_tmp}/out"
    _input="$(printf '\n\n\nn\n')"

    if run_command_interactive "${_out}" "${_input}" \
        "$ENV_BIN" "QUICKTUI_RELEASES=http://127.0.0.1:${MOCK_PORT}" \
        "$SHELL_BIN" "$INSTALL_SCRIPT" --addr 127.0.0.1 --port 9001; then
        assert_output_not_contains "${_out}" "Listen address [default:" "interactive CLI addr skips listen-address prompt"
        assert_output_not_contains "${_out}" "Port [default:" "interactive CLI port skips port prompt"
        assert_file_contains "${HOME}/.config/quicktui/config" "QUICKTUI_ADDR=127.0.0.1:9001" "interactive CLI addr and port are saved"
    else
        fail "interactive CLI addr and port are saved" "installer unexpectedly failed"
    fi
}

test_interactive_invalid_addr_and_port_reprompt() {
    printf '\n--- test_interactive_invalid_addr_and_port_reprompt ---\n'
    reset_test_env

    _tmp="$(make_tmpdir)"
    _out="${_tmp}/out"
    _input="$(printf '\n\n\nbad addr\n127.0.0.1\n99999\n9000\nn\n')"

    if run_command_interactive "${_out}" "${_input}" \
        "$ENV_BIN" "QUICKTUI_RELEASES=http://127.0.0.1:${MOCK_PORT}" \
        "$SHELL_BIN" "$INSTALL_SCRIPT"; then
        assert_output_contains "${_out}" "Invalid listen address: 'bad addr'" "interactive invalid address is re-prompted"
        assert_output_contains "${_out}" "Invalid port: '99999'" "interactive invalid port is re-prompted"
        assert_file_contains "${HOME}/.config/quicktui/config" "QUICKTUI_ADDR=127.0.0.1:9000" "interactive re-prompt saves the corrected addr:port"
    else
        fail "interactive re-prompt saves the corrected addr:port" "installer unexpectedly failed"
    fi
}

test_uninstall_nothing_installed() {
    printf '\n--- test_uninstall_nothing_installed ---\n'
    reset_test_env

    _tmp="$(make_tmpdir)"
    _out="${_tmp}/out"
    if "$SHELL_BIN" "$INSTALL_SCRIPT" --uninstall >"${_out}" 2>&1; then
        assert_output_contains "${_out}" "Nothing to remove. QuickTUI does not appear to be installed." "empty uninstall is a no-op"
    else
        fail "empty uninstall is a no-op" "uninstall unexpectedly failed"
    fi
}

test_uninstall_removes_leftovers_without_binary() {
    printf '\n--- test_uninstall_removes_leftovers_without_binary ---\n'
    reset_test_env

    mkdir -p "${HOME}/.config/quicktui"
    printf 'QUICKTUI_TOKEN=stale\nQUICKTUI_ADDR=127.0.0.1:9999\n' > "${HOME}/.config/quicktui/config"
    mkdir -p "${HOME}/Library/Logs/QuickTUI"
    printf 'stale log\n' > "${HOME}/Library/Logs/QuickTUI/stderr.log"

    if [ "$CURRENT_OS" = "Linux" ]; then
        mkdir -p "${HOME}/.config/systemd/user/default.target.wants"
        printf '[Service]\nEnvironment=QUICKTUI_ADDR=127.0.0.1:9999\n' > "${HOME}/.config/systemd/user/quicktui.service"
        ln -sf ../quicktui.service "${HOME}/.config/systemd/user/default.target.wants/quicktui.service"
    else
        mkdir -p "${HOME}/Library/LaunchAgents"
        printf 'Label=ai.quicktui\n' > "${HOME}/Library/LaunchAgents/ai.quicktui.plist"
    fi

    "$SHELL_BIN" "$INSTALL_SCRIPT" --uninstall

    assert_path_not_exists "${HOME}/.config/quicktui" "config directory removed during uninstall"
    assert_path_not_exists "${HOME}/Library/Logs/QuickTUI" "log directory removed during uninstall"
    assert_path_not_exists "${HOME}/.config/systemd/user/quicktui.service" "systemd service removed during uninstall"
    assert_path_not_exists "${HOME}/.config/systemd/user/default.target.wants/quicktui.service" "systemd service symlink removed during uninstall"
    assert_path_not_exists "${HOME}/Library/LaunchAgents/ai.quicktui.plist" "launchd plist removed during uninstall"
}

test_binary_executable() {
    printf '\n--- test_binary_executable ---\n'
    reset_test_env

    run_installer -y --no-service

    _output="$("${HOME}/.local/bin/quicktui-server" 2>&1 || true)"
    if echo "$_output" | grep -Fq "quicktui-mock"; then
        pass "installed binary is executable"
    else
        fail "installed binary is executable" "unexpected output: $_output"
    fi
}

test_upgrade_preserves_token() {
    printf '\n--- test_upgrade_preserves_token ---\n'
    reset_test_env

    # First install
    run_installer -y --no-service --token "original-token-abc"
    assert_file_contains "${HOME}/.config/quicktui/config" "QUICKTUI_TOKEN=original-token-abc" "first install sets token"

    # Upgrade (re-run without --token)
    run_installer -y --no-service
    assert_file_contains "${HOME}/.config/quicktui/config" "QUICKTUI_TOKEN=original-token-abc" "upgrade preserves existing token"
}

test_upgrade_preserves_config() {
    printf '\n--- test_upgrade_preserves_config ---\n'
    reset_test_env

    # First install with custom config
    run_installer -y --no-service --token "keep-me" --addr 127.0.0.1 --port 9000 --term screen --lang C.UTF-8
    assert_file_contains "${HOME}/.config/quicktui/config" "QUICKTUI_ADDR=127.0.0.1:9000" "first install sets addr"
    assert_file_contains "${HOME}/.config/quicktui/config" "QUICKTUI_TERM=screen" "first install sets term"
    assert_file_contains "${HOME}/.config/quicktui/config" "QUICKTUI_LANG=C.UTF-8" "first install sets lang"

    # Upgrade without any overrides
    run_installer -y --no-service
    assert_file_contains "${HOME}/.config/quicktui/config" "QUICKTUI_TOKEN=keep-me" "upgrade preserves token"
    assert_file_contains "${HOME}/.config/quicktui/config" "QUICKTUI_ADDR=127.0.0.1:9000" "upgrade preserves addr"
    assert_file_contains "${HOME}/.config/quicktui/config" "QUICKTUI_TERM=screen" "upgrade preserves term"
    assert_file_contains "${HOME}/.config/quicktui/config" "QUICKTUI_LANG=C.UTF-8" "upgrade preserves lang"
}

test_upgrade_with_new_token() {
    printf '\n--- test_upgrade_with_new_token ---\n'
    reset_test_env

    # First install
    run_installer -y --no-service --token "old-token"

    # Upgrade with explicit new token
    run_installer -y --no-service --token "new-token"
    assert_file_contains "${HOME}/.config/quicktui/config" "QUICKTUI_TOKEN=new-token" "upgrade --token overrides existing token"
}

test_upgrade_replaces_binary() {
    printf '\n--- test_upgrade_replaces_binary ---\n'
    reset_test_env

    # First install
    run_installer -y --no-service

    # Record old binary checksum
    _old_sum="$(sha256sum "${HOME}/.local/bin/quicktui-server" 2>/dev/null | cut -d' ' -f1 || \
                shasum -a 256 "${HOME}/.local/bin/quicktui-server" | cut -d' ' -f1)"

    # Tamper with the mock to produce a different binary for upgrade
    printf '\n# upgraded' >> "${MOCK_DIR}/${MOCK_BINARY_NAME}"
    write_mock_checksum_good

    # Upgrade
    run_installer -y --no-service

    _new_sum="$(sha256sum "${HOME}/.local/bin/quicktui-server" 2>/dev/null | cut -d' ' -f1 || \
                shasum -a 256 "${HOME}/.local/bin/quicktui-server" | cut -d' ' -f1)"

    if [ "$_old_sum" != "$_new_sum" ]; then
        pass "upgrade replaces binary with new version"
    else
        fail "upgrade replaces binary with new version" "checksum unchanged after upgrade"
    fi

    # Restore original mock
    sed -i.bak '$ d' "${MOCK_DIR}/${MOCK_BINARY_NAME}" 2>/dev/null || \
        sed -i '' '$ d' "${MOCK_DIR}/${MOCK_BINARY_NAME}"
    rm -f "${MOCK_DIR}/${MOCK_BINARY_NAME}.bak"
    write_mock_checksum_good
}

test_upgrade_stops_service_before_replace() {
    printf '\n--- test_upgrade_stops_service_before_replace ---\n'
    reset_test_env

    # First install with service
    run_installer -y --token "svc-token" --addr 127.0.0.1 --port 8080

    # Upgrade
    run_installer -y

    assert_file_exists "${HOME}/.quicktui-test/uninstall-service.log" "upgrade calls --uninstall-service to stop old service"
}

test_upgrade_shows_upgrade_message() {
    printf '\n--- test_upgrade_shows_upgrade_message ---\n'
    reset_test_env

    # First install
    run_installer -y --no-service

    # Upgrade
    _tmp="$(make_tmpdir)"
    _out="${_tmp}/out"
    run_installer -y --no-service >"${_out}" 2>&1
    assert_output_contains "${_out}" "Upgrader" "upgrade shows Upgrader title"
    assert_output_contains "${_out}" "upgraded successfully" "upgrade shows upgraded message"
}

test_upgrade_ipv6_preserves_addr() {
    printf '\n--- test_upgrade_ipv6_preserves_addr ---\n'
    reset_test_env

    # First install with IPv6
    run_installer -y --no-service --token "ipv6-tok" --addr "[::1]" --port 9000

    # Upgrade without overrides
    run_installer -y --no-service
    assert_file_contains "${HOME}/.config/quicktui/config" "QUICKTUI_TOKEN=ipv6-tok" "upgrade preserves token with IPv6 config"
    assert_file_contains "${HOME}/.config/quicktui/config" "QUICKTUI_ADDR=[::1]:9000" "upgrade preserves IPv6 address"
}

test_sudo_n_fallback_to_tmux_builds() {
    printf '\n--- test_sudo_n_fallback_to_tmux_builds ---\n'
    reset_test_env

    # Linux-only: simulate non-root user whose sudo requires a password.
    # In -y mode, run_privileged uses sudo -n which should fail immediately,
    # causing install_tmux to fall back to install_tmux_from_builds.
    if [ "$CURRENT_OS" = "Darwin" ]; then
        pass "sudo -n fallback to tmux-builds (skipped: macOS uses brew, not sudo)"
        return
    fi

    _bin_dir="$(make_tmpdir)"
    link_existing_commands "$_bin_dir" sh env uname curl wget sed cut mktemp rm tar gzip chmod ln mkdir mv du printf od awk shasum sha256sum head cat kill sleep stat grep tr openssl
    write_fake_id_nonroot "$_bin_dir"
    write_fake_sudo_password_required "$_bin_dir"

    # Provide apt-get that would succeed if sudo worked
    cat > "${_bin_dir}/apt-get" <<'APTEOF'
#!/bin/sh
exit 0
APTEOF
    chmod +x "${_bin_dir}/apt-get"

    # Patch out well-known paths so we exercise the full install chain
    _patched_script="${_bin_dir}/q-patched.sh"
    sed 's|/usr/local/bin/tmux /usr/bin/tmux|/nonexistent/tmux|' "$INSTALL_SCRIPT" > "$_patched_script"
    chmod +x "$_patched_script"

    _out="${_bin_dir}/out"
    _err="${_bin_dir}/err"
    if PATH="${_bin_dir}" \
        HOME="${HOME}" \
        QUICKTUI_RELEASES="http://127.0.0.1:${MOCK_PORT}" \
        TMUX_BUILDS_VERSION=0.0.1-test \
        TMUX_BUILDS_RELEASES="http://127.0.0.1:${MOCK_PORT}" \
        "$SHELL_BIN" "$_patched_script" -y --no-service >"${_out}" 2>"${_err}"; then
        assert_file_exists "${HOME}/.local/tmux/tmux" "sudo -n fallback installs tmux from builds"
        assert_file_contains "${HOME}/.config/quicktui/config" "QUICKTUI_TMUX_BIN=${HOME}/.local/tmux/tmux" \
            "sudo -n fallback writes QUICKTUI_TMUX_BIN"
    else
        printf '    DEBUG stdout: '; head -20 "${_out}" 2>/dev/null; printf '\n'
        printf '    DEBUG stderr: '; head -20 "${_err}" 2>/dev/null; printf '\n'
        fail "sudo -n fallback installs tmux from builds" "installer failed"
    fi
}

test_tmux_found_at_well_known_path_sets_config() {
    printf '\n--- test_tmux_found_at_well_known_path_sets_config ---\n'
    reset_test_env

    # Place a fake tmux at a well-known path outside $PATH so that
    # _find_tmux discovers it via the absolute-path fallback.
    _bin_dir="$(make_tmpdir)"
    _well_known_dir="$(make_tmpdir)"
    link_existing_commands "$_bin_dir" uname sed cut curl wget mktemp rm tar gzip chmod ln mkdir mv id du printf od awk shasum sha256sum head cat kill sleep stat grep tr openssl

    write_fake_tmux "$_well_known_dir" "3.6a"
    _well_known_tmux="${_well_known_dir}/tmux"

    _out="${_bin_dir}/out"
    # Patch _find_tmux's well-known paths to use our temp dir instead of
    # /usr/local/bin and /usr/bin so the test stays self-contained.
    _patched_script="${_bin_dir}/q-patched.sh"
    sed "s|/usr/local/bin/tmux /usr/bin/tmux|${_well_known_tmux}|" "$INSTALL_SCRIPT" > "$_patched_script"
    chmod +x "$_patched_script"

    if PATH="${_bin_dir}" QUICKTUI_RELEASES="http://127.0.0.1:${MOCK_PORT}" \
        "$SHELL_BIN" "$_patched_script" -y --no-service >"${_out}" 2>&1; then
        assert_file_contains "${HOME}/.config/quicktui/config" "QUICKTUI_TMUX_BIN=${_well_known_tmux}" \
            "well-known-path tmux writes QUICKTUI_TMUX_BIN"
    else
        fail "well-known-path tmux writes QUICKTUI_TMUX_BIN" "installer failed unexpectedly"
        printf '    DEBUG: '; head -30 "${_out}" 2>/dev/null; printf '\n'
    fi
}

test_tmux_install_from_builds_no_pkg_manager() {
    printf '\n--- test_tmux_install_from_builds_no_pkg_manager ---\n'
    reset_test_env

    # Minimal PATH: essential commands but no brew/port/apt-get/yum/dnf/tmux
    _bin_dir="$(make_tmpdir)"
    link_existing_commands "$_bin_dir" sh env uname curl wget sed cut mktemp rm tar gzip chmod ln mkdir mv id du printf od awk shasum sha256sum head cat kill sleep stat grep tr

    # Patch out well-known paths so the test always exercises the
    # tmux-builds download path, even when /usr/bin/tmux exists.
    _patched_script="${_bin_dir}/q-patched.sh"
    sed 's|/usr/local/bin/tmux /usr/bin/tmux|/nonexistent/tmux|' "$INSTALL_SCRIPT" > "$_patched_script"
    chmod +x "$_patched_script"

    _out="${_bin_dir}/out"
    _input="$(printf 'y\n\n\ny\n\n\n\nn\n')"

    _err="${_bin_dir}/err"
    if run_command_interactive "${_out}" "${_input}" \
        "$ENV_BIN" \
        "PATH=${_bin_dir}" \
        "HOME=${HOME}" \
        "QUICKTUI_RELEASES=http://127.0.0.1:${MOCK_PORT}" \
        "TMUX_BUILDS_VERSION=0.0.1-test" \
        "TMUX_BUILDS_RELEASES=http://127.0.0.1:${MOCK_PORT}" \
        "$SHELL_BIN" "$_patched_script" 2>"$_err"; then
        assert_file_exists "${HOME}/.local/tmux/tmux" "tmux binary installed to ~/.local/tmux"
        assert_file_exists "${HOME}/.local/bin/tmux" "tmux symlinked to ~/.local/bin"
        if [ -L "${HOME}/.local/bin/tmux" ]; then
            pass "~/.local/bin/tmux is a symlink"
        else
            fail "~/.local/bin/tmux is a symlink" "not a symlink"
        fi
        assert_file_contains "${HOME}/.config/quicktui/config" "QUICKTUI_TMUX_BIN=${HOME}/.local/tmux/tmux" "from-builds install writes absolute QUICKTUI_TMUX_BIN"
        assert_output_contains "${_out}" "tmux installed to ~/.local/tmux" "from-builds success message shown"
    else
        printf '    DEBUG stdout: '; head -20 "${_out}" 2>/dev/null; printf '\n'
        printf '    DEBUG stderr: '; head -20 "${_err}" 2>/dev/null; printf '\n'
        fail "tmux install from builds completes successfully" "installer unexpectedly failed"
    fi
}

test_check_flag_runs_without_install() {
    printf '\n--- test_check_flag_runs_without_install ---\n'
    reset_test_env

    _tmp="$(make_tmpdir)"
    _out="${_tmp}/out"

    # --check should run environment checks and exit without downloading or installing
    if "$SHELL_BIN" "$INSTALL_SCRIPT" --check >"${_out}" 2>&1; then
        assert_output_contains "${_out}" "Environment checks" "check flag prints environment checks header"
    else
        # Even if checks find warnings, we still verify it ran checks (not an install)
        assert_output_contains "${_out}" "Environment checks" "check flag prints environment checks header"
    fi

    assert_path_not_exists "${HOME}/.local/bin/quicktui-server" "check flag does not install binary"
    assert_path_not_exists "${HOME}/.config/quicktui/config" "check flag does not write config"
}

test_preflight_warns_missing_locale() {
    printf '\n--- test_preflight_warns_missing_locale ---\n'
    reset_test_env

    _bin_dir="$(make_tmpdir)"
    _tmp="$(make_tmpdir)"
    _out="${_tmp}/out"

    # Create a fake locale command that returns no locales
    cat > "${_bin_dir}/locale" <<'EOF'
#!/bin/sh
# Return empty locale list
exit 0
EOF
    chmod +x "${_bin_dir}/locale"
    link_existing_commands "$_bin_dir" uname infocmp sh script sed grep cut
    write_fake_tmux "$_bin_dir" "3.6a"

    # Locale fallback is not an error — --check should exit 0
    PATH="${_bin_dir}" "$SHELL_BIN" "$INSTALL_SCRIPT" --check --lang en_US.UTF-8 >"${_out}" 2>&1 || true

    assert_output_contains "${_out}" "falling back to C.UTF-8" "missing locale triggers fallback"
}

test_preflight_warns_missing_terminfo() {
    printf '\n--- test_preflight_warns_missing_terminfo ---\n'
    reset_test_env

    _bin_dir="$(make_tmpdir)"
    _tmp="$(make_tmpdir)"
    _out="${_tmp}/out"

    # Create a fake infocmp that always fails
    cat > "${_bin_dir}/infocmp" <<'EOF'
#!/bin/sh
exit 1
EOF
    chmod +x "${_bin_dir}/infocmp"
    link_existing_commands "$_bin_dir" uname locale sh script sed grep cut
    write_fake_tmux "$_bin_dir" "3.6a"

    # Terminfo fallback is not an error — --check should exit 0
    PATH="${_bin_dir}" "$SHELL_BIN" "$INSTALL_SCRIPT" --check --term xterm-256color >"${_out}" 2>&1 || true

    assert_output_contains "${_out}" "falling back to screen-256color" "missing terminfo triggers fallback"
}

test_preflight_skips_when_locale_cmd_missing() {
    printf '\n--- test_preflight_skips_when_locale_cmd_missing ---\n'
    reset_test_env

    _bin_dir="$(make_tmpdir)"
    _tmp="$(make_tmpdir)"
    _out="${_tmp}/out"

    # Do NOT link locale — it should be missing from PATH
    link_existing_commands "$_bin_dir" uname infocmp sh script sed grep cut
    write_fake_tmux "$_bin_dir" "3.6a"

    # Should not error; locale check should be skipped
    PATH="${_bin_dir}" "$SHELL_BIN" "$INSTALL_SCRIPT" --check >"${_out}" 2>&1 || true

    assert_output_contains "${_out}" "Locale check skipped" "locale check skipped when command missing"
    assert_output_not_contains "${_out}" 'Locale "' "no locale warning when command missing"
}

test_preflight_tmux_session_cleanup() {
    printf '\n--- test_preflight_tmux_session_cleanup ---\n'
    reset_test_env

    # Use the real tmux binary, not any fake from previous tests
    _real_tmux="$(command -v tmux 2>/dev/null || echo /usr/bin/tmux)"

    # Clean up any leftover session from previous tests
    "$_real_tmux" kill-session -t _qtui_preflight 2>/dev/null || true
    "$_real_tmux" kill-server 2>/dev/null || true

    _tmp="$(make_tmpdir)"
    _out="${_tmp}/out"

    # Run --check with real tmux (available in Docker image)
    "$SHELL_BIN" "$INSTALL_SCRIPT" --check >"${_out}" 2>&1 || true

    # The _qtui_preflight session should have been cleaned up
    if "$_real_tmux" has-session -t _qtui_preflight 2>/dev/null; then
        fail "preflight tmux session cleaned up" "session _qtui_preflight still exists"
        "$_real_tmux" kill-session -t _qtui_preflight 2>/dev/null || true
    else
        pass "preflight tmux session cleaned up"
    fi
}

# ============================================================
# Main
# ============================================================

main() {
    printf '\n\033[1m=== QuickTUI q.sh Test Suite ===\033[0m\n'

    setup_mock_server
    trap cleanup_all EXIT INT TERM
    reset_test_env

    test_help_flag
    test_check_flag_runs_without_install
    test_preflight_warns_missing_locale
    test_preflight_warns_missing_terminfo
    test_preflight_skips_when_locale_cmd_missing
    test_preflight_tmux_session_cleanup
    test_unknown_option
    test_missing_option_value
    test_unsupported_platform
    test_unsupported_architecture
    test_tmux_missing_noninteractive
    test_tmux_install_reports_missing_after_package_manager_returns_success
    test_tmux_old_version_noninteractive
    test_tmux_old_version_interactive_continue
    test_no_download_tool
    test_checksum_failure
    test_default_install
    test_no_service_message
    test_custom_token
    test_custom_addr_no_service
    test_ipv6_addr_no_service
    test_invalid_noninteractive_addr
    test_invalid_noninteractive_port
    test_service_config
    test_service_registration_failure
    test_service_startup_failure_after_registration
    test_interactive_invalid_token_choice
    test_interactive_empty_custom_token
    test_interactive_custom_token_and_decline_service
    test_interactive_service_prompt_defaults_yes
    test_interactive_provided_addr_port_not_prompted
    test_interactive_invalid_addr_and_port_reprompt
    test_uninstall_nothing_installed
    test_uninstall_removes_leftovers_without_binary
    test_binary_executable
    test_upgrade_preserves_token
    test_upgrade_preserves_config
    test_upgrade_with_new_token
    test_upgrade_replaces_binary
    test_upgrade_stops_service_before_replace
    test_upgrade_shows_upgrade_message
    test_upgrade_ipv6_preserves_addr
    test_sudo_n_fallback_to_tmux_builds
    test_tmux_found_at_well_known_path_sets_config
    test_tmux_install_from_builds_no_pkg_manager

    printf '\n\033[1m=== Results: %d passed, %d failed ===\033[0m\n\n' "$TESTS_PASSED" "$TESTS_FAILED"

    if [ "$TESTS_FAILED" -gt 0 ]; then
        exit 1
    fi
}

main
