# Stable Install Verifier

This directory contains the synthetic monitor for public QuickTUI server installs. It runs the same public `curl | sh` installer paths that users run from `quicktui.ai` and `dl.quicktui.cn`, but does so inside a disposable privileged Linux container with user systemd enabled.

The monitor is read-only with respect to release state. It does not publish, tag, upload, or modify manifests. Its only remote side effect is the GitHub Actions reporting jobs that create, comment on, or close fixed monitor Issues when the scheduled workflows run.

## Matrix

The GitHub Actions workflows run one disposable container per matrix cell.

`.github/workflows/verify-qsh-install.yml` verifies `q.sh` stable and preview installs:

| site | script | channel | install command |
| --- | --- | --- | --- |
| `quicktui.ai` | `q.sh` | `stable` | `curl -fsSL https://quicktui.ai/q.sh \| sh -s -- -y` |
| `quicktui.ai` | `q.sh` | `preview` | `curl -fsSL https://quicktui.ai/q.sh \| sh -s -- -y --preview --required-version-2` |
| `dl.quicktui.cn` | `q.sh` | `stable` | `curl -fsSL https://dl.quicktui.cn/q.sh \| sh -s -- -y` |
| `dl.quicktui.cn` | `q.sh` | `preview` | `curl -fsSL https://dl.quicktui.cn/q.sh \| sh -s -- -y --preview --required-version-2` |

`.github/workflows/verify-q2-install.yml` verifies `q2.sh` preview installs:

| site | script | channel | install command |
| --- | --- | --- | --- |
| `quicktui.ai` | `q2.sh` | `preview` | `curl -fsSL https://quicktui.ai/q2.sh \| sh -s -- --preview` |
| `dl.quicktui.cn` | `q2.sh` | `preview` | `curl -fsSL https://dl.quicktui.cn/q2.sh \| sh -s -- --preview` |

`q2.sh` currently supports the preview channel only, so the q2 workflow does not include `q2.sh` stable cells.

Preview cells exit `skip` when the site's `server-manifest.json` has no usable preview tag. Skip is a green monitor state. Any non-skip failure is a hard failure for that workflow.

## Local Reproduction

Run from the repository root:

```sh
sh monitoring/run-verify-docker.sh \
  --site quicktui.ai \
  --script q2.sh \
  --channel preview
```

Wrapper-level environment overrides:

| variable | default | purpose |
| --- | --- | --- |
| `QT_VERIFY_ARTIFACT_DIR` | `.verify-artifacts` | Host-side directory for copied result/log artifacts. |
| `QT_VERIFY_IMAGE` | `quicktui-install-verifier` | Docker image name. |
| `QT_VERIFY_CONTAINER` | `quicktui-install-verifier-$$` | Container name. |
| `QT_VERIFY_TIMEOUT_SECONDS` | `900` | Host wrapper timeout. |

The container verifier uses these defaults internally. The wrapper does not currently forward host environment values for these variables into the container; change the wrapper or workflow deliberately if an operations run needs to tune them.

| variable | default | purpose |
| --- | --- | --- |
| `QT_VERIFY_RETRY_ATTEMPTS` | `3` | Manifest/install retry attempts inside the container. |
| `QT_VERIFY_MANIFEST_TIMEOUT_SECONDS` | `20` | Per-attempt manifest fetch timeout. |
| `QT_VERIFY_INSTALL_TIMEOUT_SECONDS` | `300` | Per-attempt installer timeout. |
| `QT_VERIFY_SERVICE_ATTEMPTS` | `30` | User service active polling attempts. |
| `QT_VERIFY_VERSION_ATTEMPTS` | `100` | Version API polling attempts; the verifier tries `/v2/version` first and falls back to legacy `/api/version`. |

Test-only modes:

```sh
QT_VERIFY_TEST_MODE=1 QT_VERIFY_PLAN_ONLY=1 \
  sh monitoring/run-verify-docker.sh \
    --site quicktui.ai --script q2.sh --channel preview
```

