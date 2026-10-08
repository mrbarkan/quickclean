# Changelog

## 0.0.1 (Alpha) — 2026-10-08

First public build. **Read-only**: Quickclean scans and explains; it never changes or deletes anything.

### Added
- Scans six categories: Apps, Leftovers (the standard `~/Library` and `/Library` data folders), Background (launch agents and daemons, privileged helpers, kernel and system extensions), Add-ons (Quick Look, Spotlight, settings panes, input methods, fonts, color profiles, screen savers, audio, Safari and Mail plug-ins), Dev Tooling (Homebrew, developer caches, toolchains, dotfiles) and Settings (macOS settings changed from their defaults).
- Every item shows its owner, whether that owner is still installed (Installed, Orphaned, Apple, Unidentified), a confidence level, a risk level (Safe, Review, Careful, Protected), Broken, Stale and Running badges, and a plain-language explanation with the evidence behind it.
- Overview: totals per category, space used by orphaned leftovers, customizations still active, changed macOS settings, and the apps that left the most behind.
- Group by owner, filters, search, Quick Look, Reveal in Finder, JSON and Markdown export.
- `qc` command-line tool: `qc scan [--category …] [--json | --markdown]`.
- Full Disk Access onboarding.
