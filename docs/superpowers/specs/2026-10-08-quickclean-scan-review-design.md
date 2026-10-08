# Quickclean — Sub-project 1: Scan & Review (Design)

Date: 2026-10-08
Status: Approved in conversation, pending written-spec review

## 1. Purpose

The user is a power user who installs many Homebrew packages, apps, games, and dev tools. Over time the Mac accumulates leftovers (even after AppCleaner / Purge) and lingering customizations (e.g. a theming app's cursor helper that still replaces the beachball). Quickclean is a native macOS 27 app that inventories the system and helps return it to a "freshly installed" feel — safely, with clear toggles, and with every item explained.

Quickclean is decomposed into three sub-projects, each with its own spec → plan → build cycle:

1. **Scan & Review (this spec)** — read-only inventory, attribution, classification, review UI, CLI, export.
2. **Safe Removal** — quarantine selected items with restore + log; privileged helper for admin locations.
3. **Reset to Defaults** — restore look-and-feel and system settings (cursor, Dock, Finder, menu bar, input, etc.).

### Success criteria (this sub-project)

- One scan groups everything on the machine into: Apps, Leftovers, Background, Add-ons, Dev Tooling, Settings.
- Every finding shows its owner, owner status, confidence, risk, size, and a plain-language explanation with evidence.
- Orphaned items (owner no longer installed) are clearly identified; active customizations (e.g. a cursor helper) are surfaced on the Overview.
- The engine is provably read-only (test + build check).
- Full scan completes in < 30 s on a heavily used machine (sizes may finish lazily after).

### Assumptions

- Personal use, not Mac App Store. Non-sandboxed, Developer ID / local signing, requires Full Disk Access.
- Runs as the logged-in user. No admin escalation in this sub-project.
- Target: macOS 27, Xcode 27, Swift 6.4 (strict concurrency).

## 2. Architecture

```
Quickclean/
├─ Package.swift
├─ Sources/
│  ├─ QuickcleanCore/      library — all scanning/attribution/classification; read-only
│  │  └─ Resources/        stock-macos27.json, defaults-macos27.json, known-apps.json
│  └─ qc/                  CLI executable: qc scan [--category <c>]... [--json]
├─ Tests/QuickcleanCoreTests/
├─ App/Quickclean.xcodeproj  SwiftUI app target depending on QuickcleanCore (local package)
└─ Scripts/gen-stock-list    builds initial stock-macos27.json from this machine
```

### Scan pipeline

1. **AppIndex** — catalogs installed apps from `/Applications`, `/Applications/Utilities`, `~/Applications` (and one level of subfolders). Per app: bundle ID, team ID, name, version, Apple-signed flag (via `SecStaticCode`), source (App Store receipt / Homebrew cask / manual), last-used date (Spotlight `kMDItemLastUsedDate`, if available).
2. **Scanners** (run concurrently in a `TaskGroup`), each conforming to:
   ```swift
   protocol Scanner: Sendable {
       var category: Category { get }
       func scan(_ env: ScanEnvironment, index: AppIndex) -> AsyncThrowingStream<RawFinding, Error>
   }
   ```
   - **AppsScanner** — one finding per installed app.
   - **LeftoversScanner** — in both `~/Library` and `/Library`: `Application Support`, `Caches`, `Preferences`, `Containers`, `Group Containers`, `Saved Application State`, `HTTPStorages`, `WebKit`, `Logs`, `Cookies`.
   - **BackgroundScanner** — `~/Library/LaunchAgents`, `/Library/LaunchAgents`, `/Library/LaunchDaemons`, `/Library/PrivilegedHelperTools`, login/background items (`sfltool dumpbtm`), system extensions (`systemextensionsctl list`), kexts (`/Library/Extensions`).
   - **AddonsScanner** — Quick Look plugins, Spotlight importers, PreferencePanes, Input Methods, Fonts, ColorSync Profiles, Screen Savers, Audio plug-ins (Components, VST, VST3, HAL), Internet Plug-Ins, Safari/Mail extensions — in both user and `/Library` domains.
   - **DevToolingScanner** — Homebrew (`brew info --json=v2 --installed`, `brew leaves`, taps), `~/Library/Developer/Xcode/DerivedData`, `Archives`, `iOS DeviceSupport`, CoreSimulator devices, npm/pnpm/yarn/pip/cargo/go caches, version managers (pyenv, nvm, rbenv, asdf, mise, rustup), Docker data, top-level dotfiles in `~`.
   - **SettingsScanner** — for tracked preference domains (`com.apple.dock`, `com.apple.finder`, `NSGlobalDomain`, `com.apple.menuextra.*`, `com.apple.universalaccess`, `com.apple.AppleMultitouchTrackpad`, `com.apple.screencapture`, etc.), compares current values against `defaults-macos27.json` and emits one finding per non-default key.
3. **Attributor** — assigns owner + owner status + confidence (§3).
4. **Classifier** — assigns provenance (stock/added), risk, badges, explanation (§3).

### Finding model

```swift
struct Finding: Identifiable, Codable, Sendable {
    let id: String               // stable: category + canonical primary path (or domain/key)
    let category: Category       // apps, leftovers, background, addons, devTooling, settings
    let kind: Kind               // e.g. cache, preferences, launchAgent, quickLookPlugin, brewFormula, defaultsKey
    let title: String            // human-readable
    let paths: [URL]
    var size: Int64?             // allocated bytes, nil until computed
    let owner: Owner?            // bundleID, displayName, teamID
    let ownerStatus: OwnerStatus // installed, orphaned, apple, unknown
    let confidence: Confidence   // high, medium, low, none
    let risk: Risk               // safe, review, careful, protected
    let badges: Set<Badge>       // broken, stale, running
    let explanation: String
    let evidence: [Evidence]     // rule that matched + detail
    let modified: Date?
    let defaultSelected: Bool
}
```

`ScanIssue` (path/command, reason) is collected alongside findings.

### Reference data (bundled JSON, hand-editable)

- `stock-macos27.json` — paths, bundle IDs, launchd labels, and preference domains that ship with a clean macOS 27 install.
- `defaults-macos27.json` — default values for each tracked settings key.
- `known-apps.json` — patterns for hard-to-attribute third-party items (e.g. `com.alexzielenski.mousecloak.*` → Mousecape, cursor customization; vendor folders not named by bundle ID such as `Adobe`, `Steam`).

### Read-only guarantee

`QuickcleanCore` has no API that writes, moves, or deletes. Enforced by tests (§5).

## 3. Attribution & classification

### Attribution rules (strongest first; first match wins)

| Confidence | Rule |
|---|---|
| High | Exact bundle ID: item named `com.vendor.app[.plist]`, container ID, group container `TEAMID.group.*`; launchd `Program`/`ProgramArguments[0]` resolves inside a known app bundle; BTM entry's associated bundle ID; Homebrew receipt |
| Medium | Same team ID as an installed (or known) app; bundle-ID prefix match (`com.vendor.*`); launchd label prefix match; `known-apps.json` pattern |
| Low | Normalized name-token match only (case/space/version-suffix insensitive) |
| None | Nothing matched → owner status `unknown`, shown as "Unidentified" |

### Owner status

- `installed` — owner present in AppIndex.
- `orphaned` — owner identified but not installed.
- `apple` — matches stock reference or Apple signature / `com.apple.` prefix.
- `unknown` — no owner.

### Badges

- `broken` — launchd job / login item whose executable does not exist.
- `stale` — not modified in > 180 days.
- `running` — app is running or launchd job is loaded.

### Risk

- **safe** — orphaned Caches, Logs, Saved Application State, HTTPStorages, WebKit; regenerable dev caches (DerivedData, npm/pip/cargo/go caches).
- **review** — orphaned Preferences / Application Support / Containers (may hold licenses, saves); any item of an installed app; Homebrew leaves; dotfiles.
- **careful** — launch agents/daemons, privileged helpers, system extensions, kexts, any `/Library` item requiring admin, any finding with `low` confidence.
- **protected** — not selectable: Apple stock items, anything under `/System`, Keychains, `~/Documents`, `~/Desktop`, Photos/Mail libraries, iCloud Drive. Non-default Apple settings appear under Settings for the future reset tool but are not removable.

Precedence: protected > careful > review > safe (the most restrictive applicable rule wins).

### Default selection

`defaultSelected = risk == .safe && confidence == .high && ownerStatus == .orphaned`. All other findings start unchecked. Selection is held in the UI and exported; it has no effect on disk in this sub-project.

### Explanations

Generated from templates per `kind` + evidence, e.g.:

> **Mousecape cursor helper** · Orphaned · Careful · High
> Launch agent `com.alexzielenski.mousecloak.listener` in ~/Library/LaunchAgents. Runs `…/Mousecape/…`, which no longer exists. Re-applies custom cursors at every login. *Why:* label matches known Mousecape pattern; Mousecape is not installed.

### Sizing

Allocated size (`totalFileAllocatedSizeKey`), computed per directory lazily and concurrently. Hard links / APFS clones counted once per scan by inode.

## 4. UI (SwiftUI, macOS 27)

Standard system controls only.

- **NavigationSplitView**
  - Sidebar: Overview · Apps · Leftovers · Background · Add-ons · Dev Tooling · Settings — each with count and total size; per-scanner progress while scanning.
  - Content: `Table` with columns — checkbox, icon + title, owner, status badges, risk, confidence, size, modified. Sortable; ⌘F search; Space = Quick Look; context menu: Reveal in Finder, Copy Path, Copy Explanation.
  - Inspector: explanation, expandable evidence, all paths, owner app info. Protected items show a lock and the reason.
- **Overview**: totals per category, total reclaimable orphan size, **"Customizations still active"** card (background items and add-ons that alter look/behavior: cursor helpers, menu bar mods, input methods, Finder extensions), **"Top orphan owners"** list.
- **Group by owner** toolbar toggle: groups findings per owner app.
- **Filters**: owner status, risk, confidence, "Show stock items" (off by default).
- **Export**: JSON report (same schema as `qc scan --json`) and Markdown summary.
- **Onboarding**: detect Full Disk Access by attempting to read a TCC-protected path; explain why; button opens the Privacy & Security → Full Disk Access pane; re-check on app activation. Without FDA, scans still run with a persistent "results incomplete" banner.
- Results stream in as scanners report; scan is cancellable.

## 5. Errors, permissions, performance, testing

### Errors

- All per-path and per-command problems become `ScanIssue`s, listed in an Issues footer. Never fatal.
- External commands: launched via `Process` with absolute paths, no shell, 10 s timeout; parse failures → issue.
- Homebrew: look for `/opt/homebrew/bin/brew`, then `/usr/local/bin/brew`; absent → skip with note.

### Permissions

Runs as the user with FDA; no admin. Root-only paths → issue, never escalated.

### Traversal safety

- Never follow symlinks outside the scan roots.
- Do not descend into bundles beyond `Info.plist` and code signature.
- Never scan `/System`, `/private/var/db`, or mounted volumes other than the boot volume's data roots listed above.

### Performance

Scanners run in parallel; sizes computed lazily with bounded concurrency. Target < 30 s for the list to be complete on a busy machine.

### Testing

- **ScanEnvironment** injection: `homeURL`, `rootURL`, `CommandRunner` protocol, `Clock`. Tests build fixture trees in a temp directory and stub `brew`, `sfltool`, `systemextensionsctl` output.
- **Unit tests** per attribution rule and for every row of the risk / confidence tables, plus precedence.
- **Golden test**: a fixture "Mac" (orphaned Mousecape agent, Adobe leftovers, a stray brew leaf, a changed Dock key, a protected Documents folder) scanned → compared against `expected-report.json`.
- **Read-only proofs**:
  1. Hash the fixture tree (paths, sizes, mtimes) before and after a full scan; must be identical.
  2. Build/test check that greps `Sources/QuickcleanCore` for write/move/delete APIs (`removeItem`, `moveItem`, `trashItem`, `createFile`, `write(to:`, `replaceItem`, `copyItem`, `createDirectory`, `unlink`, `rename`) and fails if any appear.
- **Real-machine check**: run `qc scan --json` on the user's Mac and review labels together.

### Reference data generation

`Scripts/gen-stock-list` enumerates Apple-signed apps, `com.apple.*` launchd labels, preference domains, and Apple-created Library folders on this machine to seed `stock-macos27.json`; the result is reviewed by hand before committing.

## 6. Out of scope (later sub-projects)

Deletion / quarantine / restore, resetting defaults, privileged helper and admin actions, scheduled scans, menu bar extra.
