import Foundation

/// One finding per installed app.
public struct AppsScanner: Scanner {
    public var category: ScanCategory { .apps }

    public init() {}

    public func scan(_ env: ScanEnvironment, index: AppIndex) async -> ScanOutput {
        var out = ScanOutput()
        for app in index.apps {
            let isApple = app.isAppleSigned || app.source == .system
            let source: String = switch app.source {
            case .appStore: "Installed from the App Store."
            case .homebrew: "Installed with Homebrew."
            case .manual: "Installed manually."
            case .system: "Comes with macOS."
            }
            let used = app.lastUsed.map { "Last used \($0.formatted(date: .abbreviated, time: .omitted))." }
                ?? "Last-used date not recorded."
            var badges: Set<Badge> = []
            if let last = app.lastUsed, env.now.timeIntervalSince(last) > Classifier.staleAge { badges.insert(.stale) }
            let version = app.version.map { " Version \($0)." } ?? ""
            out.findings.append(RawFinding(
                category: .apps, kind: .app, name: app.name, paths: [app.url], identifier: app.bundleID,
                preset: PresetAttribution(
                    owner: Owner(bundleID: app.bundleID, displayName: app.name, teamID: app.teamID),
                    status: isApple ? .apple : .installed, confidence: .high,
                    evidence: Evidence(rule: "installedApp", detail: "Found in \(app.url.deletingLastPathComponent().path).")),
                badges: badges, modified: app.lastUsed, detail: "\(source) \(used)\(version)",
                inSystemDomain: false))
        }
        return out
    }
}
