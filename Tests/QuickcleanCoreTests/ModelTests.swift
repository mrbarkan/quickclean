import Foundation
import Testing
@testable import QuickcleanCore

@Test func findingRoundTripsThroughJSON() throws {
    let f = Finding(
        id: "leftovers:/x", category: .leftovers, kind: .cache, title: "Spotify · Cache",
        paths: ["/x"], size: 10,
        owner: Owner(bundleID: "com.spotify.client", displayName: "Spotify", teamID: nil),
        ownerStatus: .orphaned, confidence: .high, risk: .safe, badges: [.stale], explanation: "e",
        evidence: [Evidence(rule: "exactBundleID", detail: "d")], modified: Date(timeIntervalSince1970: 0),
        defaultSelected: true, protectedReason: nil)
    let data = try JSONEncoder().encode(f)
    #expect(try JSONDecoder().decode(Finding.self, from: data) == f)
}

@Test func riskAndConfidenceAreOrdered() {
    #expect(Risk.safe < .review && Risk.review < .careful && Risk.careful < .protected)
    #expect(Confidence.none < .low && Confidence.low < .medium && Confidence.medium < .high)
}
