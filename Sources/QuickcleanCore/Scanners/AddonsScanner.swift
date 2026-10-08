import Foundation

/// Plugins and extras that hook into macOS or its apps.
public struct AddonsScanner: Scanner {
    public var category: Category { .addons }

    static let shared: [(String, Kind)] = [
        ("QuickLook", .quickLookPlugin), ("Spotlight", .spotlightImporter), ("PreferencePanes", .preferencePane),
        ("Input Methods", .inputMethod), ("Fonts", .font), ("ColorSync/Profiles", .colorProfile),
        ("Screen Savers", .screenSaver), ("Audio/Plug-Ins/Components", .audioPlugin), ("Audio/Plug-Ins/VST", .audioPlugin),
        ("Audio/Plug-Ins/VST3", .audioPlugin), ("Audio/Plug-Ins/HAL", .audioPlugin), ("Internet Plug-Ins", .internetPlugin),
    ]
    static let userOnly: [(String, Kind)] = [("Safari/Extensions", .safariExtension), ("Mail/Bundles", .mailBundle)]
    static let behaviorChanging: Set<Kind> = [.inputMethod, .preferencePane, .screenSaver, .mailBundle, .safariExtension, .internetPlugin]

    public init() {}

    public func scan(_ env: ScanEnvironment, index: AppIndex) async -> ScanOutput {
        var out = ScanOutput()
        let places: [(URL, Kind, Bool)] =
            Self.shared.map { (env.homePath("Library/\($0.0)"), $0.1, false) }
            + Self.shared.map { (env.path("Library/\($0.0)"), $0.1, true) }
            + Self.userOnly.map { (env.homePath("Library/\($0.0)"), $0.1, false) }
        for (dir, kind, system) in places {
            for url in Listing.children(dir, into: &out) {
                let info = Listing.bundleInfo(url)
                let id = info?["CFBundleIdentifier"] as? String ?? url.deletingPathExtension().lastPathComponent
                let name = info?["CFBundleName"] as? String ?? url.deletingPathExtension().lastPathComponent
                out.findings.append(RawFinding(
                    category: .addons, kind: kind, name: name, paths: [url], identifier: id,
                    modified: Listing.modified(url),
                    detail: Self.behaviorChanging.contains(kind) ? "Changes how macOS looks or behaves." : nil,
                    inSystemDomain: system))
            }
        }
        return out
    }
}
