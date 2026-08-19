# Stable Install Verifier

This directory contains the synthetic monitor for public QuickTUI server installs and mirrored release integrity. Global cells run the same public `curl | sh` installer paths that users run from `quicktui.ai` inside a disposable privileged Linux container with user systemd enabled. CN `q.sh` cells validate the public manifest and mirrored server archive checksum without running an installer.

The monitor is read-only with respect to release state. It does not publish, tag, upload, or modify manifests. Its only remote side effect is the GitHub Actions reporting jobs that create, comment on, or close fixed monitor Issues when the scheduled workflows run.

## Matrix

Install-mode cells run in disposable containers. CN checksum-mode cells run directly on the GitHub runner and use only temporary files.

`.github/workflows/verify-qsh-install.yml` verifies these `q.sh` cells:

- `quicktui.ai / stable / install`: runs `q.sh -y` and verifies the installed server,
  user service, and version API.
- `quicktui.ai / preview / install`: runs `q.sh -y --preview --required-version-2`
  and performs the same runtime checks.
- `dl.quicktui.cn / stable / checksum`: validates the stable manifest entry and
  mirrored `quicktui-server-linux-amd64.gz` SHA-256.
- `dl.quicktui.cn / preview / checksum`: validates the preview manifest entry and
  the same mirrored archive SHA-256.

Each CN checksum cell validates manifest schema version 1, the channel object and tag shape,
and declarations for the archive and its `.sha256` file. It then downloads both files from
`https://dl.quicktui.cn/releases/download/<tag>/` and requires the actual archive digest to
match the 64-character hexadecimal digest in the checksum file. It does not download or run
`q.sh`, the native installer, or the server.

`.github/workflows/verify-q2-install.yml` verifies `q2.sh` preview installs:

| site | script | channel | install command |
| --- | --- | --- | --- |
| `quicktui.ai` | `q2.sh` | `preview` | `curl -fsSL https://quicktui.ai/q2.sh \| sh -s -- --preview` |
| `dl.quicktui.cn` | `q2.sh` | `preview` | `curl -fsSL https://dl.quicktui.cn/q2.sh \| sh -s -- --preview` |

`q2.sh` currently supports the preview channel only, so the q2 workflow does not include `q2.sh` stable cells.

Preview cells exit `skip` when the site's `server-manifest.json` has no preview channel or usable preview tag. Skip is a green monitor state. A malformed channel or tag is a hard failure, as is any other non-skip failure.

## Local Reproduction

The Docker wrapper reproduces install-mode cells. Run from the repository root:

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
| `QT_VERIFY_VERSION_ATTEMPTS` | `100` | Version API polling attempts; the verifier tries `/v3/version`, then `/v2/version`, then legacy `/api/version`. |

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

Each workflow cell uploads these files. Install-mode cells copy them from the disposable
container; CN checksum-mode cells write them directly under the runner temporary directory.

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
| `installed.tag` | Tag parsed from the installed server; empty for CN checksum cells. |
| `installed.version_response_endpoint` | Version endpoint for install-mode cells. |
| `assertions.S1` through `assertions.S7` | Install-mode assertion results. |
| `expected.asset` | Archive selected by a CN checksum cell. |
| `expected.checksum_asset` | Checksum file selected by a CN checksum cell. |
| `expected.sha256` | Digest read from the CN checksum file. |
| `verified.asset` | Archive downloaded and hashed by a CN checksum cell. |
| `verified.sha256` | Digest calculated from the downloaded CN archive. |
| `log_tail`, `journal_tail` | Sanitized install-mode log tails. |

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

For install-mode cells, host-side effects are limited to Docker image/container lifecycle, a temporary env file, copied result/log artifacts, and cleanup. The public installers, tmux, service registration, user systemd, and version API checks run inside the disposable container, not on the host.

CN checksum-mode cells do not start Docker or execute release binaries. They download the
manifest, Linux amd64 archive, and checksum into a temporary runner directory, write result and
log artifacts, and remove the downloaded files when the step exits.

The wrapper:

- creates a temporary env file outside the repository and mounts it read-only at `/etc/qt-verify.env`;
- does not mount the repository as a writable volume;
- mounts only `/sys/fs/cgroup` for systemd support and tmpfs mounts for `/run` and `/run/lock`;
- removes the container on exit;
- rejects test-only expected-tag overrides unless `QT_VERIFY_TEST_MODE=1`.

Do not run public `q.sh` / `q2.sh` install commands directly on the host for this monitor. Use
`run-verify-docker.sh` for install-mode reproduction. The CN checksum path is defined inline in
`.github/workflows/verify-qsh-install.yml` and does not have a host-side install command.

## Known Limitations

- GitHub-hosted runners are Linux amd64, so this does not cover macOS, Windows, arm64, or launchd paths.
- CN `q.sh` cells verify only `quicktui-server-linux-amd64.gz` and its `.sha256` file. They do
  not cover the CN bootstrap, installer, service, runtime API, signatures, or other platform
  assets; the Global cells retain installer and runtime coverage for Linux amd64.
- CN mirror reachability from GitHub-hosted runners can be noisy. The monitor intentionally records those failures as hard failures for now; adjust matrix policy later only with explicit operations data.
- Live GitHub Actions dispatch and live Issue behavior can only be validated after the workflow file exists on the default branch.
