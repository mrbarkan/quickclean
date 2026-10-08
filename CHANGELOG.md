# Changelog

## 0.0.2 (Alpha) — 2026-10-08

Still **read-only**. This release was checked against a real, heavily used Mac by four independent audits.

### Added
- **System Changes** category: installer receipts (with a check of whether their files still exist), default apps and URL handlers, command-line tools in `/usr/local` (broken links flagged), shared frameworks and Java runtimes, third-party app extensions registered with macOS, and `/etc` entries or `hosts` edits a clean install doesn't have.
- Wallpapers that use an image inside an app (theming apps such as RetroMac) or a file that no longer exists.
- Background jobs that apps register without a plist file (modern login items and updaters).
- More add-on locations: file system plug-ins, camera plug-ins, Quick Actions and Automator actions; Application Scripts and `/Users/Shared` as leftovers.
- Homebrew: formulae `brew info` doesn't report, every tap, dependencies nothing needs any more, and casks whose app was deleted.
- Dev tooling: Gradle, `~/.cache` and the Android SDK.
- Settings: hot corners, trackpad swipe and scroll direction, Stage Manager, window tiling margins, click-to-show-desktop and screenshot click display.
- Known apps for RetroMac and Lickable Menu Bar (customizations), VS Code, Edge, Teams, Premiere, Gemini, Claude Code, Cursor, AnyDesk and more.

### Fixed
- Data of installed software no longer shows as orphaned: programs that still exist, extensions and helpers inside apps, containers (attributed by the app macOS recorded as their creator), Shortcuts and printing data, and plug-ins installed without an app.
- Leftovers of removed apps are no longer credited to another app from the same developer.
- Third-party folders with generic names ("Caches", "Purge", "Profiles") are no longer hidden as Apple's.
- "Running" means an actual live process, including system daemons; background items no longer inherit the owner app's state or an install-date "stale" badge.
- Apps nested deeper in Applications (Creative Cloud) and launchers without a bundle ID are listed.
- Settings compare against real macOS defaults (no more false "Pointer: size" warning), and automatic dark mode isn't flagged.

## 0.0.1 (Alpha) — 2026-10-08

First public build. **Read-only**: Quickclean scans and explains; it never changes or deletes anything.

### Added
- Scans six categories: Apps, Leftovers (the standard `~/Library` and `/Library` data folders), Background (launch agents and daemons, privileged helpers, kernel and system extensions), Add-ons (Quick Look, Spotlight, settings panes, input methods, fonts, color profiles, screen savers, audio, Safari and Mail plug-ins), Dev Tooling (Homebrew, developer caches, toolchains, dotfiles) and Settings (macOS settings changed from their defaults).
- Every item shows its owner, whether that owner is still installed (Installed, Orphaned, Apple, Unidentified), a confidence level, a risk level (Safe, Review, Careful, Protected), Broken, Stale and Running badges, and a plain-language explanation with the evidence behind it.
- Overview: totals per category, space used by orphaned leftovers, customizations still active, changed macOS settings, and the apps that left the most behind.
- Group by owner, filters, search, Quick Look, Reveal in Finder, JSON and Markdown export.
- `qc` command-line tool: `qc scan [--category …] [--json | --markdown]`.
- Full Disk Access onboarding.
