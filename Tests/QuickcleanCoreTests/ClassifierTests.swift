import Foundation
import Testing
@testable import QuickcleanCore

private let home = URL(fileURLWithPath: "/Users/test")
private let env = ScanEnvironment(
    home: home, root: URL(fileURLWithPath: "/"), commands: StubCommandRunner([:]),
    bundles: StubBundleInspector([:]), preferences: DictPreferences([:]), now: Fixture.now,
    runningBundleIDs: ["com.running.app"])
private let classifier = Classifier(reference: ReferenceData.bundled, env: env)

private func raw(
    _ kind: Kind, path: String = "/Users/test/Library/Caches/x", override: Risk? = nil,
    system: Bool = false, modified: Date? = nil, badges: Set<Badge> = []
) -> RawFinding {
    RawFinding(category: .leftovers, kind: kind, name: "x", paths: [URL(fileURLWithPath: path)],
               identifier: "x", badges: badges, modified: modified, riskOverride: override, inSystemDomain: system)
}

private func attr(_ status: OwnerStatus, _ confidence: Confidence, bundleID: String? = "com.x.app") -> Attribution {
    Attribution(owner: Owner(bundleID: bundleID, displayName: "X", teamID: nil), status: status,
                confidence: confidence, evidence: [Evidence(rule: "r", detail: "Because.")])
}

@Test(arguments: [
    (Kind.cache, OwnerStatus.orphaned, Confidence.high, Risk.safe),
    (.logs, .orphaned, .high, .safe),
    (.savedState, .orphaned, .medium, .safe),
    (.cache, .installed, .high, .review),
    (.preferences, .orphaned, .high, .review),
    (.appSupport, .orphaned, .high, .review),
    (.launchAgent, .orphaned, .high, .careful),
    (.privilegedHelper, .installed, .high, .careful),
    (.cache, .orphaned, .low, .careful),
    (.cache, .unknown, .none, .careful),
    (.cache, .apple, .high, .protected),
])
func riskTable(kind: Kind, status: OwnerStatus, confidence: Confidence, expected: Risk) {
    #expect(classifier.risk(raw(kind), attr(status, confidence)).0 == expected)
}

@Test func riskOverrideAppliesBelowCareful() {
    #expect(classifier.risk(raw(.devCache, override: .safe), attr(.installed, .high)).0 == .safe)
    #expect(classifier.risk(raw(.devCache, override: .safe), attr(.installed, .low)).0 == .careful)
}

@Test func systemDomainIsCareful() {
    #expect(classifier.risk(raw(.cache, path: "/Library/Caches/x", system: true), attr(.orphaned, .high)).0 == .careful)
}

@Test func protectedPathsAndKinds() {
    let ssh = classifier.risk(raw(.dotfile, path: "/Users/test/.ssh"), attr(.unknown, .none))
    #expect(ssh.0 == .protected && ssh.1 != nil)
    #expect(classifier.risk(raw(.appSupport, path: "/Users/test/Documents/x"), attr(.orphaned, .high)).0 == .protected)
    #expect(classifier.risk(raw(.settingsKey), attr(.apple, .high)).0 == .protected)
    #expect(classifier.risk(raw(.cache, path: "/System/Library/x"), attr(.orphaned, .high)).0 == .protected)
}

@Test func defaultSelectionOnlyForSafeHighOrphans() {
    #expect(classifier.classify(raw(.cache), attr(.orphaned, .high)).defaultSelected)
    #expect(!classifier.classify(raw(.cache), attr(.orphaned, .medium)).defaultSelected)
    #expect(!classifier.classify(raw(.preferences), attr(.orphaned, .high)).defaultSelected)
    #expect(!classifier.classify(raw(.cache), attr(.installed, .high)).defaultSelected)
}

@Test func runningItemsAreNeverPreselected() {
    let f = classifier.classify(raw(.cache), attr(.orphaned, .high, bundleID: "com.running.app"))
    #expect(f.badges.contains(.running))
    #expect(!f.defaultSelected)
}

@Test func staleBadgeAfter180Days() {
    let old = classifier.classify(raw(.cache, modified: Fixture.now.addingTimeInterval(-200 * 86_400)), attr(.orphaned, .high))
    let recent = classifier.classify(raw(.cache, modified: Fixture.now.addingTimeInterval(-100 * 86_400)), attr(.orphaned, .high))
    #expect(old.badges.contains(.stale))
    #expect(!recent.badges.contains(.stale))
}

@Test func titleIdAndPaths() {
    let f = classifier.classify(raw(.cache), attr(.orphaned, .high))
    #expect(f.title == "X · Cache")
    #expect(f.id == "leftovers:/Users/test/Library/Caches/x")
    #expect(f.paths == ["/Users/test/Library/Caches/x"])
}

@Test func explanationForOrphanedAgent() {
    var r = raw(.launchAgent, path: "/Users/test/Library/LaunchAgents/com.alexzielenski.mousecloak.listener.plist")
    r.detail = "Re-applies custom cursors at every login."
    let a = Attribution(owner: Owner(bundleID: nil, displayName: "Mousecape", teamID: nil), status: .orphaned,
                        confidence: .medium, evidence: [Evidence(rule: "knownApp", detail: "Matches the known pattern for Mousecape.")])
    let text = classifier.classify(r, a).explanation
    #expect(text.contains("~/Library/LaunchAgents"))
    #expect(text.contains("no longer installed"))
    #expect(text.contains("Re-applies custom cursors"))
    #expect(text.contains("Why: Matches the known pattern for Mousecape."))
}
