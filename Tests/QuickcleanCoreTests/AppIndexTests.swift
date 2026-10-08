import Foundation
import Testing
@testable import QuickcleanCore

private func makeFixture() throws -> Fixture {
    let fx = try Fixture()
    try fx.bundle("root/Applications/Foo.app", id: "com.foo.app", name: "Foo")
    try fx.bundle("root/Applications/Games/Bar.app", id: "com.bar.game", name: "Bar")
    try fx.file("root/Applications/Games/Bar.app/Contents/_MASReceipt/receipt")
    try fx.bundle("home/Applications/Baz Pro.app", id: "com.baz.pro")
    try fx.dir("root/Applications/Broken.app/Contents")   // no Info.plist
    try fx.bundle("root/Applications/Safari.app", id: "com.apple.Safari", name: "Safari")
    return fx
}

private func index(_ fx: Fixture, casks: Set<String> = []) -> AppIndex {
    let env = fx.env(signatures: [
        "com.foo.app": SignatureInfo(teamID: "TEAM123456", isApple: false),
        "com.apple.Safari": SignatureInfo(teamID: nil, isApple: true),
    ])
    return AppIndexBuilder.build(env, reference: ReferenceData.bundled, caskApps: casks)
}

@Test func indexFindsAppsInRootHomeAndSubfolders() throws {
    let fx = try makeFixture()
    let ids = Set(index(fx).apps.map(\.bundleID))
    #expect(ids == ["com.foo.app", "com.bar.game", "com.baz.pro", "com.apple.Safari"])
}

@Test func indexLooksUpByBundleIDCaseInsensitively() throws {
    let fx = try makeFixture()
    #expect(index(fx).app(bundleID: "COM.FOO.APP")?.name == "Foo")
}

@Test func indexLooksUpByTeamVendorNameAndContainedPath() throws {
    let fx = try makeFixture()
    let idx = index(fx)
    #expect(idx.apps(teamID: "TEAM123456").map(\.bundleID) == ["com.foo.app"])
    #expect(idx.app(vendorPrefix: "com.foo")?.bundleID == "com.foo.app")
    #expect(idx.app(nameToken: "foo")?.bundleID == "com.foo.app")
    #expect(idx.app(nameToken: "bazpro")?.bundleID == "com.baz.pro")   // name from filename
    let inside = fx.root.appending(path: "Applications/Foo.app/Contents/MacOS/foo").path
    #expect(idx.app(containing: inside)?.bundleID == "com.foo.app")
    #expect(idx.app(containing: "/elsewhere/Foo.app/x") == nil)
}

@Test func indexDetectsSource() throws {
    let fx = try makeFixture()
    let idx = index(fx, casks: ["Baz Pro.app"])
    #expect(idx.app(bundleID: "com.bar.game")?.source == .appStore)
    #expect(idx.app(bundleID: "com.baz.pro")?.source == .homebrew)
    #expect(idx.app(bundleID: "com.foo.app")?.source == .manual)
    #expect(idx.app(bundleID: "com.apple.Safari")?.source == .system)
    #expect(idx.app(bundleID: "com.apple.Safari")?.isAppleSigned == true)
}

@Test func normalizeStripsCaseSpacesPunctuationAndVersions() {
    #expect(Identifier.normalize("Baz Pro.app") == "bazpro")
    #expect(Identifier.normalize("Adobe Photoshop 2025") == "adobephotoshop")
    #expect(Identifier.normalize("zoom.us") == "zoomus")
}
