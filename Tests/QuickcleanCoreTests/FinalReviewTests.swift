import Foundation
import Testing
@testable import QuickcleanCore

/// Regressions from the final branch review.

@Test func appOnlySpotlightKnowsAboutIsNotAnOrphan() async throws {
    let fx = try Fixture()
    try fx.dir("home/Library/WebKit/com.aeroquartet.Treasured")
    let env = fx.env(spotlight: ["com.aeroquartet.Treasured": URL(fileURLWithPath: "/Volumes/Other/Treasured.app")])
    let result = await ScanEngine(env: env, categories: [.leftovers]).run()
    let f = try #require(result.findings.first { $0.id.hasSuffix("com.aeroquartet.Treasured") })
    #expect(f.ownerStatus == .installed)
    #expect(!f.defaultSelected)
}

@Test func helperIDExtendingInstalledAppIsInstalled() {
    let gh = InstalledApp(bundleID: "com.github.GitHubClient", name: "GitHub Desktop", version: nil, teamID: nil,
                          isAppleSigned: false, source: .manual, url: URL(fileURLWithPath: "/Applications/GitHub Desktop.app"), lastUsed: nil)
    let a = Attributor(index: AppIndex(apps: [gh]), reference: .bundled)
        .attribute(RawFinding(category: .leftovers, kind: .cache, name: "x", paths: [], identifier: "com.github.GitHubClient.ShipIt"))
    #expect(a.status == .installed)
    #expect(a.confidence == .medium)
}

@Test func devToolingPathsAreNotAlsoLeftovers() async throws {
    let fx = try Fixture()
    try fx.dir("home/Library/Caches/Homebrew")
    try fx.dir("home/Library/Caches/pip")
    try fx.dir("home/Library/Caches/com.other.app")
    let result = await ScanEngine(env: fx.env(), categories: [.leftovers, .devTooling]).run()
    let homebrew = result.findings.filter { $0.paths.first?.hasSuffix("Library/Caches/Homebrew") == true }
    #expect(homebrew.map(\.category) == [.devTooling])
    #expect(result.findings.filter { $0.paths.first?.hasSuffix("Library/Caches/pip") == true }.count == 1)
    #expect(result.findings.contains { $0.paths.first?.hasSuffix("com.other.app") == true })
}

@Test func knownAppFolderUsesLocatedApp() {
    let a = Attributor(index: AppIndex(apps: []), reference: .bundled,
                       locateApp: { $0 == "com.aeroquartet.Treasured" ? URL(fileURLWithPath: "/Volumes/X/Treasured.app") : nil })
        .attribute(RawFinding(category: .leftovers, kind: .appSupport, name: "Treasured", paths: [], identifier: "Treasured"))
    #expect(a.status == .installed)
}
