import Foundation

/// App data left in the standard Library folders, in both the user and system domains.
public struct LeftoversScanner: Scanner {
    public var category: ScanCategory { .leftovers }

    static let locations: [(String, Kind)] = [
        ("Application Support", .appSupport), ("Caches", .cache), ("Preferences", .preferences),
        ("Containers", .container), ("Group Containers", .groupContainer),
        ("Saved Application State", .savedState), ("HTTPStorages", .httpStorage), ("WebKit", .webkitData),
        ("Logs", .logs), ("Cookies", .cookies),
    ]

    public init() {}

    public func scan(_ env: ScanEnvironment, index: AppIndex) async -> ScanOutput {
        var out = ScanOutput()
        for (library, system) in [(env.homePath("Library"), false), (env.path("Library"), true)] {
            for (folder, kind) in Self.locations {
                let dir = library.appending(path: folder)
                if kind == .preferences {
                    let files = Listing.children(dir, into: &out).filter { $0.pathExtension == "plist" }
                    let byHost = Listing.children(dir.appending(path: "ByHost"), into: &out).filter { $0.pathExtension == "plist" }
                    for url in files + byHost { out.findings.append(finding(url, kind, system)) }
                } else {
                    for url in Listing.children(dir, into: &out) { out.findings.append(finding(url, kind, system)) }
                }
            }
        }
        return out
    }

    private func finding(_ url: URL, _ kind: Kind, _ system: Bool) -> RawFinding {
        RawFinding(
            category: .leftovers, kind: kind, name: url.lastPathComponent, paths: [url],
            identifier: Identifier.strip(url.lastPathComponent), modified: Listing.modified(url),
            inSystemDomain: system)
    }
}
