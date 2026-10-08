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
        return out
    }
}
