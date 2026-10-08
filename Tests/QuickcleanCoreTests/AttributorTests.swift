import Foundation
import Testing
@testable import QuickcleanCore

private let foo = InstalledApp(
    bundleID: "com.foo.app", name: "Foo", version: "1", teamID: "TEAM123456", isAppleSigned: false,
    source: .manual, url: URL(fileURLWithPath: "/Applications/Foo.app"), lastUsed: nil)
private let xcode = InstalledApp(
    bundleID: "com.apple.dt.Xcode", name: "Xcode", version: "27", teamID: nil, isAppleSigned: true,
    source: .appStore, url: URL(fileURLWithPath: "/Applications/Xcode.app"), lastUsed: nil)

private let attributor = Attributor(
    index: AppIndex(apps: [foo, xcode]), reference: ReferenceData.bundled,
    fileExists: { $0.hasPrefix("/Applications/Foo.app") })

private func attribute(_ identifier: String?, program: String? = nil) -> Attribution {
    attributor.attribute(RawFinding(
        category: .leftovers, kind: .cache, name: identifier ?? "x", paths: [], identifier: identifier,
        programPath: program))
}

@Test func exactBundleIDOfInstalledApp() {
    let a = attribute("com.foo.app")
    #expect(a.status == .installed && a.confidence == .high && a.owner?.displayName == "Foo")
}

@Test func vendorPrefixOfInstalledApp() {
    let a = attribute("com.foo.helper")
    #expect(a.status == .installed && a.confidence == .medium && a.owner?.bundleID == "com.foo.app")
}

@Test func bundleIDOfMissingAppIsOrphaned() {
    let a = attribute("com.gone.app")
    #expect(a.status == .orphaned && a.confidence == .high && a.owner?.displayName == "Gone")
}

@Test func appleIdentifiersAreApple() {
    #expect(attribute("com.apple.Safari").status == .apple)
    #expect(attribute("GeoServices").status == .apple)
}

@Test func appleSignedInstalledAppIsApple() {
    #expect(attribute("com.apple.dt.Xcode").status == .apple)
}

@Test func teamPrefixedContainerOfInstalledApp() {
    let a = attribute("TEAM123456.com.foo.shared")
    #expect(a.status == .installed && a.confidence == .medium)
    let exact = attribute("TEAM123456.com.foo.app")
    #expect(exact.status == .installed && exact.confidence == .high)
}

@Test func teamPrefixedContainerOfUnknownTeamIsOrphaned() {
    let a = attribute("ZZZZZZZZZZ.group.x")
    #expect(a.status == .orphaned && a.confidence == .medium)
}

@Test func programInsideMissingAppIsOrphaned() {
    let a = attribute("com.gone.agent", program: "/Applications/Gone.app/Contents/MacOS/g")
    #expect(a.status == .orphaned && a.confidence == .high && a.owner?.displayName == "Gone")
}

@Test func programInsideInstalledApp() {
    let a = attribute("com.whatever.agent", program: "/Applications/Foo.app/Contents/Library/LoginItems/h")
    #expect(a.status == .installed && a.confidence == .high && a.owner?.bundleID == "com.foo.app")
}

@Test func knownAppPatternWhenNotInstalled() {
    let a = attribute("com.alexzielenski.mousecloak.listener")
    #expect(a.status == .orphaned && a.confidence == .medium && a.owner?.displayName == "Mousecape")
}

@Test func plainNameMatchingInstalledApp() {
    let a = attribute("Foo")
    #expect(a.status == .installed && a.confidence == .low)
}

@Test func plainNameKnownAppFolder() {
    let a = attribute("Adobe")
    #expect(a.status == .orphaned && a.confidence == .medium && a.owner?.displayName == "Adobe")
}

@Test func unknownName() {
    let a = attribute("RandomThing")
    #expect(a.status == .unknown && a.confidence == .none && a.owner == nil)
}

@Test func presetWins() {
    let preset = PresetAttribution(
        owner: Owner(bundleID: nil, displayName: "Homebrew", teamID: nil), status: .installed,
        confidence: .high, evidence: Evidence(rule: "homebrew", detail: "Installed by Homebrew."))
    let a = attributor.attribute(RawFinding(
        category: .devTooling, kind: .brewFormula, name: "node", paths: [], identifier: "com.apple.x", preset: preset))
    #expect(a.status == .installed && a.owner?.displayName == "Homebrew")
}

@Test func everyAttributionCarriesEvidence() {
    for id in ["com.foo.app", "com.gone.app", "RandomThing", "Adobe", "com.apple.Safari"] {
        #expect(!attribute(id).evidence.isEmpty)
    }
}

@Test func appKnownToLaunchServicesElsewhereIsInstalled() {
    let a = Attributor(
        index: AppIndex(apps: []), reference: ReferenceData.bundled,
        locateApp: { $0 == "com.elsewhere.app" ? URL(fileURLWithPath: "/Users/x/Games/Elsewhere.app") : nil })
    let r = a.attribute(RawFinding(category: .leftovers, kind: .cache, name: "com.elsewhere.app", paths: [], identifier: "com.elsewhere.app"))
    #expect(r.status == .installed && r.owner?.displayName == "Elsewhere")
}

@Test func knownAppWhoseOwnBundleIDIsMissingIsHighConfidence() {
    let r = attribute("com.spotify.client")
    #expect(r.status == .orphaned && r.confidence == .high && r.owner?.displayName == "Spotify")
}

// MARK: Real-machine regressions

private let adobeAE = InstalledApp(
    bundleID: "com.adobe.AfterEffects", name: "Adobe After Effects 2026", version: nil, teamID: "JQ525L2MZD",
    isAppleSigned: false, source: .manual, url: URL(fileURLWithPath: "/Applications/Adobe After Effects 2026/Adobe After Effects 2026.app"), lastUsed: nil)
private let realistic = Attributor(
    index: AppIndex(apps: [adobeAE]), reference: ReferenceData.bundled,
    fileExists: { $0 == "/opt/homebrew/bin/brew" })

private func attributeReal(_ id: String) -> Attribution {
    realistic.attribute(RawFinding(category: .leftovers, kind: .appSupport, name: id, paths: [], identifier: id))
}

@Test func vendorFolderIsInstalledWhenAnyVendorAppIs() {
    #expect(attributeReal("Adobe").status == .installed)
    #expect(attributeReal("com.Adobe.After Effects.26.0").status == .installed)
}

@Test func homebrewFolderIsInstalledWhenBrewExists() {
    #expect(attributeReal(".homebrew").status != .orphaned)
    #expect(attributeReal("Homebrew").status == .installed)
}

@Test func libraryCachesAreNotAttributedToAnApp() {
    for id in ["com.crashlytics.data", "com.hackemist.SDImageCache", "org.sparkle-project.DownloaderService", "io.sentry"] {
        let a = attributeReal(id)
        #expect(a.status == .unknown, "\(id)")
        #expect(a.confidence == .low, "\(id)")
        #expect(a.owner != nil, "\(id)")
    }
}

@Test func teamPrefixedAppleGroupsAreApple() {
    #expect(attributeReal("243LU875E5.groups.com.apple.podcasts").status == .apple)
    #expect(attributeReal("74J34U3R6X.com.apple.iWork").status == .apple)
    #expect(attributeReal("systemgroup.com.apple.icloud.searchpartyd.sharedsettings").status == .apple)
}

@Test func bundleLikeAllowsSpacesAfterVendor() {
    #expect(Identifier.isBundleLike("com.borisfx.Mocha AE Plugin 2025"))
    #expect(!Identifier.isBundleLike("com foo.bar.baz"))
}
