import Foundation
import Testing
@testable import QuickcleanCore

@Test func sumsAllocatedSizeOfFolder() async throws {
    let fx = try Fixture()
    try fx.bytes("home/d/a", count: 1_000_000)
    try fx.bytes("home/d/sub/b", count: 1_000_000)
    let size = await SizeCalculator().size(of: [fx.url("home/d")])
    #expect(size >= 2_000_000)
    #expect(size < 2_200_000)
}

@Test func hardLinksCountOnce() async throws {
    let fx = try Fixture()
    try fx.bytes("home/d/a", count: 1_000_000)
    try FileManager.default.linkItem(at: fx.url("home/d/a"), to: fx.url("home/d/a-link"))
    let size = await SizeCalculator().size(of: [fx.url("home/d")])
    #expect(size < 1_100_000)
}

@Test func symlinksAreNotFollowed() async throws {
    let fx = try Fixture()
    try fx.symlink("home/Library/Caches/evil", to: "/")
    let start = Date()
    let size = await SizeCalculator().size(of: [fx.url("home/Library/Caches/evil")])
    #expect(size == 0)
    #expect(Date().timeIntervalSince(start) < 1)
}

@Test func symlinkInsideFolderIsNotFollowed() async throws {
    let fx = try Fixture()
    try fx.bytes("home/d/a", count: 10_000)
    try fx.symlink("home/d/root", to: "/")
    let size = await SizeCalculator().size(of: [fx.url("home/d")])
    #expect(size < 100_000)
}

@Test func missingPathIsZero() async {
    #expect(await SizeCalculator().size(of: [URL(fileURLWithPath: "/nonexistent/qc")]) == 0)
}

@Test func appsScannerReportsEveryIndexedApp() async throws {
    let fx = try Fixture()
    let apps = [
        InstalledApp(bundleID: "com.foo.app", name: "Foo", version: "1.0", teamID: "T", isAppleSigned: false, source: .homebrew,
                     url: fx.url("root/Applications/Foo.app"), lastUsed: Fixture.now.addingTimeInterval(-400 * 86_400)),
        InstalledApp(bundleID: "com.apple.Safari", name: "Safari", version: "27", teamID: nil, isAppleSigned: true, source: .system,
                     url: fx.url("root/Applications/Safari.app"), lastUsed: nil),
    ]
    let out = await AppsScanner().scan(fx.env(), index: AppIndex(apps: apps))
    let foo = try #require(out.findings.first { $0.identifier == "com.foo.app" })
    #expect(foo.kind == .app && foo.name == "Foo")
    #expect(foo.preset?.status == .installed)
    #expect(foo.badges.contains(.stale))
    #expect(foo.detail?.contains("Homebrew") == true)
    #expect(out.findings.first { $0.identifier == "com.apple.Safari" }?.preset?.status == .apple)
}
