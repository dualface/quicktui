# QuickTUI

QuickTUI connects your phone or tablet to terminal sessions on your computer. Visit [quicktui.ai](https://quicktui.ai) for product information and installation instructions.

This repository hosts GitHub Releases, public installation monitoring, and a read-only website mirror under `website/`.

## Website mirror

Static pages and assets come from a pinned monorepo source commit. Installer bootstraps, announcements, client configurations, and the configuration signature are snapshots read from the public website. `website/quicktui-source.json` records the source commit and SHA-256 hashes of those public snapshots.

The mirror includes localized pages, including Simplified Chinese. Repository documentation and code comments remain in English.

The mirror is not a deployment source. Changes here do not flow back to the product source or the live website. GitHub Pages is disabled; use https://quicktui.ai for the live site.

## Releases and monitoring

Download published binaries from [GitHub Releases](https://github.com/dualface/quicktui/releases). The `monitoring/` directory contains local installation checks for the `server2` and `preview` channels. This repository has no GitHub Actions workflows. See [the monitoring guide](monitoring/README.md).

---

## More Projects by the Author

Explore other projects by [dualface](https://dualface.dev/):

- [Kander](https://github.com/dualface/kander): rule-driven multi-agent kanban orchestration, with independent review and delivery gates.
- [Ullage](https://github.com/dualface/ullage-cli): a local daemon and CLI that shows subscription usage for Claude, ChatGPT, Grok, Cursor, and more.
- [ste-zh](https://github.com/dualface/ste-zh): an agent skill that makes agents report results in Chinese by ASD-STE100 principles: conclusion first, fixed status words, explicit verification state.
