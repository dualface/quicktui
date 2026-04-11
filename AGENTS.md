# Repository Guidelines

## Structure

Static website + installer script repo. `index.html` = main landing page, styles inlined. `privacy.html` = privacy page. `images/` = logos/device frames/screenshots. `docs/` = site assets. `q.sh` = POSIX `sh` install/uninstall script. `tests/test_install.sh` = installer regression suite. `Dockerfile.test` runs same tests in clean container. `.github/workflows/test-intel-mac.yml` → integration test of `darwin/amd64` binary on macOS via Rosetta 2.

## Language Policy

Repo English-only: `AGENTS.md`, docs, page copy, comments, commit notes, test descriptions. No Chinese or mixed-language wording.

## Common Commands

No frontend build pipeline — static HTML + shell. Key commands: `sh q.sh --help` (installer options), `docker build -f Dockerfile.test -t quicktui-test . && docker run --rm quicktui-test` (regression suite in clean container), `python3 -m http.server` (local preview), `git diff --check` (patch sanity).

## Coding Conventions

HTML: 2-space indent. Style changes → `<style>` block in `index.html`. No second stylesheet source. `q.sh` = POSIX `sh` only, no bash-isms. Screenshots/assets grouped by device, e.g. `images/iPad/...`, `images/iPhone/...`. Tests: prefer helper fns or `test_<behavior>()` cases. No one-off assertion scripts.

## Testing And Commits

**Never run tests on local host.** Always Docker (`docker build -f Dockerfile.test -t quicktui-test . && docker run --rm quicktui-test`) or push → GitHub Actions. `docker` not in PATH → full path `/Applications/Docker.app/Contents/Resources/bin/docker`.

Installer behavior changes → add coverage in `tests/test_install.sh`. Never change script without updating regressions. PATH-restricting tests should patch out well-known absolute paths (`/usr/local/bin/tmux`, `/usr/bin/tmux`) via `sed` when Docker image pre-installs them. Site copy/layout changes → pass `git diff --check`. Visible style changes → browser spot check. Commit messages why-first, scoped by installer / tests / site copy-layout. Behavioral changes → describe verification in body. Never commit real tokens, server addresses, local state files, or `.omx/` contents.
