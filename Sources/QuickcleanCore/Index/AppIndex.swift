import Foundation

public enum AppSource: String, Codable, Sendable {
    case appStore, homebrew, manual, system
}

public struct InstalledApp: Sendable, Hashable {
    public var bundleID: String
    public var name: String
    public var version: String?
    public var teamID: String?
    public var isAppleSigned: Bool
    public var source: AppSource
    public var url: URL
    public var lastUsed: Date?
    /// Bundle IDs of extensions, helpers and login items inside the app.
    public var embeddedIDs: [String] = []
}

/// Every installed app, with the lookups attribution needs.
public struct AppIndex: Sendable {
    public let apps: [InstalledApp]
    private let byBundleID: [String: InstalledApp]
    private let byName: [String: InstalledApp]

    public init(apps: [InstalledApp]) {
        self.apps = apps
        var ids = Dictionary(apps.map { ($0.bundleID.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        for app in apps {
            for id in app.embeddedIDs where ids[id.lowercased()] == nil { ids[id.lowercased()] = app }
        }
        byBundleID = ids
        byName = Dictionary(apps.map { (Identifier.normalize($0.name), $0) }, uniquingKeysWith: { a, _ in a })
    }

    public func app(bundleID: String) -> InstalledApp? { byBundleID[bundleID.lowercased()] }

    public func apps(teamID: String) -> [InstalledApp] { apps.filter { $0.teamID == teamID } }

    /// An installed app whose bundle ID starts with `vendorPrefix` (e.g. "com.foo").
    public func app(vendorPrefix: String) -> InstalledApp? {
        let p = vendorPrefix.lowercased() + "."
        return apps.first { $0.bundleID.lowercased().hasPrefix(p) }
    }

    public func app(nameToken: String) -> InstalledApp? {
        let n = Identifier.normalize(nameToken)
        return n.isEmpty ? nil : byName[n]
    }

    /// The app whose bundle contains `path`.
    public func app(containing path: String) -> InstalledApp? {
        apps.first { app in
            let base = app.url.path
            return path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
        }
    }
}

public enum AppIndexBuilder {
    public static func build(_ env: ScanEnvironment, reference: ReferenceData, caskApps: Set<String>) -> AppIndex {
        let roots = [env.path("Applications"), env.path("Applications/Utilities"), env.homePath("Applications")]
        var seen = Set<String>()
        var apps: [InstalledApp] = []
        for root in roots {
            for url in candidates(in: root) where seen.insert(url.path).inserted {
                if let app = inspect(url, env: env, reference: reference, caskApps: caskApps) { apps.append(app) }
            }
        }
        return AppIndex(apps: apps)
    }

    /// `.app` bundles in `root` and its plain subfolders, up to `depth` levels; never inside packages.
    private static func candidates(in root: URL, depth: Int = 3) -> [URL] {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return [] }
        var result: [URL] = []
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if child.pathExtension == "app" { result.append(child); continue }
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard depth > 1, child.pathExtension.isEmpty, values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
            result += candidates(in: child, depth: depth - 1)
        }
        return result
    }

    private static func inspect(_ url: URL, env: ScanEnvironment, reference: ReferenceData, caskApps: Set<String>) -> InstalledApp? {
        guard let info = NSDictionary(contentsOf: url.appending(path: "Contents/Info.plist")) else { return nil }
        let fileName = url.deletingPathExtension().lastPathComponent
        // Some launchers (Steam game shortcuts) ship no bundle ID; give them a private one.
        let bundleID = info["CFBundleIdentifier"] as? String ?? "local.unidentified.\(Identifier.normalize(fileName))"
        let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? fileName
        let signature = env.bundles.signature(of: url)
        let source: AppSource =
            if reference.stock.appBundleIDs.contains(bundleID) { .system }
            else if FileManager.default.fileExists(atPath: url.appending(path: "Contents/_MASReceipt/receipt").path) { .appStore }
            else if caskApps.contains(url.lastPathComponent) { .homebrew }
            else { .manual }
        return InstalledApp(
            bundleID: bundleID, name: name.isEmpty ? fileName : name,
            version: info["CFBundleShortVersionString"] as? String, teamID: signature.teamID,
            isAppleSigned: signature.isApple, source: source, url: url, lastUsed: env.bundles.lastUsed(url),
            embeddedIDs: embeddedIDs(in: url))
    }

    private static let embeddedFolders = [
        "Contents/PlugIns", "Contents/Extensions", "Contents/Library/LoginItems", "Contents/Library/LaunchServices",
        "Contents/Library/SystemExtensions", "Contents/XPCServices", "Contents/Helpers", "Contents/MacOS",
    ]

    private static func embeddedIDs(in app: URL) -> [String] {
        embeddedFolders.flatMap { folder -> [String] in
            let dir = app.appending(path: folder)
            let children = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            return children.compactMap { child in
                guard !child.pathExtension.isEmpty else { return nil }
                return NSDictionary(contentsOf: child.appending(path: "Contents/Info.plist"))?["CFBundleIdentifier"] as? String
            }
        }
    }
}
