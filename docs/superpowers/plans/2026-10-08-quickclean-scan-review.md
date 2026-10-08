# Quickclean Scan & Review Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a read-only scanner (Swift library + `qc` CLI + SwiftUI app) that inventories a macOS 27 machine, attributes every item to an owner, labels it with confidence/risk/explanation, and presents it for review — then ship it as a notarized Alpha 0.0.1.

**Architecture:** `QuickcleanCore` (SwiftPM library) contains an `AppIndex`, six `Scanner`s that emit `RawFinding`s, an `Attributor` and a `Classifier` that turn them into `Finding`s, and a `ScanEngine` that orchestrates and streams `ScanEvent`s. All filesystem/process access goes through `ScanEnvironment` so tests run against fixture trees in a temp directory. `qc` and `Quickclean.app` are thin consumers. Release tooling (script + Claude Code skill) archives, signs with Developer ID, notarizes, staples and packages a DMG.

**Tech Stack:** Swift 6.4 (strict concurrency), SwiftPM, Swift Testing, SwiftUI (macOS 27), Security.framework, CoreServices (MDItem), XcodeGen (`project.yml`), `xcodebuild`, `xcrun notarytool`, `hdiutil`, `gh`.

**Spec:** `docs/superpowers/specs/2026-10-08-quickclean-scan-review-design.md`

## Global Constraints

- Target macOS 27.0, Xcode 27, Swift 6.4, Swift 6 language mode (strict concurrency).
- License: MIT (free and open source). Repo: https://github.com/mrbarkan/quickclean (public).
- `QuickcleanCore` must never write, move or delete: forbidden tokens `removeItem`, `moveItem`, `trashItem`, `createFile`, `write(to:`, `replaceItem`, `copyItem`, `createDirectory`, `unlink(`, `rename(`. Export functions return `Data`/`String`; callers write.
- Non-sandboxed app, hardened runtime, Developer ID Application: David Barkan (L26TPPMPF3); notarytool keychain profile `notarytool`.
- Bundle ID `io.github.mrbarkan.quickclean`; Alpha 0.0.1 → `MARKETING_VERSION=0.0.1`, Info key `QCChannel=alpha`, artifact `Quickclean-0.0.1-alpha.dmg`.
- External commands: absolute path, no shell, 10 s timeout. Never call anything that prompts for admin.
- Never scan `/System`, `/private/var/db`, other volumes; never follow symlinks out of scan roots; never descend into bundles beyond `Contents/Info.plist`, `Contents/_MASReceipt` and code signature.
- Stale threshold 180 days. Default selection = `risk == .safe && confidence == .high && ownerStatus == .orphaned`.

## Review Focus

