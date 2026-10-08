import Foundation
@testable import QuickcleanCore

/// A throwaway fake Mac: `<tmp>/home` and `<tmp>/root`.
final class Fixture: @unchecked Sendable {
    let base: URL
    var home: URL { base.appending(path: "home") }
    var root: URL { base.appending(path: "root") }
    private let fm = FileManager.default

    init() throws {
        base = fm.temporaryDirectory.appending(path: "qc-fixture-\(UUID().uuidString)")
        try fm.createDirectory(at: base.appending(path: "home"), withIntermediateDirectories: true)
        try fm.createDirectory(at: base.appending(path: "root"), withIntermediateDirectories: true)
    }

    deinit { try? fm.removeItem(at: base) }

    func url(_ rel: String) -> URL { base.appending(path: rel) }

    @discardableResult
    func dir(_ rel: String) throws -> URL {
        let u = url(rel)
        try fm.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    @discardableResult
    func file(_ rel: String, _ contents: String = "x") throws -> URL {
        let u = url(rel)
        try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: u)
        return u
    }

    @discardableResult
    func bytes(_ rel: String, count: Int) throws -> URL {
        let u = url(rel)
        try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: count).write(to: u)
        return u
    }

    @discardableResult
    func plist(_ rel: String, _ dict: [String: Any]) throws -> URL {
        let u = url(rel)
        try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try data.write(to: u)
        return u
    }

    /// Creates `<rel>` as a minimal app/plugin bundle with a Contents/Info.plist.
    @discardableResult
    func bundle(_ rel: String, id: String, name: String? = nil, extra: [String: Any] = [:]) throws -> URL {
        var info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleShortVersionString": "1.0"]
        if let name { info["CFBundleName"] = name }
        info.merge(extra) { $1 }
        try plist("\(rel)/Contents/Info.plist", info)
        return url(rel)
    }

    func symlink(_ rel: String, to dest: String) throws {
        let u = url(rel)
        try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: u.path, withDestinationPath: dest)
    }

    func setModified(_ rel: String, daysAgo: Double, now: Date = Fixture.now) throws {
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-daysAgo * 86_400)], ofItemAtPath: url(rel).path)
    }

    static let now = Date(timeIntervalSince1970: 1_791_000_000)

    func env(
        commands: [String: CommandResult] = [:],
        signatures: [String: SignatureInfo] = [:],
        preferences: [String: [String: Any]]? = nil,
        running: Set<String> = []
    ) -> ScanEnvironment {
        ScanEnvironment(
            home: home, root: root,
            commands: StubCommandRunner(commands),
            bundles: StubBundleInspector(signatures),
            preferences: preferences.map { DictPreferences($0) } ?? PlistPreferencesReader(home: home),
            now: Fixture.now, runningBundleIDs: running)
    }
}

/// Keyed by "exe arg1 arg2". Unknown commands fail with notFound.
struct StubCommandRunner: CommandRunner {
    let results: [String: CommandResult]
    init(_ results: [String: CommandResult]) { self.results = results }
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> CommandResult {
        let key = ([executable] + arguments).joined(separator: " ")
        guard let r = results[key] else { throw CommandError.notFound(key) }
        return r
    }
}

extension CommandResult {
    static func ok(_ out: String) -> CommandResult { CommandResult(status: 0, stdout: out, stderr: "") }
}

/// Keyed by bundle id read from Info.plist; unsigned when absent.
struct StubBundleInspector: BundleInspector {
    let byBundleID: [String: SignatureInfo]
    init(_ m: [String: SignatureInfo]) { byBundleID = m }
    func signature(of url: URL) -> SignatureInfo {
        let info = NSDictionary(contentsOf: url.appending(path: "Contents/Info.plist"))
        let id = info?["CFBundleIdentifier"] as? String ?? ""
        return byBundleID[id] ?? SignatureInfo(teamID: nil, isApple: false)
    }
    func lastUsed(_ url: URL) -> Date? { nil }
}

struct DictPreferences: PreferencesReader, @unchecked Sendable {
    let domains: [String: [String: Any]]
    init(_ d: [String: [String: Any]]) { domains = d }
    func values(domain: String) -> [String: Any]? { domains[domain] }
}
