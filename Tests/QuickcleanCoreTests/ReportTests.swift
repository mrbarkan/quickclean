import Foundation
import Testing
@testable import QuickcleanCore

private func finding(_ id: String, _ category: ScanCategory, _ kind: Kind, owner: String?, status: OwnerStatus,
                     size: Int64?, risk: Risk = .review) -> Finding {
    Finding(id: id, category: category, kind: kind, title: id, paths: ["/x/\(id)"], size: size,
            owner: owner.map { Owner(bundleID: nil, displayName: $0, teamID: nil) }, ownerStatus: status,
            confidence: .high, risk: risk, badges: [], explanation: "e", evidence: [], modified: nil,
            defaultSelected: false, protectedReason: nil)
}

private let sample = [
    finding("a", .leftovers, .cache, owner: "Adobe", status: .orphaned, size: 3_000_000, risk: .safe),
    finding("b", .leftovers, .appSupport, owner: "Adobe", status: .orphaned, size: 1_000_000),
    finding("c", .leftovers, .cache, owner: "Spotify", status: .orphaned, size: 500_000, risk: .safe),
    finding("d", .background, .launchAgent, owner: "Mousecape", status: .orphaned, size: 1_000, risk: .careful),
    finding("e", .addons, .inputMethod, owner: nil, status: .unknown, size: 10, risk: .careful),
    finding("f", .addons, .font, owner: nil, status: .unknown, size: 10, risk: .careful),
    finding("g", .apps, .app, owner: "Foo", status: .installed, size: 9_000_000),
]

@Test func overviewTotalsAndOrphans() {
    let o = Overview(findings: sample, reference: .bundled)
    #expect(o.totals[.leftovers]?.count == 3)
    #expect(o.totals[.leftovers]?.bytes == 4_500_000)
    #expect(o.orphanBytes == 4_501_000)
    #expect(o.topOrphanOwners.first?.name == "Adobe")
    #expect(o.topOrphanOwners.first?.bytes == 4_000_000)
    #expect(o.topOrphanOwners.first?.count == 2)
}

@Test func overviewCustomizations() {
    let o = Overview(findings: sample, reference: .bundled)
    #expect(Set(o.customizations.map(\.id)) == ["d", "e"])
}

@Test func reportJSONRoundTrips() throws {
    let r = Report(version: "0.0.1", generatedAt: Date(timeIntervalSince1970: 0), findings: sample, issues: [ScanIssue(subject: "s", reason: "r")])
    let back = try JSONDecoder.report.decode(Report.self, from: try r.json())
    #expect(back.findings == sample)
    #expect(back.version == "0.0.1")
}

@Test func reportMarkdownHasSectionsAndIssues() {
    let md = Report(version: "0.0.1", generatedAt: Date(timeIntervalSince1970: 0), findings: sample,
                    issues: [ScanIssue(subject: "Login Items", reason: "r")]).markdown()
    #expect(md.contains("## Leftovers"))
    #expect(md.contains("## Customizations still active"))
    #expect(md.contains("## Issues"))
    #expect(md.contains("Login Items"))
    #expect(md.contains("| Title | Owner | Status | Risk | Confidence | Size |"))
}

@Test(arguments: [(Int64(1_500_000), "1.5 MB"), (Int64(2_000_000_000), "2 GB")])
func byteFormat(bytes: Int64, expected: String) {
    #expect(ByteFormat.string(bytes, locale: Locale(identifier: "en_US")) == expected)
}

@Test func byteFormatFollowsLocale() {
    #expect(ByteFormat.string(1_500_000, locale: Locale(identifier: "pt_BR")) == "1,5 MB")
}

@Test func byteFormatNil() { #expect(ByteFormat.string(nil) == "—") }
