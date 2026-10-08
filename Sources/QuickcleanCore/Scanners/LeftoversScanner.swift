import Foundation

/// App data left in the standard Library folders, in both the user and system domains.
public struct LeftoversScanner: Scanner {
    public var category: ScanCategory { .leftovers }

    static let locations: [(String, Kind)] = [
        ("Application Support", .appSupport), ("Caches", .cache), ("Preferences", .preferences),
        ("Containers", .container), ("Group Containers", .groupContainer),
        ("Saved Application State", .savedState), ("HTTPStorages", .httpStorage), ("WebKit", .webkitData),
        ("Logs", .logs), ("Cookies", .cookies), ("Application Scripts", .appScripts),
    ]

    public init() {}

    public func scan(_ env: ScanEnvironment, index: AppIndex) async -> ScanOutput {
        var out = ScanOutput()
        // Developer caches and data are reported (once) by the Dev Tooling scanner.
        let claimed = Set((DevToolingScanner.caches + DevToolingScanner.data).map { env.homePath($0.0).path })
        for (library, system) in [(env.homePath("Library"), false), (env.path("Library"), true)] {
            for (folder, kind) in Self.locations {
                let dir = library.appending(path: folder)
                if kind == .preferences {
                    let files = Listing.children(dir, into: &out).filter { $0.pathExtension == "plist" }
                    let byHost = Listing.children(dir.appending(path: "ByHost"), into: &out).filter { $0.pathExtension == "plist" }
                    for url in files + byHost { out.findings.append(finding(url, kind, system)) }
                } else {
                    for url in Listing.children(dir, into: &out) where !claimed.contains(url.path) {
                        out.findings.append(finding(url, kind, system))
                    }
                }
            }
        }
        // Shared data every user account can see.
        for url in Listing.children(env.path("Users/Shared"), into: &out) where !Self.isStockShared(url.lastPathComponent) {
            out.findings.append(finding(url, .appSupport, true))
        }
        return out
    }

    /// Folders macOS itself keeps in /Users/Shared (update relocations included).
    static func isStockShared(_ name: String) -> Bool {
        ["SC Info", "Library"].contains(name) || name.hasPrefix("Relocated Items") || name.hasPrefix("Previously Relocated Items")
    }

    private func finding(_ url: URL, _ kind: Kind, _ system: Bool) -> RawFinding {
        var raw = RawFinding(
            category: .leftovers, kind: kind, name: url.lastPathComponent, paths: [url],
            identifier: Identifier.strip(url.lastPathComponent), modified: Listing.modified(url),
            inSystemDomain: system)
        let metadataName = ".com.apple.containermanagerd.metadata.plist"
        switch kind {
        case .container, .groupContainer:
            raw.creatorID = NSDictionary(contentsOf: url.appending(path: metadataName))?["MCMMetadataCreator"] as? String
        case .appScripts:
            // Application Scripts folders mirror a container of the same name.
            let library = url.deletingLastPathComponent().deletingLastPathComponent()
            raw.creatorID = ["Group Containers", "Containers"].lazy.compactMap { folder in
                NSDictionary(contentsOf: library.appending(path: "\(folder)/\(url.lastPathComponent)/\(metadataName)"))?["MCMMetadataCreator"] as? String
            }.first
        default:
            break
        }
        return raw
    }
}
