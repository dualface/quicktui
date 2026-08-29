# Stable Install Verifier

This directory contains the synthetic monitor for public QuickTUI server
installs. The scheduled GitHub Actions workflows in this repository run the
same public `curl | sh` installer paths that users run from `quicktui.ai`
inside a disposable privileged Linux container with user systemd enabled.

The monitor is read-only with respect to release state. It does not publish,
tag, upload, or modify manifests. Its only remote side effect is the GitHub
Actions reporting jobs that create, comment on, or close fixed monitor Issues
when the scheduled workflows run.

These scripts are synced from `quicktui-mono` `website/monitoring/`. Public
paths and Docker layout stay local to this repository:

- `website/monitoring/verify-install.sh` -> `monitoring/verify-install.sh`
- `website/monitoring/verify-systemd-boot.sh` -> `monitoring/verify-systemd-boot.sh`
- `website/monitoring/qt-verify.service` -> `monitoring/qt-verify.service`
- `website/monitoring/Dockerfile.verify` maps `COPY website/monitoring/` to
  `COPY monitoring/` and creates both schema v1 and v2 config directories
- `website/monitoring/run-verify-docker.sh` stays a public-repo wrapper that
  builds `monitoring/Dockerfile.verify`; it does not import monorepo Docker
  environment lock scripts

## Matrix

`.github/workflows/verify-qsh-install.yml` runs one disposable container per
matrix cell:

| site          | script | channel   | install command                                                              |
| ------------- | ------ | --------- | ---------------------------------------------------------------------------- |
| `quicktui.ai` | `q.sh` | `stable`  | `curl -fsSL https://quicktui.ai/q.sh \| sh -s -- install --channel stable -y`  |
| `quicktui.ai` | `q.sh` | `preview` | `curl -fsSL https://quicktui.ai/q.sh \| sh -s -- install --channel preview -y` |

GitHub-hosted runners are outside China and cannot reliably reach
`dl.quicktui.cn`. CN mirror verification stays local-only in `quicktui-mono`.

Preview cells exit `skip` when the site's `server-manifest.json` has no usable
preview tag. Skip is a green monitor state. Any non-skip failure is a hard
failure for that workflow.

## Local Reproduction

Run from this repository root:

```sh
sh monitoring/run-verify-docker.sh \
  --site quicktui.ai \
  --script q.sh \
  --channel stable
```

Wrapper-level environment overrides:

| variable                    | default                        | purpose                                              |
| --------------------------- | ------------------------------ | ---------------------------------------------------- |
| `QT_VERIFY_ARTIFACT_DIR`    | `.verify-artifacts`            | Host-side directory for copied result/log artifacts. |
| `QT_VERIFY_IMAGE`           | `quicktui-install-verifier`    | Docker image name.                                   |
| `QT_VERIFY_CONTAINER`       | `quicktui-install-verifier-$$` | Container name.                                      |
| `QT_VERIFY_TIMEOUT_SECONDS` | `900`                          | Host wrapper timeout.                                |

The container verifier uses these defaults internally. The wrapper does not
currently forward host environment values for these variables into the
container; change the wrapper or workflow deliberately if an operations run
needs to tune them.

| variable                                  | default | purpose                                                |
| ----------------------------------------- | ------- | ------------------------------------------------------ |
| `QT_VERIFY_RETRY_ATTEMPTS`                | `3`     | Manifest/install retry attempts inside the container.  |
| `QT_VERIFY_MANIFEST_TIMEOUT_SECONDS`      | `20`    | Per-attempt manifest fetch timeout.                    |
| `QT_VERIFY_INSTALL_TIMEOUT_SECONDS`       | `300`   | Per-attempt installer timeout.                         |
| `QT_VERIFY_SERVICE_ATTEMPTS`              | `30`    | User service active polling attempts.                  |
| `QT_VERIFY_VERSION_ATTEMPTS`              | `100`   | Probe attempt cap for schema v1/v2 readiness polling.  |
| `QT_VERIFY_PROBE_DEADLINE_SECONDS`        | `20`    | Wall-clock deadline for a schema v2 complete sample.   |
| `QT_VERIFY_PROBE_CONNECT_TIMEOUT_SECONDS` | `2`     | Per-request curl connect timeout for readiness probes. |
| `QT_VERIFY_PROBE_MAX_TIME_SECONDS`        | `3`     | Per-request curl max time for readiness probes.        |

Test-only modes:

```sh
QT_VERIFY_TEST_MODE=1 QT_VERIFY_PLAN_ONLY=1 \
  sh monitoring/run-verify-docker.sh \
    --site quicktui.ai --script q.sh --channel stable
```

Plan-only mode validates argument handling and installer command construction
without running the public installer.

```sh
QT_VERIFY_TEST_MODE=1 QT_VERIFY_EXPECTED_TAG_OVERRIDE=bad-tag \
  sh monitoring/run-verify-docker.sh \
    --site quicktui.ai --script q.sh --channel stable
```

The expected-tag override is only accepted with `QT_VERIFY_TEST_MODE=1`. It is
used for negative self-checks that prove the S5 expected-vs-installed assertion
fails when the install reaches version comparison. If the public install fails
earlier, that earlier assertion remains the real failure and the S5 check is
not exercised.

