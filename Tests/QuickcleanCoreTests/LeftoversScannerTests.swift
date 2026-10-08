import Foundation
import Testing
@testable import QuickcleanCore

@Suite(.serialized) struct LeftoversScannerTests {
    func scan(_ fx: Fixture) async -> ScanOutput {
        await LeftoversScanner().scan(fx.env(), index: AppIndex(apps: []))
    }

    @Test func findsItemsAcrossLibraryFolders() async throws {
        let fx = try Fixture()
        try fx.dir("home/Library/Caches/com.spotify.client")
        try fx.plist("home/Library/Preferences/com.spotify.client.plist", ["a": 1])
        try fx.plist("home/Library/Preferences/ByHost/com.foo.app.0F1E2D3C-AAAA-BBBB-CCCC-111122223333.plist", ["a": 1])
        try fx.dir("home/Library/Saved Application State/com.gone.app.savedState")
        try fx.dir("root/Library/Application Support/Adobe")
        try fx.file("home/Library/Caches/.DS_Store")
        try fx.dir("home/Library/Preferences/SomeFolder")

        let out = await scan(fx)
        let byID = Dictionary(out.findings.map { ($0.identifier ?? "", $0) }, uniquingKeysWith: { a, _ in a })
        #expect(byID["com.spotify.client"]?.kind == .cache || byID["com.spotify.client"]?.kind == .preferences)
        #expect(out.findings.filter { $0.identifier == "com.spotify.client" }.map(\.kind).sorted { $0.rawValue < $1.rawValue } == [.cache, .preferences])
        #expect(byID["com.foo.app"]?.kind == .preferences)
        #expect(byID["com.gone.app"]?.kind == .savedState)
        #expect(byID["Adobe"]?.kind == .appSupport)
        #expect(byID["Adobe"]?.inSystemDomain == true)
        #expect(byID["com.spotify.client"]?.inSystemDomain == false)
        #expect(byID[".DS_Store"] == nil)
        #expect(byID["SomeFolder"] == nil)
        #expect(out.findings.count == 5)
        #expect(out.issues.isEmpty)
    }

    @Test func unreadableFolderBecomesIssue() async throws {
        let fx = try Fixture()
        let logs = try fx.dir("home/Library/Logs")
        try fx.dir("home/Library/Logs/Inside")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: logs.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: logs.path) }
        try fx.dir("home/Library/Caches/com.x.y")

        let out = await scan(fx)
        #expect(out.issues.count == 1)
        #expect(out.issues.first?.subject.hasSuffix("Library/Logs") == true)
        #expect(out.findings.map(\.identifier) == ["com.x.y"])
    }

    @Test func recordsModificationDate() async throws {
        let fx = try Fixture()
        try fx.dir("home/Library/Caches/com.x.y")
        try fx.setModified("home/Library/Caches/com.x.y", daysAgo: 300)
        let out = await scan(fx)
        let modified = try #require(out.findings.first?.modified)
        #expect(Fixture.now.timeIntervalSince(modified) > 299 * 86_400)
    }
}

@Test func containersCarryTheirCreator() async throws {
    let fx = try Fixture()
    try fx.plist("home/Library/Group Containers/group.com.facebook.family/.com.apple.containermanagerd.metadata.plist",
                 ["MCMMetadataCreator": "net.whatsapp.WhatsApp", "MCMMetadataIdentifier": "group.com.facebook.family"])
    try fx.dir("home/Library/Containers/com.plain.app")
    let out = await LeftoversScanner().scan(fx.env(), index: AppIndex(apps: []))
    #expect(out.findings.first { $0.identifier == "group.com.facebook.family" }?.creatorID == "net.whatsapp.WhatsApp")
    #expect(out.findings.first { $0.identifier == "com.plain.app" }?.creatorID == nil)
}
