import Foundation

public enum ByteFormat {
    public static func string(_ bytes: Int64?, locale: Locale = .current) -> String {
        guard let bytes else { return "—" }
        return bytes.formatted(.byteCount(style: .file).locale(locale))
    }
}

/// The numbers behind the Overview screen and the CLI summary.
public struct Overview: Sendable {
    public struct Total: Sendable, Equatable { public var count = 0; public var bytes: Int64 = 0 }
    public struct OwnerTotal: Sendable, Equatable { public var name: String; public var count: Int; public var bytes: Int64 }

    public var totals: [ScanCategory: Total] = [:]
    public var orphanBytes: Int64 = 0
    /// Third-party items that still change how macOS looks or behaves.
    public var customizations: [Finding] = []
    public var topOrphanOwners: [OwnerTotal] = []
    /// macOS settings that differ from a clean install.
    public var changedSettings: [Finding] = []

    static let behaviorKinds: Set<Kind> = [
        .inputMethod, .preferencePane, .screenSaver, .mailBundle, .safariExtension, .internetPlugin, .kext,
    ]

    public init(findings: [Finding], reference: ReferenceData) {
        let customizingNames = Set(reference.knownApps.filter(\.customization).map(\.name))
        var owners: [String: OwnerTotal] = [:]
        for f in findings {
            totals[f.category, default: Total()].count += 1
            totals[f.category, default: Total()].bytes += f.size ?? 0
            if f.ownerStatus == .orphaned {
                orphanBytes += f.size ?? 0
                let name = f.owner?.displayName ?? "Unknown"
                owners[name, default: OwnerTotal(name: name, count: 0, bytes: 0)].count += 1
                owners[name, default: OwnerTotal(name: name, count: 0, bytes: 0)].bytes += f.size ?? 0
            }
            if f.kind == .settingsKey { changedSettings.append(f) }
            let byOwner = f.owner.map { customizingNames.contains($0.displayName) } ?? false
            if f.ownerStatus != .apple, f.risk != .protected, f.category != .apps,
               byOwner || Self.behaviorKinds.contains(f.kind) {
                customizations.append(f)
            }
        }
        topOrphanOwners = owners.values.sorted { ($0.bytes, $1.name) > ($1.bytes, $0.name) }
    }
}

public struct Report: Codable, Sendable {
    public var tool = "quickclean"
    public var version: String
    public var generatedAt: Date
    public var findings: [Finding]
    public var issues: [ScanIssue]

    public init(version: String, generatedAt: Date, findings: [Finding], issues: [ScanIssue]) {
        self.version = version
        self.generatedAt = generatedAt
        self.findings = findings
        self.issues = issues
    }

    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public func markdown(reference: ReferenceData = .bundled) -> String {
        let overview = Overview(findings: findings, reference: reference)
        var md = "# Quickclean report\n\nGenerated \(generatedAt.formatted(.iso8601)) by Quickclean \(version).\n\n"
        md += "Orphaned items take up **\(ByteFormat.string(overview.orphanBytes))**.\n\n"
        if !overview.customizations.isEmpty {
            md += "## Customizations still active\n\n"
            for f in overview.customizations { md += "- **\(f.title)** — \(f.explanation)\n" }
            md += "\n"
        }
        if !overview.changedSettings.isEmpty {
            md += "## Changed macOS settings\n\n"
            for f in overview.changedSettings { md += "- **\(f.title)** — \(f.explanation)\n" }
            md += "\n"
        }
        for category in ScanCategory.allCases {
            let items = findings.filter { $0.category == category }
            guard !items.isEmpty else { continue }
            let total = overview.totals[category] ?? Overview.Total()
            md += "## \(category.label) (\(items.count), \(ByteFormat.string(total.bytes)))\n\n"
            md += "| Title | Owner | Status | Risk | Confidence | Size |\n|---|---|---|---|---|---|\n"
            for f in items {
                let title = f.title.replacingOccurrences(of: "|", with: "\\|")
                md += "| \(title) | \(f.owner?.displayName ?? "—") | \(f.ownerStatus.rawValue) | \(f.risk.rawValue) | \(f.confidence.rawValue) | \(ByteFormat.string(f.size)) |\n"
            }
            md += "\n"
        }
        if !issues.isEmpty {
            md += "## Issues\n\n"
            for i in issues { md += "- **\(i.subject)**: \(i.reason)\n" }
        }
        return md
    }
}

extension JSONDecoder {
    public static var report: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