Plan-only mode validates argument handling and installer command construction without running the public installer.

```sh
QT_VERIFY_TEST_MODE=1 QT_VERIFY_EXPECTED_TAG_OVERRIDE=bad-tag \
  sh monitoring/run-verify-docker.sh \
    --site quicktui.ai --script q.sh --channel stable
```

The expected-tag override is only accepted with `QT_VERIFY_TEST_MODE=1`. It is used for negative self-checks that prove the S5 expected-vs-installed assertion fails when the install reaches version comparison. If the public install fails earlier, that earlier assertion remains the real failure and the S5 check is not exercised.

## Result Artifacts

The wrapper copies these files from the container:

| file | meaning |
| --- | --- |
| `qt-verify-result.json` | Structured cell result. |
| `qt-verify-install.log` | Installer/verifier log tail source. |

Important result fields:

| field | meaning |
| --- | --- |
| `status` | `pass`, `fail`, or `skip`. |
| `site`, `script`, `channel` | Matrix cell identity. |
| `reason` | Human-readable failure or skip reason. |
| `expected.tag` | Tag selected from the same site's manifest. |
| `installed.tag` | Tag parsed from the installed `quicktui-server`. |
| `installed.version_response_endpoint` | Version endpoint that returned the service version. |
| `assertions.S1` through `assertions.S7` | Install, binary, tag shape, manifest, version match, service, and version API checks. |
| `log_tail`, `journal_tail` | Sanitized tails used by the Actions summary and monitor Issue. |

Each workflow uploads result and log artifacts for every cell with `if: always()`. Each summary job treats missing or invalid result artifacts as hard failures so a failed cell cannot disappear from the monitor.

## Reporting

`.github/workflows/verify-qsh-install.yml` and `.github/workflows/verify-q2-install.yml` run daily and support manual dispatch. Their summary jobs are serialized with separate workflow concurrency groups, `verify-qsh-install-monitor` and `verify-q2-install-monitor`, so concurrent runs do not race their fixed monitor Issues.

When hard-fail cells exist, each summary job creates or comments on the open Issue for that installer:

```text
[monitor] q.sh install verification failing
[monitor] q2.sh install verification failing
```

When no hard-fail cells remain, each summary job comments on its open monitor Issue and closes it. The Issue body includes the run link and a sanitized hard-failure table. Per-cell scalar fields, log tails, and the final Issue body are bounded before they are sent to GitHub; use the uploaded artifacts for full logs.

The q.sh workflow also closes any open legacy Issue titled `[monitor] stable install verification failing` with a superseded comment, because that combined monitor was split into separate q.sh and q2.sh issue streams.

## Host-Side Boundary

Host-side effects are limited to Docker image/container lifecycle, a temporary env file, copied result/log artifacts, and cleanup. The public installers, tmux, service registration, user systemd, and version API checks run inside the disposable container, not on the host.

The wrapper:

- creates a temporary env file outside the repository and mounts it read-only at `/etc/qt-verify.env`;
- does not mount the repository as a writable volume;
- mounts only `/sys/fs/cgroup` for systemd support and tmpfs mounts for `/run` and `/run/lock`;
- removes the container on exit;
- rejects test-only expected-tag overrides unless `QT_VERIFY_TEST_MODE=1`.

Do not run public `q.sh` / `q2.sh` install commands directly on the host for this monitor. Use `run-verify-docker.sh`.

## Known Limitations

- GitHub-hosted runners are Linux amd64, so this does not cover macOS, Windows, arm64, or launchd paths.
- CN mirror reachability from GitHub-hosted runners can be noisy. The monitor intentionally records those failures as hard failures for now; adjust matrix policy later only with explicit operations data.
- Live GitHub Actions dispatch and live Issue behavior can only be validated after the workflow file exists on the default branch.