## Result Artifacts

The wrapper copies these files from the container:

| file                    | meaning                             |
| ----------------------- | ----------------------------------- |
| `qt-verify-result.json` | Structured cell result.             |
| `qt-verify-install.log` | Installer/verifier log tail source. |

Important result fields:

| field                                 | meaning                                                                                         |
| ------------------------------------- | ----------------------------------------------------------------------------------------------- |
| `status`                              | `pass`, `fail`, or `skip`.                                                                      |
| `site`, `script`, `channel`           | Matrix cell identity.                                                                           |
| `reason`                              | Human-readable failure or skip reason.                                                          |
| `expected.tag`                        | Tag selected from the same site's manifest.                                                     |
| `installed.tag`                       | Tag parsed from the installed `quicktui-server`.                                                |
| `installed.version_response_endpoint` | Public version endpoint that returned the service version.                                      |
| `installed.health_response_endpoint`  | Public health endpoint that returned `status=ok`.                                               |
| `installed.pairing_response_endpoint` | Public capability endpoint advertising E2E `device_pop_v1` pairing readiness.                   |
| `installed.pairing_ready`             | Whether the capability passed the E2E/pairing protocol and identity checks.                     |
| `probe_attempts`                      | Actual schema v2 probe rounds executed, or null when the v2 probe did not run.                  |
| `probe_elapsed_seconds`               | Schema v2 probe wall time in seconds, or null when the v2 probe did not run.                    |
| `probe_last_stage`                    | Last failed v2 stage (`health`, `version`, `capability`, or `deadline`). Empty on success.      |
| `probe_last_curl_status`              | Curl exit status of the last failed v2 request. Null on success or unused.                      |
| `timing.probe_*`                      | The same probe diagnostic fields nested under `timing`.                                         |
| `assertions.S1` through `assertions.S7` | Install, binary, tag shape, manifest, version match, service, and version API checks.         |
| `log_tail`, `journal_tail`            | Sanitized tails used by the Actions summary and monitor Issue.                                  |

Each workflow uploads result and log artifacts for every cell with
`if: always()`. Each summary job treats missing or invalid result artifacts as
hard failures so a failed cell cannot disappear from the monitor.

## Reporting

`.github/workflows/verify-qsh-install.yml` runs daily and supports manual
dispatch. Its summary job is serialized with the workflow concurrency group
`verify-qsh-install-monitor`, so concurrent runs do not race its fixed monitor
Issue.

When hard-fail cells exist, the summary job creates or comments on the open
Issue for the installer:

```text
[monitor] q.sh install verification failing
```

When no hard-fail cells remain, the summary job comments on its open monitor
Issue and closes it. The Issue body includes the run link and a sanitized
hard-failure table. Per-cell scalar fields, log tails, and the final Issue body
are bounded before they are sent to GitHub; use the uploaded artifacts for full
logs.

The q.sh workflow also closes any open legacy Issue titled
`[monitor] stable install verification failing` with a superseded comment.

## Host-Side Boundary

Host-side effects are limited to Docker image/container lifecycle, a temporary
env file, copied result/log artifacts, and cleanup. The public installers,
tmux, service registration, user systemd, and version API checks run inside the
disposable container, not on the host.

The verifier selects its checks from the installed setup schema. Stable schema
v1 installations use the legacy env config, authenticate with its root token,
and accept the registered legacy version endpoints. Schema v2 installations use
the TOML config and probe `/v3/healthz`, `/v3/version`, and
`/.well-known/quicktui-server-capability` without an `Authorization` header.
Schema v2 waits for health first, then requires one complete sample where
health, version, and capability are all valid in the same round. Each probe
request uses bounded curl connect/max timeouts, capped to the remaining
wall-clock deadline, and a new request is not started after the deadline. The
loop also stops at the attempt cap. Failure artifacts record the actual attempt
count, last failed stage, curl exit status, and probe elapsed time; result
fields come from that last observation, not from mixing earlier successes with
a later failure. The v2 capability must advertise `quicktui.e2e.v1`, the
same-host `ws://.../e2e` endpoint, `pairing_code_v1`, a valid identity
fingerprint, and `device_pop_v1` before the install is considered ready.

The wrapper:

- creates a temporary env file outside the repository and mounts it read-only
  at `/etc/qt-verify.env`;
- does not mount the repository as a writable volume;
- mounts only `/sys/fs/cgroup` for systemd support and tmpfs mounts for `/run`
  and `/run/lock`;
- removes the container on exit;
- rejects test-only expected-tag overrides unless `QT_VERIFY_TEST_MODE=1`.

Do not run public `q.sh` install commands directly on the host for this
monitor. Use `run-verify-docker.sh`.

## Known Limitations

- GitHub-hosted runners are Linux amd64, so this does not cover macOS, Windows,
  arm64, or launchd paths.
- CN mirror reachability from GitHub-hosted runners can be noisy. CN cells are
  not part of this workflow matrix.
- Live GitHub Actions dispatch and live Issue behavior can only be validated
  after the workflow file exists on the default branch.