1. **Unreadable / malformed inputs** (permission-denied folder, corrupt plist, binary plist that isn't a dict) → scan continues, a `ScanIssue` is recorded. Test in Task 7 (Leftovers) and Task 8 (Background).
2. **Symlink pointing outside scan roots** (e.g. `~/Library/Caches/foo → /`) → reported as a finding of size 0 without traversal; sizing must not follow it. Test in Task 12 (SizeCalculator).
3. **Homebrew missing or brew emits garbage / times out** → Dev Tooling still returns non-brew findings plus one issue. Test in Task 10.
4. **Login items cannot be listed without root** → a single informational issue, no admin prompt. Test in Task 8.
5. **Huge directories / hard links** → sizes counted once per inode and computed after the list is complete; list completes first. Test in Task 12.

## File Structure

```
Package.swift
LICENSE, README.md, .gitignore
Sources/QuickcleanCore/
  Model/Finding.swift            enums + Finding, Owner, Evidence, ScanIssue, RawFinding, PresetAttribution
  Environment/ScanEnvironment.swift   ScanEnvironment, CommandRunner, ProcessCommandRunner, BundleInspector, PreferencesReader
  Reference/ReferenceData.swift  StockReference, DefaultsReference, KnownApps, loader
  Resources/stock-macos27.json, defaults-macos27.json, known-apps.json
  Index/AppIndex.swift           InstalledApp, AppIndex, AppIndexBuilder
  Attribution/Identifier.swift   identifier parsing (bundle-like, team prefix, savedState/ByHost suffixes, name normalization)
  Attribution/Attributor.swift
  Classification/Classifier.swift  risk, badges, default selection, title
  Classification/Explainer.swift   explanation text
  Scanners/Scanner.swift          protocol + shared directory listing helper
  Scanners/AppsScanner.swift, LeftoversScanner.swift, BackgroundScanner.swift,
           AddonsScanner.swift, DevToolingScanner.swift, SettingsScanner.swift
  Engine/SizeCalculator.swift
  Engine/ScanEngine.swift         ScanEvent, ScanEngine
  Engine/FullDiskAccess.swift
  Report/Report.swift             Report, JSON + Markdown rendering
Sources/qc/main.swift
Tests/QuickcleanCoreTests/
  Support/Fixture.swift           temp tree builder, StubCommandRunner, StubBundleInspector, StubPreferences
  ModelTests, IdentifierTests, AttributorTests, ClassifierTests, ReferenceTests,
  AppIndexTests, LeftoversScannerTests, BackgroundScannerTests, AddonsScannerTests,
  DevToolingScannerTests, SettingsScannerTests, SizeCalculatorTests,
  EngineGoldenTests, ReadOnlyTests, ReportTests
  Fixtures/expected-report.json
App/project.yml                    XcodeGen spec
App/Quickclean/                    QuickcleanApp.swift, ScanModel.swift, Views/*.swift, Info.plist, Quickclean.entitlements, Assets.xcassets
Scripts/gen-stock-list             (python3, read-only) seeds stock-macos27.json
Scripts/release.sh                 archive → sign → notarize → staple → dmg → notarize → staple
.claude/skills/release/SKILL.md    release skill: asks channel + version with proposal
```

---

### Task 1: Package scaffold, license, model

**Files:**
- Create: `Package.swift`, `LICENSE` (MIT, © 2026 David Barkan), `README.md`, `Sources/QuickcleanCore/Model/Finding.swift`, `Sources/qc/main.swift` (stub), `Tests/QuickcleanCoreTests/ModelTests.swift`

**Interfaces — Produces:**
```swift
public enum Category: String, Codable, Sendable, CaseIterable { case apps, leftovers, background, addons, devTooling, settings }
public enum Kind: String, Codable, Sendable { case app, appSupport, cache, preferences, container, groupContainer, savedState, httpStorage, webkitData, logs, cookies, launchAgent, launchDaemon, privilegedHelper, systemExtension, kext, loginItems, quickLookPlugin, spotlightImporter, preferencePane, inputMethod, font, colorProfile, screenSaver, audioPlugin, internetPlugin, safariExtension, mailBundle, brewFormula, brewCask, brewTap, devCache, devData, dotfile, settingsKey }
public enum OwnerStatus: String, Codable, Sendable { case installed, orphaned, apple, unknown }
public enum Confidence: String, Codable, Sendable, Comparable { case none, low, medium, high }
public enum Risk: String, Codable, Sendable, Comparable { case safe, review, careful, protected }
public enum Badge: String, Codable, Sendable { case broken, stale, running }
public struct Owner: Codable, Sendable, Hashable { bundleID: String?; displayName: String; teamID: String? }
public struct Evidence: Codable, Sendable, Hashable { rule: String; detail: String }
public struct ScanIssue: Codable, Sendable, Hashable { subject: String; reason: String }
public struct Finding: Identifiable, Codable, Sendable, Hashable { id, category, kind, title, paths: [String], size: Int64?, owner: Owner?, ownerStatus, confidence, risk, badges: Set<Badge>, explanation, evidence: [Evidence], modified: Date?, defaultSelected: Bool, protectedReason: String? }
public struct PresetAttribution: Sendable { owner: Owner?; status: OwnerStatus; confidence: Confidence; evidence: Evidence }
public struct RawFinding: Sendable { category, kind, name: String, paths: [URL], identifier: String?, programPath: String?, preset: PresetAttribution?, badges: Set<Badge>, modified: Date?, detail: String?, riskOverride: Risk?, inSystemDomain: Bool, idOverride: String? }
```
Paths are stored as `String` (absolute) in `Finding` for stable JSON.

- [ ] **Step 1: Write failing test** `ModelTests.swift`:
```swift
import Testing, Foundation
@testable import QuickcleanCore
@Test func findingRoundTripsThroughJSON() throws {
    let f = Finding(id: "leftovers:/x", category: .leftovers, kind: .cache, title: "Spotify · Cache",
        paths: ["/x"], size: 10, owner: Owner(bundleID: "com.spotify.client", displayName: "Spotify", teamID: nil),
        ownerStatus: .orphaned, confidence: .high, risk: .safe, badges: [.stale], explanation: "e",
        evidence: [Evidence(rule: "exactBundleID", detail: "d")], modified: Date(timeIntervalSince1970: 0),
        defaultSelected: true, protectedReason: nil)
    let data = try JSONEncoder().encode(f)
    #expect(try JSONDecoder().decode(Finding.self, from: data) == f)
}
@Test func riskAndConfidenceOrder() {
    #expect(Risk.safe < .review && Risk.review < .careful && Risk.careful < .protected)
    #expect(Confidence.none < .low && Confidence.low < .medium && Confidence.medium < .high)
}
```
- [ ] **Step 2:** `swift test` → FAIL (types missing).
- [ ] **Step 3:** Implement `Package.swift` (tools 6.2, platforms `.macOS("27.0")`, products `QuickcleanCore` library + `qc` executable, test target, `resources: [.process("Resources")]`) and `Finding.swift` with the types above (`Comparable` via an `order` Int).
- [ ] **Step 4:** `swift test` → PASS.
- [ ] **Step 5:** Commit `feat: package scaffold and finding model (MIT)`.

### Task 2: Environment, command runner, test fixtures

**Files:** Create `Sources/QuickcleanCore/Environment/ScanEnvironment.swift`, `Tests/QuickcleanCoreTests/Support/Fixture.swift`, `Tests/QuickcleanCoreTests/CommandRunnerTests.swift`

**Interfaces — Produces:**
```swift
public struct CommandResult: Sendable { public let status: Int32; public let stdout: String; public let stderr: String }
public enum CommandError: Error, Sendable { case notFound(String), timedOut(String), launchFailed(String) }
public protocol CommandRunner: Sendable { func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> CommandResult }
public struct ProcessCommandRunner: CommandRunner { public init() }
public struct SignatureInfo: Sendable, Equatable { public var teamID: String?; public var isApple: Bool }
public protocol BundleInspector: Sendable { func signature(of url: URL) -> SignatureInfo; func lastUsed(_ url: URL) -> Date? }
public struct LiveBundleInspector: BundleInspector
public protocol PreferencesReader: Sendable { func values(domain: String) -> [String: Any]? }   // nonisolated(unsafe) not needed: returns fresh dict
public struct PlistPreferencesReader: PreferencesReader { home: URL }  // reads home/Library/Preferences/<domain>.plist; NSGlobalDomain → .GlobalPreferences.plist
public struct CFPreferencesReader: PreferencesReader
public struct ScanEnvironment: Sendable {
    public var home: URL; public var root: URL; public var commands: any CommandRunner
    public var bundles: any BundleInspector; public var preferences: any PreferencesReader
    public var now: Date; public var runningBundleIDs: Set<String>
    public static func live() -> ScanEnvironment
    public func path(_ relative: String) -> URL        // root-relative ("Library/LaunchAgents")
    public func homePath(_ relative: String) -> URL
}
```
Test support produces: `Fixture` (temp dir with `home/` and `root/`, `file(_:contents:)`, `dir(_:)`, `plist(_:_:)`, `app(at:bundleID:name:)`, `symlink(_:to:)`, `setModified(_:daysAgo:)`, `env(...)`), `StubCommandRunner([String: CommandResult])` keyed by `"exe arg1 arg2"`, `StubBundleInspector`, `DictPreferences`.

- [ ] **Step 1: Failing tests:**
```swift
@Test func processRunnerCapturesOutput() async throws {
    let r = try await ProcessCommandRunner().run("/bin/echo", ["hi"], timeout: 5)
    #expect(r.status == 0 && r.stdout == "hi\n")
}
@Test func processRunnerTimesOut() async {
    await #expect(throws: CommandError.self) { try await ProcessCommandRunner().run("/bin/sleep", ["5"], timeout: 0.3) }
}
@Test func processRunnerMissingExecutable() async {
    await #expect(throws: CommandError.self) { try await ProcessCommandRunner().run("/nonexistent/x", [], timeout: 1) }
}
```
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement. `ProcessCommandRunner` uses `Process` with `executableURL`, pipes drained on background threads, a `DispatchSource` timer that calls `terminate()` and resumes with `.timedOut`. `LiveBundleInspector.signature` uses `SecStaticCodeCreateWithPath`, `SecCodeCopySigningInformation` (`kSecCodeInfoTeamIdentifier`), and `SecStaticCodeCheckValidity` with requirement `anchor apple` and flags `kSecCSDoNotValidateExecutable | kSecCSDoNotValidateResources`. `lastUsed` uses `MDItemCreateWithURL` + `kMDItemLastUsedDate`. `ScanEnvironment.live()` uses `/` root, real home, `NSWorkspace.shared.runningApplications` bundle IDs, `CFPreferencesReader`.
- [ ] **Step 4:** Run → PASS. **Step 5:** Commit `feat: scan environment and command runner`.

### Task 3: Reference data

**Files:** Create `Sources/QuickcleanCore/Reference/ReferenceData.swift`, `Resources/stock-macos27.json`, `Resources/defaults-macos27.json`, `Resources/known-apps.json`, `Tests/.../ReferenceTests.swift`

**Interfaces — Produces:**
```swift
public struct StockReference: Codable, Sendable { public var appBundleIDs: Set<String>; public var appleNames: Set<String> /* lowercased */; public var protectedHomePaths: [String]; public func isAppleName(_ s: String) -> Bool }
public enum JSONValue: Codable, Sendable, Hashable { case bool(Bool), number(Double), string(String), null; public init?(any: Any); public var display: String }
public struct DefaultSetting: Codable, Sendable { public var domain: String; public var key: String; public var title: String; public var defaultValue: JSONValue /* .null = absent */; public var note: String? }
public struct KnownApp: Codable, Sendable { public var pattern: String /* prefix match, lowercased */; public var name: String; public var bundleID: String?; public var customization: Bool; public var note: String }
public struct ReferenceData: Sendable { public var stock: StockReference; public var defaults: [DefaultSetting]; public var knownApps: [KnownApp]; public static let bundled: ReferenceData; public func knownApp(for identifier: String) -> KnownApp? }
```
`known-apps.json` seeds: Mousecape (`com.alexzielenski.mousecloak`, `com.alexzielenski.mousecape`, `mousecape`; customization), Cursorcerer, Bartender, Ice (`com.jordanbaird.ice`), Hidden Bar, Adobe (`adobe`, `com.adobe`), Steam (`steam`, `com.valvesoftware`), Google (`google`, `com.google.keystone`, `com.google.googleupdater`), Microsoft AutoUpdate (`com.microsoft.autoupdate`), Zoom (`zoom.us`, `us.zoom`), Docker (`com.docker`), Karabiner (`org.pqrs`; customization), BetterTouchTool (`com.hegenberg`; customization), Witch, uBar, cDock/MacForge (`com.w0lf`; customization), SIMBL/mySIMBL (customization), Logitech (`com.logi`, `logitech`), Spotify, Discord (`discord`, `com.hnc.discord`), Epic (`com.epicgames`), Battle.net (`com.blizzard`), CleanMyMac (`com.macpaw`), Setapp (`com.setapp`).
`defaults-macos27.json` seeds Dock (`autohide=false`, `orientation="bottom"`, `magnification=false`, `show-recents=true`, `mineffect="genie"`, `static-only=false`, `autohide-delay=absent`, `autohide-time-modifier=absent`, `showhidden=absent`, `expose-animation-duration=absent`, `minimize-to-application=false`), Finder (`AppleShowAllFiles=absent`, `ShowPathbar=false`, `ShowStatusBar=false`, `_FXShowPosixPathInTitle=absent`, `FXEnableExtensionChangeWarning=true`, `QuitMenuItem=absent`, `CreateDesktop=absent`, `DisableAllAnimations=absent`), NSGlobalDomain (`AppleShowAllExtensions=false`, `KeyRepeat=absent`, `InitialKeyRepeat=absent`, `ApplePressAndHoldEnabled=absent`, `NSAutomaticSpellingCorrectionEnabled=absent`, `NSWindowResizeTime=absent`, `NSAutomaticWindowAnimationsEnabled=absent`, `AppleInterfaceStyle=absent`), universalaccess (`cursorIsCustomized=absent`, `mouseDriverCursorSize=absent`, `reduceMotion=absent`), screencapture (`location=absent`, `type=absent`, `disable-shadow=absent`), LaunchServices (`LSQuarantine=absent`), `com.apple.desktopservices` (`DSDontWriteNetworkStores=absent`).

- [ ] **Step 1: Failing tests:** bundled reference loads; `knownApp(for: "com.alexzielenski.mousecloak.listener")?.name == "Mousecape"` and `.customization == true`; `JSONValue(any: true) == .bool(true)`, `JSONValue(any: NSNumber(value: 48)) == .number(48)`; `stock.isAppleName("GeoServices")` true when present in the seed; every `DefaultSetting` has non-empty title.
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement (decode with `Bundle.module`; `JSONValue(any:)` distinguishes `CFBoolean` via `CFGetTypeID(n) == CFBooleanGetTypeID()`). **Step 4:** PASS. **Step 5:** Commit.

### Task 4: AppIndex

**Files:** Create `Sources/QuickcleanCore/Index/AppIndex.swift`, `Tests/.../AppIndexTests.swift`

**Interfaces — Produces:**
```swift
public enum AppSource: String, Codable, Sendable { case appStore, homebrew, manual, system }
public struct InstalledApp: Sendable, Hashable { bundleID: String; name: String; version: String?; teamID: String?; isAppleSigned: Bool; source: AppSource; url: URL; lastUsed: Date? }
public struct AppIndex: Sendable {
    public init(apps: [InstalledApp])
    public var apps: [InstalledApp]
    public func app(bundleID: String) -> InstalledApp?          // case-insensitive
    public func apps(teamID: String) -> [InstalledApp]
    public func app(vendorPrefix: String) -> InstalledApp?      // "com.vendor"
    public func app(nameToken: String) -> InstalledApp?          // normalized name equality
    public func app(containing path: String) -> InstalledApp?    // path inside app bundle
}
public enum AppIndexBuilder { public static func build(_ env: ScanEnvironment, caskApps: Set<String>) -> AppIndex }
```
Roots: `root/Applications`, `root/Applications/Utilities`, `home/Applications`, plus one level of non-bundle subfolders of each. Source: `Contents/_MASReceipt/receipt` → appStore; app filename in `caskApps` → homebrew; bundleID in `stock.appBundleIDs` → system; else manual.

- [ ] **Step 1: Failing tests** with fixture apps `root/Applications/Foo.app` (bundle `com.foo.app`), `root/Applications/Games/Bar.app` (`com.bar.game`, `_MASReceipt`), `home/Applications/Baz.app`; stub inspector gives `com.foo.app` team `TEAM123456`: assert `app(bundleID:"COM.FOO.APP")`, `apps(teamID:)`, `app(vendorPrefix:"com.foo")`, `app(nameToken:"foo")`, `app(containing: ".../Foo.app/Contents/MacOS/x")`, Bar source `.appStore`, caskApps `["Baz.app"]` → `.homebrew`; an app bundle missing Info.plist is skipped.
- [ ] **Step 2–4:** Fail → implement → pass. **Step 5:** Commit.

### Task 5: Identifier parsing + Attributor

**Files:** Create `Attribution/Identifier.swift`, `Attribution/Attributor.swift`, tests `IdentifierTests.swift`, `AttributorTests.swift`

**Interfaces — Produces:**
```swift
public enum Identifier {
    public static func isBundleLike(_ s: String) -> Bool          // ≥2 dots or ≥3 reverse-DNS components, tld in known list
    public static func strip(_ name: String) -> String            // removes .plist, .savedState, .binarycookies, ByHost .<UUID>/.<hex>, trailing .plist
    public static func teamPrefix(_ s: String) -> (team: String, rest: String)?   // ^[A-Z0-9]{10}\.
    public static func vendorPrefix(_ bundleID: String) -> String?  // first two components unless shared (com.github, io.github, com.electron, org.chromium)
    public static func normalize(_ name: String) -> String         // lowercase, drop spaces/punct, trailing version digits, ".app"
    public static func appName(fromPath: String) -> String?        // "/Applications/Foo Bar.app/…" → "Foo Bar"
}
public struct Attribution: Sendable { owner: Owner?; status: OwnerStatus; confidence: Confidence; evidence: [Evidence] }
public struct Attributor: Sendable {
    public init(index: AppIndex, reference: ReferenceData, fileExists: @Sendable (String) -> Bool)
    public func attribute(_ raw: RawFinding) -> Attribution
}
```
Rules, in order (first match wins):
1. `raw.preset` → use it.
2. Apple: stripped identifier has prefix `com.apple.` or `stock.isAppleName(identifier)` → `.apple`, high, rule `apple`.
3. `programPath` inside an `.app`: index `app(containing:)` → installed/high `programInsideApp`; else if path doesn't exist → orphaned/high owner = app name from path, rule `programInsideMissingApp`.
4. Team prefix (`TEAMID.rest`): exact rest bundle → installed/high; team in index → installed/medium `teamID`; else orphaned/medium `teamIDNotInstalled`.
5. Bundle-like: exact → installed/high `exactBundleID` (if `isAppleSigned` → `.apple`); known app → installed (if its bundleID or vendor prefix in index) else orphaned, medium `knownApp`; vendor prefix → installed/medium `vendorPrefix`; else orphaned/high `exactBundleIDNotInstalled` (owner display name = known app name or last meaningful component).
6. Non-bundle name: known app → as 5 (medium); `app(nameToken:)` → installed/low `nameToken`; else unknown/none `noMatch`.
Owner status `apple` also when the matched InstalledApp `isAppleSigned`.

- [ ] **Step 1: Failing tests (one per rule)** — identifiers `com.foo.app` → installed/high; `com.foo.helper` → installed/medium; `com.gone.app` → orphaned/high, owner name "Gone"; `com.apple.Safari` → apple; `GeoServices` (apple name) → apple; `TEAM123456.com.foo.shared` → installed/high; `ZZZZZZZZZZ.group.x` → orphaned/medium; programPath `/Applications/Gone.app/Contents/MacOS/g` (missing) → orphaned/high owner "Gone"; `com.alexzielenski.mousecloak.listener` → orphaned/medium owner "Mousecape"; `Foo` → installed/low; `RandomThing` → unknown/none; `Identifier.strip("com.x.y.0F1E2D3C-AAAA-BBBB-CCCC-111122223333.plist") == "com.x.y"`, `strip("com.x.y.savedState") == "com.x.y"`.
- [ ] **Step 2–4:** Fail → implement → pass. **Step 5:** Commit.

### Task 6: Classifier + Explainer

**Files:** Create `Classification/Classifier.swift`, `Classification/Explainer.swift`, test `ClassifierTests.swift`

**Interfaces — Produces:**
```swift
public struct Classifier: Sendable {
    public init(reference: ReferenceData, env: ScanEnvironment)
    public func classify(_ raw: RawFinding, _ a: Attribution) -> Finding
    public func risk(_ raw: RawFinding, _ a: Attribution) -> (Risk, protectedReason: String?)
}
public enum Explainer { public static func explain(_ raw: RawFinding, _ a: Attribution, home: URL) -> String; public static func kindLabel(_ k: Kind) -> String }
```
Risk evaluation order (most restrictive wins):
- **protected**: `a.status == .apple`; `kind == .settingsKey`; any path under `/System`; path equals/under home `Library/Keychains`, `Documents`, `Desktop`, `Pictures/Photos Library.photoslibrary`, `Library/Mail`, `Library/Mobile Documents`, or a protected dotfile (`.ssh`, `.gnupg`, `.zshrc`, `.zprofile`, `.zshenv`, `.bashrc`, `.bash_profile`, `.profile`, `.gitconfig`, `.Trash`, `.CFUserTextEncoding`, `.config`). Reason string set.
- **careful**: kinds `launchAgent, launchDaemon, privilegedHelper, systemExtension, kext, loginItems`; `raw.inSystemDomain` (under `root/Library`); confidence `low`/`none`.
- `raw.riskOverride` if set (used by Dev Tooling: devCache → safe, devData/brew → review).
- **review**: kinds `preferences, appSupport, container, groupContainer, dotfile, brewFormula, brewCask, brewTap, app`; status `installed`.
- **safe**: kinds `cache, logs, savedState, httpStorage, webkitData, cookies` with status `orphaned`.
- fallback **review**.
Badges: union of raw badges, `.stale` if `modified < now − 180d`, `.running` if owner bundleID ∈ `env.runningBundleIDs`.
Title: `"\(owner?.displayName ?? raw.name) · \(kindLabel)"` except `.app` (app name), `.settingsKey`/brew (raw.name).
ID: `"\(category.rawValue):\(paths.first?.path ?? raw.name)"`.
Explanation template: `"<KindLabel> at <~path>. <owner sentence>. <raw.detail>"`; owner sentence: installed → "Belongs to X, which is installed."; orphaned → "Belongs to X, which is no longer installed."; apple → "Part of macOS or an Apple app."; unknown → "Could not identify which app created this." Followed by `" Why: "` + evidence details joined.

- [ ] **Step 1: Failing tests** — table-driven: (cache, orphaned, high) → safe & defaultSelected; (cache, installed, high) → review; (preferences, orphaned, high) → review; (launchAgent, orphaned, high) → careful; (cache, orphaned, low) → careful; (cache, apple) → protected; (devCache with override safe, installed) → safe; `inSystemDomain` cache orphaned → careful; path `~/.ssh` dotfile → protected; settingsKey → protected; stale badge when modified 200 days ago, not at 100; running badge; explanation for orphaned Mousecape agent contains "no longer installed" and "Why:".
- [ ] **Step 2–4:** Fail → implement → pass. **Step 5:** Commit.

### Task 7: Scanner protocol + LeftoversScanner

**Files:** Create `Scanners/Scanner.swift`, `Scanners/LeftoversScanner.swift`, test `LeftoversScannerTests.swift`

**Interfaces — Produces:**
```swift
public struct ScanOutput: Sendable { public var findings: [RawFinding] = []; public var issues: [ScanIssue] = [] }
public protocol Scanner: Sendable { var category: Category { get }; func scan(_ env: ScanEnvironment, index: AppIndex) async -> ScanOutput }
enum Listing { static func children(_ dir: URL, into out: inout ScanOutput) -> [URL]   // skips .DS_Store/.localized; records permission errors as issues; returns [] if missing
               static func modified(_ url: URL) -> Date? ; static func isSymlink(_ url: URL) -> Bool }
public struct LeftoversScanner: Scanner
```
Locations (home and root `Library/`): `Application Support → appSupport`, `Caches → cache`, `Preferences → preferences` (files `*.plist`; also `Preferences/ByHost/*`), `Containers → container`, `Group Containers → groupContainer`, `Saved Application State → savedState`, `HTTPStorages → httpStorage`, `WebKit → webkitData`, `Logs → logs`, `Cookies → cookies`. Skip `Preferences` subfolders other than `ByHost`. `identifier = Identifier.strip(filename)`; `inSystemDomain = true` for root ones.

- [ ] **Step 1: Failing tests** — fixture with `home/Library/Caches/com.spotify.client/`, `home/Library/Preferences/com.spotify.client.plist`, `home/Library/Preferences/ByHost/com.foo.app.0F1E2D3C-AAAA-BBBB-CCCC-111122223333.plist`, `home/Library/Saved Application State/com.gone.app.savedState/`, `root/Library/Application Support/Adobe/`, `.DS_Store` file; an unreadable dir (`chmod 000 home/Library/Logs`) → assert findings kinds/identifiers/inSystemDomain and one `ScanIssue` for Logs; `.DS_Store` ignored. (Restore permissions in test teardown.)
- [ ] **Step 2–4:** Fail → implement → pass. **Step 5:** Commit.

### Task 8: BackgroundScanner

**Files:** Create `Scanners/BackgroundScanner.swift`, test `BackgroundScannerTests.swift`

Sources:
- `home/Library/LaunchAgents`, `root/Library/LaunchAgents` → launchAgent; `root/Library/LaunchDaemons` → launchDaemon. Parse plist (`PropertyListSerialization`): `Label` → identifier (fallback filename), `Program` or `ProgramArguments[0]` → programPath; if programPath set and file missing → badge `.broken`, detail "Its program <path> no longer exists."; `RunAtLoad`/`KeepAlive` → detail "Starts automatically at login/boot.". Malformed plist → finding with identifier from filename + issue.
- `root/Library/PrivilegedHelperTools/*` → privilegedHelper, identifier = filename.
- `root/Library/Extensions/*.kext` → kext, identifier = `CFBundleIdentifier`.
- `/usr/bin/systemextensionsctl list` → systemExtension rows: parse tab-separated lines with ≥6 columns where column 3 is a team ID; bundleID = column 4 before " ("; name = column 5; state = column 6; preset attribution: team in index → installed/medium; bundle vendor in index → installed/medium; else orphaned/medium. Command failure → issue.
- Login items: one issue `ScanIssue(subject: "Login Items", reason: "macOS only lists login items to administrators. Review them in System Settings › General › Login Items & Extensions.")`. No command is run.
- `.running` badge: labels from `/bin/launchctl list` (3rd column) when `Label` matches.

- [ ] **Step 1: Failing tests** — fixture agent `com.alexzielenski.mousecloak.listener.plist` whose ProgramArguments[0] points to `home/Library/Application Support/Mousecape/listener` (missing) → broken + detail; daemon with Program inside `/Applications/Gone.app/...`; malformed plist → issue + finding; stub `systemextensionsctl list` output (copy of real format above) yields 2 systemExtension findings with right bundle IDs; login items issue present exactly once; `launchctl list` stub marks running.
- [ ] **Step 2–4:** Fail → implement → pass. **Step 5:** Commit.

### Task 9: AddonsScanner

**Files:** Create `Scanners/AddonsScanner.swift`, test `AddonsScannerTests.swift`

Locations (home + root `Library/`): `QuickLook → quickLookPlugin`, `Spotlight → spotlightImporter`, `PreferencePanes → preferencePane`, `Input Methods → inputMethod`, `Fonts → font`, `ColorSync/Profiles → colorProfile`, `Screen Savers → screenSaver`, `Audio/Plug-Ins/Components`, `Audio/Plug-Ins/VST`, `Audio/Plug-Ins/VST3`, `Audio/Plug-Ins/HAL → audioPlugin`, `Internet Plug-Ins → internetPlugin`; home-only `Safari/Extensions → safariExtension`, `Mail/Bundles → mailBundle`. Bundles: identifier = `CFBundleIdentifier` from `Contents/Info.plist` (or `Info.plist`), name = `CFBundleName` or filename; files: identifier = filename without extension. Add detail "Changes how macOS looks or behaves." for inputMethod, preferencePane, screenSaver, mailBundle, safariExtension, internetPlugin.

- [ ] **Step 1: Failing tests** — fixture `home/Library/QuickLook/QLMarkdown.qlgenerator` (bundle id `com.toland.qlmarkdown`), `home/Library/Fonts/Inter.ttf`, `root/Library/Audio/Plug-Ins/Components/Foo.component` (bundle id `com.foo.audio`) → kinds, identifiers, inSystemDomain.
- [ ] **Step 2–4.** **Step 5:** Commit.

### Task 10: DevToolingScanner

**Files:** Create `Scanners/DevToolingScanner.swift`, test `DevToolingScannerTests.swift`

**Interfaces — Produces:** `public struct DevToolingScanner: Scanner` and `public static func caskApps(from json: Data) -> Set<String>` (app artifact names, used by AppIndexBuilder via the engine).

- Homebrew: brew = first existing of `root/opt/homebrew/bin/brew`, `root/usr/local/bin/brew`; absent → issue "Homebrew not found" and skip. Run `brew info --json=v2 --installed` (timeout 30 s) and `brew leaves`. Each formula → brewFormula, name = `full_name`, path = `<prefix>/Cellar/<name>`, preset owner `Owner(bundleID:nil, displayName:"Homebrew")`/installed/high; riskOverride `.review` for leaves, `.careful` for dependencies with detail "Needed by other formulae."; detail includes `desc`. Each cask → brewCask path `<prefix>/Caskroom/<token>`, riskOverride `.review`. Taps not `homebrew/core`/`homebrew/cask` from formula/cask `tap` fields → brewTap path `<prefix>/Library/Taps/<user>/homebrew-<repo>`. JSON parse failure / timeout → issue, continue.
- Dev caches (riskOverride `.safe`, kind devCache, preset owner = tool name, installed/high): `Library/Developer/Xcode/DerivedData`, `Library/Developer/Xcode/iOS DeviceSupport`, `Library/Developer/CoreSimulator/Caches`, `Library/Caches/Homebrew`, `.npm/_cacache`, `Library/Caches/pnpm`, `Library/Caches/Yarn`, `Library/Caches/pip`, `.cargo/registry`, `Library/Caches/go-build`, `go/pkg/mod`, `.gradle/caches`, `Library/Caches/CocoaPods`.
- Dev data (riskOverride `.review`, kind devData): `Library/Developer/Xcode/Archives`, `Library/Developer/CoreSimulator/Devices`, `.pyenv/versions`, `.nvm/versions`, `.rbenv/versions`, `.asdf/installs`, `.local/share/mise/installs`, `.rustup/toolchains`, `Library/Containers/com.docker.docker`, `.docker`, `.ollama/models`.
- Dotfiles: top-level `home/.*` not covered above, excluding `.DS_Store`, `.localized`, `.Trash`, `.CFUserTextEncoding` → kind dotfile, identifier = name without leading dot (attribution by name).

- [ ] **Step 1: Failing tests** — stub brew JSON (two formulae: `node` leaf, `abseil` dependency; one cask `iterm2` with `app: ["iTerm.app"]`, one formula from tap `oven-sh/bun`) → kinds, risk overrides, tap finding, `caskApps == ["iTerm.app"]`; missing brew → one issue, dev caches still found; brew returning `"garbage"` → issue; fixture `.npm/_cacache` + `.cursor` dotfile found.
- [ ] **Step 2–4.** **Step 5:** Commit.

### Task 11: SettingsScanner

**Files:** Create `Scanners/SettingsScanner.swift`, test `SettingsScannerTests.swift`

For each `DefaultSetting` grouped by domain, read `env.preferences.values(domain:)`; if key present and (`defaultValue == .null` or `JSONValue(any:) != defaultValue`) → RawFinding kind settingsKey, name = setting title, paths = [prefs plist URL], identifier = domain, preset owner `Owner(bundleID: domain, displayName: "macOS")`/apple/high, detail = `"\(domain) › \(key) is \(current.display); macOS default is \(default display or "not set"). Reset will be available in a future version. \(note)"`. ID uses `"settings:\(domain):\(key)"` — add optional `idOverride: String?` to RawFinding.

- [ ] **Step 1: Failing tests** — `DictPreferences(["com.apple.dock": ["autohide": true, "orientation": "bottom"], "com.apple.universalaccess": ["cursorIsCustomized": true]])` → findings for autohide and cursorIsCustomized only; JSONValue bool vs number distinction holds (`NSNumber(value: true)` vs `1`).
- [ ] **Step 2–4.** **Step 5:** Commit.

### Task 12: AppsScanner + SizeCalculator

**Files:** Create `Scanners/AppsScanner.swift`, `Engine/SizeCalculator.swift`, tests `SizeCalculatorTests.swift` (+ Apps assertions in AppIndexTests)

AppsScanner: one RawFinding per `index.apps` (kind app, identifier bundleID, preset: apple if `isAppleSigned` or source `.system`, else installed/high; detail "Installed from the App Store/Homebrew/manually. Last used <date|never recorded>."; `.stale` badge if lastUsed older than 180 d).
```swift
public actor SizeCalculator {
    public init(roots: [URL])                     // traversal never leaves these roots
    public func size(of paths: [URL]) -> Int64     // allocated size; each inode counted once per calculator; symlinks count 0 and are not followed
}
```
Uses `FileManager.enumerator(at:includingPropertiesForKeys:[.totalFileAllocatedSizeKey, .isSymbolicLinkKey, .fileResourceIdentifierKey], options: [])` (enumerator doesn't follow symlinks; also skip packages? no — sizes include bundle contents).

- [ ] **Step 1: Failing tests** — dir with 2 files (1 MB each) → ≥ 2 MB; hard link to one file in same dir → unchanged size; symlink `→ /` counts 0 and finishes instantly; nonexistent path → 0.
- [ ] **Step 2–4.** **Step 5:** Commit.

### Task 13: ScanEngine, golden test, read-only proofs

**Files:** Create `Engine/ScanEngine.swift`, `Engine/FullDiskAccess.swift`, tests `EngineGoldenTests.swift`, `ReadOnlyTests.swift`, `Fixtures/expected-report.json`

**Interfaces — Produces:**
```swift
public enum ScanEvent: Sendable { case started(Category), finding(Finding), issue(ScanIssue), finished(Category), size(id: String, bytes: Int64), completed }
public struct ScanEngine: Sendable {
    public init(env: ScanEnvironment, reference: ReferenceData = .bundled, categories: Set<Category> = Set(Category.allCases))
    public func events() -> AsyncStream<ScanEvent>     // cancellation-aware
    public func run() async -> (findings: [Finding], issues: [ScanIssue])   // collects, sizes included, sorted by category then id
}
public enum FullDiskAccess { public static func isGranted(home: URL) -> Bool }  // FileHandle(forReadingFrom: home/Library/Application Support/com.apple.TCC/TCC.db)
```
Flow: brew cask apps via DevToolingScanner helper (only if devTooling or apps selected) → `AppIndexBuilder.build` → scanners in `withTaskGroup` → each RawFinding attributed + classified → `.finding`; after all categories finished, sizes computed with bounded concurrency (8) → `.size`; `.completed`. Dedupe: if two findings share an id keep the first.

- [ ] **Step 1: Failing tests:**
  - Golden: fixture Mac (orphaned Mousecape agent + Application Support folder, Adobe leftovers under root Library, `com.spotify.client` cache with no Spotify, installed `Foo.app` with its prefs, brew stub with leaf `node`, dock autohide=true, `home/Documents/` present, `.ssh`) → `run()` → JSON-encode findings minus volatile fields (size, modified, paths prefixed by fixture root replaced with `$HOME`/`$ROOT`) → equals `Fixtures/expected-report.json` (generated on first green run, reviewed by hand, then committed).
  - Expected highlights asserted explicitly too: Mousecape agent `ownerStatus == .orphaned`, `risk == .careful`, badges ⊇ [.broken]; Spotify cache `defaultSelected == true`; Foo prefs `.installed`/`.review`; no finding with `defaultSelected` and `risk != .safe`.
  - Read-only #1: hash (relative path, size, mtime, mode) of whole fixture before/after `run()` equal.
  - Read-only #2: read every `.swift` under `Sources/QuickcleanCore` (located via `#filePath`) and assert none contains the forbidden tokens from Global Constraints.
- [ ] **Step 2–4.** **Step 5:** Commit `feat: scan engine with golden and read-only tests`.

### Task 14: Report export + `qc` CLI

**Files:** Create `Report/Report.swift`, `Sources/qc/main.swift`, test `ReportTests.swift`

```swift
public struct Report: Codable, Sendable { public var tool = "quickclean"; public var version: String; public var generatedAt: Date; public var findings: [Finding]; public var issues: [ScanIssue]
    public func json() throws -> Data          // pretty, sorted keys, ISO8601 dates
    public func markdown() -> String           // per-category table: Title | Owner | Status | Risk | Confidence | Size, then Issues
}
public enum ByteFormat { public static func string(_ bytes: Int64?) -> String }
```
CLI: `qc scan [--category apps|leftovers|background|addons|devTooling|settings]... [--json] [--markdown]` — default prints a human table grouped by category with totals and a "Customizations still active" section (findings whose known app has `customization` or kind in inputMethod/preferencePane/… with status ≠ apple); `qc --version`. Exits 0; warns on stderr when Full Disk Access is missing. Writing to stdout only.

- [ ] **Step 1: Failing tests** — markdown contains category headers and "Issues"; JSON decodes back to Report; `ByteFormat.string(1_500_000) == "1.5 MB"`.
- [ ] **Step 2–4.** Then manual: `swift run qc scan --category settings`. **Step 5:** Commit.

### Task 15: SwiftUI app

**Files:** Create `App/project.yml`, `App/Quickclean/QuickcleanApp.swift`, `ScanModel.swift`, `Views/SidebarView.swift`, `Views/FindingsTable.swift`, `Views/InspectorView.swift`, `Views/OverviewView.swift`, `Views/OnboardingView.swift`, `Views/Badges.swift`, `Info.plist`, `Quickclean.entitlements` (empty dict — non-sandboxed), `Assets.xcassets` (AppIcon)

`project.yml`: target `Quickclean` (application, macOS 27.0), local package dependency `..` product `QuickcleanCore`, `ENABLE_HARDENED_RUNTIME=YES`, `CODE_SIGN_STYLE=Manual` for Release with `Developer ID Application`, `DEVELOPMENT_TEAM=L26TPPMPF3`, `PRODUCT_BUNDLE_IDENTIFIER=io.github.mrbarkan.quickclean`, `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` from settings, Info key `QCChannel = $(QC_CHANNEL)`.

`ScanModel` (`@MainActor @Observable`): `findings: [String: Finding]`, `order: [String]`, `issues`, `progress: [Category: Bool]`, `selected: Set<String>` (seeded from defaultSelected; protected never insertable), `filters` (status, risk, confidence, showStock=false, search), `groupByOwner`, `hasFullDiskAccess`, `scan()`, `cancel()`, `visible(for: SidebarItem) -> [Finding]`, `groups(for:) -> [(owner: String, items: [Finding])]`, `overview` aggregates (per-category count/size, orphan size, customizations, top orphan owners), `exportJSON() -> Data`, `exportMarkdown() -> String`.

Views: `NavigationSplitView` sidebar (Overview + categories with count/size and a `ProgressView` while scanning); content `Table` with columns checkbox (`Toggle` disabled for protected, lock icon), icon+title, owner, badges, risk, confidence, size, modified; sortable via `KeyPathComparator`; `.searchable`; context menu Reveal in Finder (`NSWorkspace.activateFileViewerSelecting`), Copy Path, Copy Explanation; Space → `.quickLookPreview`; `.inspector` with explanation, evidence disclosure, paths, protected reason. Grouped mode uses `Section` rows per owner. Toolbar: Scan/Cancel, Group by owner toggle, filter menu, Export menu (`fileExporter`). Onboarding sheet when FDA missing with button opening `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`; re-check on `NSApplication.didBecomeActiveNotification`; persistent banner when missing.

- [ ] **Step 1:** `xcodegen generate --spec App/project.yml` then `xcodebuild -project App/Quickclean.xcodeproj -scheme Quickclean -configuration Debug build` → must succeed.
- [ ] **Step 2:** Launch app, run a scan, verify sidebar counts, table, inspector, export (screenshot check).
- [ ] **Step 3:** Commit `feat: SwiftUI review app`.

### Task 16: Stock list generator + real-machine review

**Files:** Create `Scripts/gen-stock-list`, modify `Resources/stock-macos27.json`

Script (python3, read-only, `-I`): collects lowercased basenames (without extension) of `/System/Library/{Frameworks,PrivateFrameworks,CoreServices}/*`, `/System/Library/LaunchAgents|LaunchDaemons/*` labels and program basenames, `/usr/libexec/*`, `/usr/sbin/*`, `/System/Applications/**/*.app` names and bundle IDs, `/System/Cryptexes/App/System/Applications/*.app` → `appleNames`; `appBundleIDs` = bundle IDs of `/System/Applications/**` and `/Applications/Safari.app`; merges a hand-maintained `manualAppleNames` list (e.g. `crashreporter`, `knowledge`, `addressbook`, `callhistorydb`, `clouddocs`, `apple`, `icloud`, `familycircle`, `syncservices`, `mobilesync`, `dock`, `homekit`, `sharedfilelist`). Writes JSON to stdout.

- [ ] **Step 1:** `python3 -I Scripts/gen-stock-list > Sources/QuickcleanCore/Resources/stock-macos27.json`; rebuild; `swift test` green.
- [ ] **Step 2:** `swift run qc scan --json > scratch/report.json`; review unknown/orphaned items with high counts; add missed Apple names / known apps; repeat until the Overview reads correctly (no Apple items orphaned; Mousecape-like customizations surfaced).
- [ ] **Step 3:** Commit `feat: stock reference for macOS 27`.

### Task 17: Release tooling + skill + Alpha 0.0.1

**Files:** Create `Scripts/release.sh`, `Scripts/ExportOptions.plist`, `.claude/skills/release/SKILL.md`, `CHANGELOG.md`

`release.sh <version> <channel>` (channel ∈ alpha|beta|rc|stable):
1. Refuse on dirty tree. `xcodegen generate`. Build number = `git rev-list --count HEAD`.
2. `xcodebuild archive -scheme Quickclean -configuration Release MARKETING_VERSION=<v> CURRENT_PROJECT_VERSION=<n> QC_CHANNEL=<c>` → `build/Quickclean.xcarchive`; `xcodebuild -exportArchive -exportOptionsPlist Scripts/ExportOptions.plist` (method `developer-id`, signingStyle manual, team L26TPPMPF3).
3. Verify `codesign --verify --deep --strict` and hardened runtime flag.
4. `ditto -c -k --keepParent Quickclean.app Quickclean.zip`; `xcrun notarytool submit --keychain-profile notarytool --wait`; `xcrun stapler staple Quickclean.app`.
5. `hdiutil create -volname Quickclean -srcfolder <staging with app + /Applications symlink> -format UDZO Quickclean-<v>-<c>.dmg`; `codesign --sign "Developer ID Application: David Barkan (L26TPPMPF3)" --timestamp` the DMG; notarize + staple DMG; `spctl -a -t open --context context:primary-signature -v` DMG and `spctl -a -t exec -v` app.
6. Print artifact path + SHA-256. Tag `v<v>-<c>` (or `v<v>` for stable).

Skill: asks for channel and version via AskUserQuestion with a proposal computed from the latest `v*` tag (next patch in same channel; promote to next channel; next minor), then runs tests, commits pending changes (asks for message proposal), pushes, runs `release.sh`, pushes the tag, and offers to publish a GitHub pre-release/release with the DMG via `gh release create`.

- [ ] **Step 1:** Write files; `bash -n Scripts/release.sh`.
- [ ] **Step 2:** `swift test` green; commit; push.
- [ ] **Step 3:** `Scripts/release.sh 0.0.1 alpha` → notarized, stapled `Quickclean-0.0.1-alpha.dmg`; verify with `spctl` and `stapler validate`.
- [ ] **Step 4:** Push tag `v0.0.1-alpha`.
