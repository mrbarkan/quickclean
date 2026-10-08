import Foundation

/// macOS settings whose current value differs from a clean install's default.
public struct SettingsScanner: Scanner {
    public var category: ScanCategory { .settings }
    let reference: ReferenceData

    public init(reference: ReferenceData = .bundled) { self.reference = reference }

    public func scan(_ env: ScanEnvironment, index: AppIndex) async -> ScanOutput {
        var out = ScanOutput()
        let byDomain = Dictionary(grouping: reference.defaults, by: \.domain)
        for domain in byDomain.keys.sorted() {
            guard let values = env.preferences.values(domain: domain) else { continue }
            let file = env.homePath("Library/Preferences/\(domain == "NSGlobalDomain" ? ".GlobalPreferences" : domain).plist")
            for setting in byDomain[domain] ?? [] {
                guard let raw = values[setting.key] else { continue }
                let current = JSONValue(any: raw)
                if setting.defaultValue != .null, current?.sameSetting(as: setting.defaultValue) == true { continue }
                // With automatic appearance, macOS writes Dark every evening by itself.
                if setting.key == "AppleInterfaceStyle", values["AppleInterfaceStyleSwitchesAutomatically"] as? Bool == true { continue }
                let shown = current?.display ?? "customized"
                let defaultShown = setting.defaultValue.display
                var detail = "\(domain) › \(setting.key) is \(shown); macOS default is \(defaultShown)."
                if let note = setting.note { detail += " \(note)" }
                detail += " Reset will be available in a later version."
                out.findings.append(RawFinding(
                    category: .settings, kind: .settingsKey, name: setting.title, paths: [file], identifier: domain,
                    preset: PresetAttribution(
                        owner: Owner(bundleID: domain, displayName: "macOS", teamID: nil), status: .apple, confidence: .high,
                        evidence: Evidence(rule: "defaults", detail: "Compared with the macOS 27 default for this setting.")),
                    detail: detail, idOverride: "settings:\(domain):\(setting.key)"))
            }
        }
        scanWallpaper(env, into: &out)
        return out
    }

    /// Wallpapers whose image lives inside an app bundle (theming apps) or no longer exists.
    private func scanWallpaper(_ env: ScanEnvironment, into out: inout ScanOutput) {
        let index = env.homePath("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
        guard let data = try? Data(contentsOf: index),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
        else { return }
        var seen = Set<String>()
        for url in Self.fileURLs(in: plist) {
            let path = url.path
            guard !Self.isAppleWallpaperStore(path), seen.insert(path).inserted else { continue }
            let inApp = Identifier.appName(fromPath: path)
            let missing = !FileManager.default.fileExists(atPath: path)
            guard inApp != nil || missing else { continue }
            let detail = inApp.map { "The desktop picture is an image inside \($0).app, so it disappears or breaks if that app is removed." }
                ?? "The desktop picture points to \(path), which no longer exists."
            // A missing image has nothing to attribute it to; the setting itself is the finding.
            let preset = inApp == nil ? PresetAttribution(
                owner: Owner(bundleID: nil, displayName: "Wallpaper setting", teamID: nil), status: .unknown, confidence: .medium,
                evidence: Evidence(rule: "wallpaperMissing", detail: "The wallpaper index points to a file that doesn't exist.")) : nil
            out.findings.append(RawFinding(
                category: .settings, kind: .settingsReference,
                name: inApp.map { "Wallpaper from \($0)" } ?? "Wallpaper image is missing",
                paths: [index], identifier: inApp ?? "wallpaper", programPath: path, preset: preset,
                badges: missing ? [.broken] : [], detail: detail, idOverride: "settings:wallpaper:\(path)"))
        }
    }

    /// Images macOS manages itself (built-in pictures and downloaded wallpaper caches it refills).
    static func isAppleWallpaperStore(_ path: String) -> Bool {
        path.hasPrefix("/System/") || path.hasPrefix("/Library/Desktop Pictures/")
            || path.contains("/com.apple.mobileAssetDesktop/") || path.contains("/com.apple.idleassetsd/")
    }

    /// Every file:// URL in a property list, including inside nested binary plists.
    static func fileURLs(in value: Any) -> [URL] {
        switch value {
        case let dict as [String: Any]: return dict.values.flatMap(fileURLs(in:))
        case let array as [Any]: return array.flatMap(fileURLs(in:))
        case let data as Data:
            guard let inner = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return [] }
            return fileURLs(in: inner)
        case let string as String where string.hasPrefix("file://"):
            return URL(string: string).map { [$0] } ?? []
        default:
            return []
        }
    }
}
