# Repository Guidelines

## Project Structure & Module Organization

This repository is a small static site plus installer/test assets.

- `index.html`: landing page and contributor-facing product copy.
- `css/style.css`: all site styling, including screenshot layout and responsive rules.
- `images/`: logos, device frames, and screenshot assets (`images/iPhone/`, `images/iPad/`).
- `q.sh`: POSIX `sh` installer/uninstaller for QuickTUI server.
- `tests/test_install.sh`: end-to-end installer regression suite.
- `Dockerfile.test`: Ubuntu-based test runner for `tests/test_install.sh`.

## Build, Test, and Development Commands

There is no frontend build pipeline here; changes are mostly static HTML/CSS and shell.

- `sh q.sh --help`: inspect the current installer CLI surface.
- `sh tests/test_install.sh`: run the installer regression suite locally.
- `docker build -f Dockerfile.test -t quicktui-test . && docker run --rm quicktui-test`: run the same installer suite in a clean container.
- `python3 -m http.server`: optional local preview for `index.html` and `css/style.css`.
- `git diff --check`: quick whitespace / patch sanity check before commit.

## Coding Style & Naming Conventions

- Use 2-space indentation in HTML and CSS; keep formatting consistent with existing files.
- Keep `q.sh` compatible with POSIX `sh`; do not introduce bash-only syntax.
- Prefer small, direct edits over new abstractions. This repo is intentionally simple.
- Keep screenshot and asset names descriptive and grouped by device, for example `images/iPad/01-setup-wizard-01.png`.
- In shell tests, add helpers or `test_*` functions rather than inline one-off logic.

## Testing Guidelines

- Installer behavior changes should be covered in `tests/test_install.sh`.
- Name new tests `test_<behavior>()` and reset state inside the test before assertions.
- For static site changes, run `git diff --check`; for layout or copy changes, also do a browser spot check when practical.

## Commit & Pull Request Guidelines

- Use concise imperative commit subjects, for example `Align connect flow copy with current iOS onboarding paths`.
- Keep commits scoped by concern: installer, tests, or site copy/layout.
- Include a short rationale in the commit body when behavior changes.
- PRs should summarize user-facing impact, list verification steps, and include screenshots for `index.html` / CSS changes.

## Security & Configuration Notes

- Never commit real tokens, server URLs, or generated local state.
- Keep `.omx/` untracked.
- Use placeholder values such as `QUICKTUI_TOKEN=your-secret-token` in docs and examples.
