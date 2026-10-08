# Quickclean

A small, native macOS 27 app that inventories everything you've added to your Mac — apps, leftovers from old uninstalls, background agents, add-ons, Homebrew and dev tooling, and customized system settings — and explains what each item is, who owns it, and how risky it would be to remove.

**Status: Alpha.** This version is **read-only**: it scans and lets you review. Safe removal (with restore) and reset-to-defaults come in later versions.

Free and open source under the MIT license.

## Build

```sh
swift test                 # engine tests
swift run qc scan          # command-line scan
xcodegen generate --spec App/project.yml && open App/Quickclean.xcodeproj
```

Quickclean needs **Full Disk Access** (System Settings › Privacy & Security › Full Disk Access) to see most of `~/Library`.
