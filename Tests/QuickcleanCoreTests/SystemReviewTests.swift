import Foundation
import Testing
@testable import QuickcleanCore

/// Regressions from the System Changes review.

private func run(_ fx: Fixture, _ commands: [String: CommandResult]) async -> ScanOutput {
    let all = commands.merging(["/usr/sbin/pkgutil --pkgs": .ok(""), "/usr/bin/pluginkit -mAvvv": .ok("")]) { a, _ in a }
    return await SystemScanner().scan(fx.env(commands: all), index: AppIndex(apps: []))
}

@Test func relativeSymlinksResolveFromTheirFolder() async throws {
    let fx = try Fixture()
    try fx.file("root/usr/local/lib/node_modules/npm/bin/npm-cli.js")
    try fx.symlink("root/usr/local/bin/npm", to: "../lib/node_modules/npm/bin/npm-cli.js")
    let out = await run(fx, [:])
    let npm = try #require(out.findings.first { $0.name == "npm" })
    #expect(!npm.badges.contains(.broken))
    #expect(npm.programPath == fx.root.appending(path: "usr/local/lib/node_modules/npm/bin/npm-cli.js").path)
}

@Test func receiptWithOnlyStockFoldersLeftIsBroken() async throws {
    let fx = try Fixture()
    try fx.dir("root/Applications")
    let pkg = "/usr/sbin/pkgutil"
    let out = await run(fx, [
        "\(pkg) --pkgs": .ok("net.displaycal.pkg\n"),
        "\(pkg) --pkg-info net.displaycal.pkg": .ok("package-id: net.displaycal.pkg\nvolume: /\nlocation: /\n"),
        "\(pkg) --only-files --files net.displaycal.pkg": .ok("Applications/DisplayCAL.app/Contents/Info.plist\nApplications/DisplayCAL.app/Contents/MacOS/DisplayCAL\n"),
    ])
    let receipt = try #require(out.findings.first { $0.kind == .pkgReceipt })
    #expect(receipt.badges.contains(.broken))
    #expect(receipt.programPath?.hasSuffix("Applications/DisplayCAL.app/Contents") == true)
}

@Test func pluginkitHeadersWithAnyFlagAreParsed() async throws {
    let fx = try Fixture()
    let output = "   . com.example.dot(1.0)\n\t            Path = /Applications/A.app/Contents/PlugIns/X.appex\n\n?    com.example.unknown(2.0)\n\t            Path = /Applications/B.app/Contents/PlugIns/Y.appex\n"
    let out = await run(fx, ["/usr/bin/pluginkit -mAvvv": .ok(output)])
    #expect(Set(out.findings.filter { $0.kind == .appExtension }.compactMap(\.identifier)) == ["com.example.dot", "com.example.unknown"])
}

@Test func hostsWithWindowsLineEndingsAndCommentsAreParsed() async throws {
    let fx = try Fixture()
    try fx.file("root/private/etc/hosts", "127.0.0.1\tlocalhost # stock\r\n::1 localhost\r\n0.0.0.0 ads.example.com\r\n10.0.0.1 a.local\r\n")
    let out = await run(fx, [:])
    #expect(out.findings.first { $0.name == "hosts" }?.detail?.contains("2 custom entries") == true)
}

@Test func viewerRoleIsUsedWhenAllRoleIsUnset() async throws {
    let fx = try Fixture()
    try fx.plist("home/Library/Preferences/com.apple.LaunchServices/com.apple.launchservices.secure.plist", ["LSHandlers": [
        ["LSHandlerContentType": "public.mp3", "LSHandlerRoleAll": "-", "LSHandlerRoleViewer": "org.videolan.vlc"],
    ]])
    let out = await run(fx, [:])
    #expect(out.findings.first { $0.kind == .defaultHandler }?.identifier == "org.videolan.vlc")
}

@Test func macOSUpdateFoldersInSharedAreSkipped() async throws {
    let fx = try Fixture()
    for name in ["Relocated Items", "Previously Relocated Items 3", "Library", "Adobe"] { try fx.dir("root/Users/Shared/\(name)") }
    let out = await LeftoversScanner().scan(fx.env(), index: AppIndex(apps: []))
    #expect(out.findings.map(\.name) == ["Adobe"])
}

private func wallpaperFindings(_ fx: Fixture, _ urls: [String]) async throws -> [RawFinding] {
    let choices = try urls.map { url -> [String: Any] in
        ["Configuration": try PropertyListSerialization.data(fromPropertyList: ["url": ["relative": url]], format: .binary, options: 0)]
    }
    try fx.plist("home/Library/Application Support/com.apple.wallpaper/Store/Index.plist", ["Spaces": ["A": ["Choices": choices]]])
    return await SettingsScanner().scan(fx.env(preferences: [:]), index: AppIndex(apps: [])).findings
}

@Test func missingWallpaperIsNotHiddenAsApple() async throws {
    let fx = try Fixture()
    let found = try await wallpaperFindings(fx, [fx.home.appending(path: "Pictures/gone.jpg").absoluteString])
    let f = try #require(found.first)
    let a = Attributor(index: AppIndex(apps: []), reference: .bundled).attribute(f)
    #expect(a.status != .apple)
}

@Test func appleWallpaperCachesAreNotReportedMissing() async throws {
    let fx = try Fixture()
    let cache = fx.home.appending(path: "Library/Application Support/com.apple.mobileAssetDesktop/Monterey Graphic.heic").absoluteString
    #expect(try await wallpaperFindings(fx, [cache, "file:///Library/Desktop%20Pictures/Gone.heic"]).isEmpty)
}
