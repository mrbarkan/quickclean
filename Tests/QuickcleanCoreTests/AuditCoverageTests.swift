import Foundation
import Testing
@testable import QuickcleanCore

/// Apps, dev tooling, settings and add-on regressions from the real-data audit.

// MARK: Apps

@Test func appsNestedTwoFoldersDownAreIndexed() throws {
    let fx = try Fixture()
    try fx.bundle("root/Applications/Utilities/Adobe Creative Cloud/ACC/Creative Cloud.app", id: "com.adobe.acc.AdobeCreativeCloud", name: "Creative Cloud")
    try fx.bundle("root/Applications/Utilities/Adobe Creative Cloud/ACC/Creative Cloud.app/Contents/Frameworks/Inner.framework", id: "com.inner")
    let index = AppIndexBuilder.build(fx.env(), reference: .bundled, caskApps: [])
    #expect(index.apps.map(\.bundleID) == ["com.adobe.acc.AdobeCreativeCloud"])
}

@Test func appsWithoutBundleIDAreStillListed() throws {
    let fx = try Fixture()
    try fx.plist("home/Applications/Hades.app/Contents/Info.plist", ["CFBundleName": "Hades"])
    let index = AppIndexBuilder.build(fx.env(), reference: .bundled, caskApps: [])
    #expect(index.apps.map(\.name) == ["Hades"])
    #expect(index.app(bundleID: "com.anything") == nil)
}

// MARK: Dev tooling

private let brewInfo = """
{"formulae": [
  {"name": "libnghttp3", "full_name": "libnghttp3", "tap": "homebrew/core", "desc": "HTTP/3 library",
   "installed": [{"version": "1.0", "installed_on_request": false}]}],
 "casks": [{"token": "linearmouse", "tap": "homebrew/cask", "artifacts": [{"app": ["LinearMouse.app"]}]}]}
"""

private func brewScan(_ fx: Fixture) async throws -> ScanOutput {
    let brew = try fx.file("root/opt/homebrew/bin/brew", "#!/bin/sh").path
    try fx.dir("root/opt/homebrew/Cellar/libnghttp3/1.0")
    try fx.dir("root/opt/homebrew/Cellar/stripe/1.30")
    try fx.dir("root/opt/homebrew/Library/Taps/stripe/homebrew-stripe-cli")
    try fx.dir("root/opt/homebrew/Library/Taps/unused/homebrew-tools")
    let env = fx.env(commands: ["\(brew) info --json=v2 --installed": .ok(brewInfo), "\(brew) leaves": .ok("libnghttp3\n")])
    return await DevToolingScanner().scan(env, index: AppIndex(apps: []))
}

@Test func leftoverDependencyIsCalledOut() async throws {
    let fx = try Fixture()
    let f = try #require(try await brewScan(fx).findings.first { $0.name == "libnghttp3" })
    #expect(f.detail?.contains("installed as a dependency") == true)
}

@Test func cellarFormulaMissingFromBrewInfoIsListed() async throws {
    let fx = try Fixture()
    #expect(try await brewScan(fx).findings.contains { $0.kind == .brewFormula && $0.name == "stripe" })
}

@Test func allTapsAreListed() async throws {
    let fx = try Fixture()
    let taps = Set(try await brewScan(fx).findings.filter { $0.kind == .brewTap }.map(\.name))
    #expect(taps == ["stripe/stripe-cli", "unused/tools"])
}

@Test func caskWhoseAppIsGoneIsBroken() async throws {
    let fx = try Fixture()
    let f = try #require(try await brewScan(fx).findings.first { $0.name == "linearmouse" })
    #expect(f.badges.contains(.broken))
}

@Test func devFoldersAreReportedWhole() async throws {
    let fx = try Fixture()
    try fx.dir("home/.gradle/wrapper/dists")
    try fx.dir("home/Library/Android/sdk/platforms")
    try fx.dir("home/.cache/codex-runtimes")
    let out = await DevToolingScanner().scan(fx.env(), index: AppIndex(apps: []))
    let names = Set(out.findings.map(\.name))
    #expect(names.isSuperset(of: ["Gradle caches and wrappers", "Android SDK", "Tool caches (~/.cache)"]))
    #expect(!out.findings.contains { $0.kind == .dotfile && ($0.name == ".gradle" || $0.name == ".cache") })
}

// MARK: Settings

private func settings(_ prefs: [String: [String: Any]]) async throws -> [RawFinding] {
    let fx = try Fixture()
    return await SettingsScanner().scan(fx.env(preferences: prefs), index: AppIndex(apps: [])).findings
}

@Test func stockValuesWrittenExplicitlyAreNotFlagged() async throws {
    let found = try await settings([
        "com.apple.universalaccess": ["mouseDriverCursorSize": 1.0, "reduceMotion": false, "cursorIsCustomized": 0],
        "com.apple.finder": ["CreateDesktop": true],
        "com.apple.dock": ["autohide": 0],
    ])
    #expect(found.isEmpty)
}

@Test func automaticAppearanceDoesNotFlagDarkMode() async throws {
    let found = try await settings(["NSGlobalDomain": ["AppleInterfaceStyle": "Dark", "AppleInterfaceStyleSwitchesAutomatically": true]])
    #expect(found.isEmpty)
    let manual = try await settings(["NSGlobalDomain": ["AppleInterfaceStyle": "Dark"]])
    #expect(manual.count == 1)
}

@Test func hotCornersAreTracked() async throws {
    let found = try await settings(["com.apple.dock": ["wvous-br-corner": 14, "wvous-tl-corner": 4]])
    #expect(found.map(\.idOverride) == ["settings:com.apple.dock:wvous-tl-corner"])
}

// MARK: Add-ons

@Test func moreAddonFoldersAreScanned() async throws {
    let fx = try Fixture()
    try fx.bundle("root/Library/Filesystems/ufsd_NTFS.fs", id: "com.paragon-software.filesystems.ntfs")
    try fx.bundle("root/Library/CoreMediaIO/Plug-Ins/DAL/LUMIXWebcam.plugin", id: "com.panasonic.lumixwebcam")
    try fx.bundle("home/Library/Services/Convert.workflow", id: "com.me.convert")
    try fx.dir("home/Library/Spotlight/ExtensionsCache")
    let out = await AddonsScanner().scan(fx.env(), index: AppIndex(apps: []))
    let kinds = Dictionary(out.findings.map { ($0.identifier ?? "", $0.kind) }, uniquingKeysWith: { a, _ in a })
    #expect(kinds["com.paragon-software.filesystems.ntfs"] == .fileSystem)
    #expect(kinds["com.panasonic.lumixwebcam"] == .cameraPlugin)
    #expect(kinds["com.me.convert"] == .service)
    #expect(kinds["ExtensionsCache"] == nil)
}

@Test func applicationScriptsAreLeftovers() async throws {
    let fx = try Fixture()
    try fx.dir("home/Library/Application Scripts/com.ibluebox.aqua-menu-bar")
    let out = await LeftoversScanner().scan(fx.env(), index: AppIndex(apps: []))
    #expect(out.findings.first { $0.identifier == "com.ibluebox.aqua-menu-bar" }?.kind == .appScripts)
}

@Test func stockColorProfilesAreApple() {
    #expect(ReferenceData.bundled.stock.isAppleName("Blue Tone"))
}
