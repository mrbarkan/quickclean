import Foundation
import Testing
@testable import QuickcleanCore

@Test func reportsOnlyNonDefaultTrackedKeys() async throws {
    let fx = try Fixture()
    let env = fx.env(preferences: [
        "com.apple.dock": ["autohide": true, "orientation": "bottom", "persistent-apps": [1]],
        "com.apple.universalaccess": ["cursorIsCustomized": true],
    ])
    let out = await SettingsScanner().scan(env, index: AppIndex(apps: []))
    let ids = Set(out.findings.compactMap(\.idOverride))
    #expect(ids == ["settings:com.apple.dock:autohide", "settings:com.apple.universalaccess:cursorIsCustomized"])
    let autohide = try #require(out.findings.first { $0.idOverride == "settings:com.apple.dock:autohide" })
    #expect(autohide.kind == .settingsKey)
    #expect(autohide.name == "Dock: automatically hide")
    #expect(autohide.detail?.contains("is on; macOS default is off") == true)
    #expect(autohide.preset?.status == .apple)
    #expect(autohide.paths.first?.lastPathComponent == "com.apple.dock.plist")
}

@Test func boolDefaultDoesNotMatchNumberOne() async throws {
    let fx = try Fixture()
    let env = fx.env(preferences: ["com.apple.dock": ["autohide": NSNumber(value: false)]])
    #expect(await SettingsScanner().scan(env, index: AppIndex(apps: [])).findings.isEmpty)
    let env2 = fx.env(preferences: ["com.apple.dock": ["autohide": 1]])
    #expect(await SettingsScanner().scan(env2, index: AppIndex(apps: [])).findings.count == 1)
}

@Test func globalDomainUsesGlobalPreferencesFile() async throws {
    let fx = try Fixture()
    let env = fx.env(preferences: ["NSGlobalDomain": ["KeyRepeat": 1]])
    let f = try #require(await SettingsScanner().scan(env, index: AppIndex(apps: [])).findings.first)
    #expect(f.paths.first?.lastPathComponent == ".GlobalPreferences.plist")
    #expect(f.detail?.contains("not set") == true)
}
