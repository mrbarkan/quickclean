import Foundation
import Testing
@testable import QuickcleanCore

/// A small fake Mac exercising every scanner.
func makeFixtureMac() throws -> (Fixture, ScanEnvironment) {
    let fx = try Fixture()
    try fx.bundle("root/Applications/Foo.app", id: "com.foo.app", name: "Foo")
    try fx.plist("home/Library/Preferences/com.foo.app.plist", ["x": 1])
    try fx.dir("home/Library/Application Support/Mousecape")
    try fx.plist("home/Library/LaunchAgents/com.alexzielenski.mousecloak.listener.plist", [
        "Label": "com.alexzielenski.mousecloak.listener",
        "ProgramArguments": [fx.home.appending(path: "Library/Application Support/Mousecape/listener").path],
        "RunAtLoad": true,
    ])
    try fx.dir("root/Library/Application Support/Adobe")
    try fx.dir("home/Library/Caches/com.spotify.client")
    try fx.bytes("home/Library/Caches/com.spotify.client/data", count: 50_000)
    try fx.dir("home/Documents")
    try fx.dir("home/.ssh")
    let brew = try fx.file("root/opt/homebrew/bin/brew", "#!/bin/sh").path
    let brewJSON = """
    {"formulae": [{"name": "node", "full_name": "node", "tap": "homebrew/core", "desc": "JavaScript runtime",
      "installed": [{"version": "24.1.0", "installed_on_request": true}]}], "casks": []}
    """
    let env = fx.env(
        commands: [
            "\(brew) info --json=v2 --installed": .ok(brewJSON),
            "\(brew) leaves": .ok("node\n"),
            "/usr/bin/systemextensionsctl list": .ok("0 extension(s)\n"),
            "/bin/launchctl list": .ok("PID\tStatus\tLabel\n"),
        ],
        signatures: ["com.foo.app": SignatureInfo(teamID: "TEAM123456", isApple: false)],
        preferences: ["com.apple.dock": ["autohide": true]])
    return (fx, env)
}

private func normalized(_ findings: [Finding], _ fx: Fixture) throws -> String {
    let stripped = findings.map { f -> Finding in
        var f = f
        f.size = nil
        f.modified = nil
        return f
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(stripped), as: UTF8.self)
        .replacingOccurrences(of: fx.home.path, with: "$HOME")
        .replacingOccurrences(of: fx.root.path, with: "$ROOT")
}

private let goldenURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/expected-report.json")

@Test func goldenScanOfFixtureMac() async throws {
    let (fx, env) = try makeFixtureMac()
    let result = await ScanEngine(env: env).run()
    let actual = try normalized(result.findings, fx)
    if ProcessInfo.processInfo.environment["QC_UPDATE_GOLDEN"] == "1" {
        try FileManager.default.createDirectory(at: goldenURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(actual.utf8).write(to: goldenURL)
    }
    let expected = try String(contentsOf: goldenURL, encoding: .utf8)
    #expect(actual == expected, "Re-run with QC_UPDATE_GOLDEN=1 and review the diff if this change is intended.")
}

@Test func engineHighlightsOnFixtureMac() async throws {
    let (fx, env) = try makeFixtureMac()
    defer { withExtendedLifetime(fx) {} }
    let result = await ScanEngine(env: env).run()
    let f = { (id: String) in result.findings.first { $0.id.hasSuffix(id) } }

    let agent = try #require(f("com.alexzielenski.mousecloak.listener.plist"))
    #expect(agent.ownerStatus == .orphaned && agent.risk == .careful && agent.badges.contains(.broken))
    #expect(agent.owner?.displayName == "Mousecape")

    let spotify = try #require(f("Caches/com.spotify.client"))
    #expect(spotify.defaultSelected)
    #expect((spotify.size ?? 0) >= 50_000)

    let prefs = try #require(f("Preferences/com.foo.app.plist"))
    #expect(prefs.ownerStatus == .installed && prefs.risk == .review)

    #expect(result.findings.filter(\.defaultSelected).allSatisfy { $0.risk == .safe })
    #expect(result.findings.first { $0.title == ".ssh" }?.risk == .protected)
    #expect(result.findings.contains { $0.id == "settings:com.apple.dock:autohide" })
    #expect(result.findings.contains { $0.kind == .app && $0.title == "Foo" })
    #expect(result.issues.contains { $0.subject == "Login Items" })
    #expect(Set(result.findings.map(\.id)).count == result.findings.count)
}

@Test func engineStreamsEventsAndCompletes() async throws {
    let (fx, env) = try makeFixtureMac()
    defer { withExtendedLifetime(fx) {} }
    var started = Set<QuickcleanCore.Category>(), finished = Set<QuickcleanCore.Category>()
    var findings = 0, sizes = 0, completed = false
    for await event in ScanEngine(env: env).events() {
        switch event {
        case .started(let c): started.insert(c)
        case .finished(let c): finished.insert(c)
        case .finding: findings += 1
        case .size: sizes += 1
        case .issue: break
        case .completed: completed = true
        }
    }
    #expect(started == Set(QuickcleanCore.Category.allCases))
    #expect(finished == started)
    #expect(findings > 5 && sizes > 0 && completed)
}

@Test func engineRespectsCategoryFilter() async throws {
    let (fx, env) = try makeFixtureMac()
    defer { withExtendedLifetime(fx) {} }
    let result = await ScanEngine(env: env, categories: [.settings]).run()
    #expect(result.findings.allSatisfy { $0.category == .settings })
    #expect(!result.findings.isEmpty)
}

@Test func fullDiskAccessCheckReadsTCCDatabase() throws {
    let fx = try Fixture()
    #expect(!FullDiskAccess.isGranted(home: fx.home))
    try fx.file("home/Library/Application Support/com.apple.TCC/TCC.db")
    #expect(FullDiskAccess.isGranted(home: fx.home))
}
