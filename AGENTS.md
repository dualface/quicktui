# Repository Guidelines

## Structure

This is a static website plus installer script repository. `index.html` is the main landing page with styles inlined; `privacy.html` is the privacy page; `images/` holds logos, device frames, and screenshots; `docs/` holds site assets; `q.sh` is the POSIX `sh` install/uninstall script; `tests/test_install.sh` is the installer regression test suite; `Dockerfile.test` runs the same tests in a clean container; `.github/workflows/test-intel-mac.yml` runs an integration test of the `darwin/amd64` binary on macOS via Rosetta 2.

## Common Commands

No frontend build pipeline — just static HTML and shell. Key commands: `sh q.sh --help` to view installer options, `sh tests/test_install.sh` to run local regression tests, `docker build -f Dockerfile.test -t quicktui-test . && docker run --rm quicktui-test` to reproduce the test environment in a container, `python3 -m http.server` to preview pages locally, `git diff --check` for basic patch sanity.

## Coding Conventions

HTML uses 2-space indentation; style changes go directly into the `<style>` block in `index.html` — do not introduce a second stylesheet source. `q.sh` must remain POSIX `sh` compatible; no bash-only syntax. Screenshots and assets are grouped by device, e.g. `images/iPad/...`, `images/iPhone/...`. In tests, prefer adding helper functions or `test_<behavior>()` cases; do not pile up one-off assertion scripts.

## Testing And Commits

Installer behavior changes must include corresponding coverage in `tests/test_install.sh`; never change the script without updating regressions. Site copy or layout changes should at least pass `git diff --check`; visible style changes should also get a browser spot check. Commit messages should be why-first, scoped by installer / tests / site copy-layout; behavioral changes must describe verification steps in the body. Never commit real tokens, server addresses, local state files, or `.omx/` contents.
