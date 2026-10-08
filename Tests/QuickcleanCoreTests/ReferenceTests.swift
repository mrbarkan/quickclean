import Foundation
import Testing
@testable import QuickcleanCore

@Test func bundledReferenceLoads() {
    let ref = ReferenceData.bundled
    #expect(!ref.defaults.isEmpty)
    #expect(!ref.knownApps.isEmpty)
    #expect(ref.defaults.allSatisfy { !$0.title.isEmpty && !$0.domain.isEmpty && !$0.key.isEmpty })
}

@Test func knownAppMatchesMousecapeHelperLabel() {
    let app = ReferenceData.bundled.knownApp(for: "com.alexzielenski.mousecloak.listener")
    #expect(app?.name == "Mousecape")
    #expect(app?.customization == true)
}

@Test func knownAppMatchesPlainFolderNameCaseInsensitively() {
    #expect(ReferenceData.bundled.knownApp(for: "Adobe")?.name == "Adobe")
    #expect(ReferenceData.bundled.knownApp(for: "nothing-like-this") == nil)
}

@Test func knownAppPrefersLongestPattern() {
    let ref = ReferenceData(
        stock: StockReference(appBundleIDs: [], appleNames: [], protectedHomePaths: []), defaults: [],
        knownApps: [
            KnownApp(pattern: "com.google", name: "Google", bundleID: nil, customization: false, note: ""),
            KnownApp(pattern: "com.google.keystone", name: "Google Software Update", bundleID: nil, customization: false, note: ""),
        ])
    #expect(ref.knownApp(for: "com.google.keystone.agent")?.name == "Google Software Update")
}

@Test func jsonValueDistinguishesBoolFromNumber() {
    #expect(JSONValue(any: true) == .bool(true))
    #expect(JSONValue(any: NSNumber(value: true)) == .bool(true))
    #expect(JSONValue(any: NSNumber(value: 48)) == .number(48))
    #expect(JSONValue(any: 1) == .number(1))
    #expect(JSONValue(any: "bottom") == .string("bottom"))
    #expect(JSONValue(any: [1, 2]) == nil)
}

@Test func stockAppleNamesAreCaseInsensitive() {
    let stock = StockReference(appBundleIDs: [], appleNames: ["geoservices"], protectedHomePaths: [])
    #expect(stock.isAppleName("GeoServices"))
    #expect(!stock.isAppleName("Spotify"))
}

@Test func knownAppPatternsMatchOnWordBoundaries() {
    let ref = ReferenceData(
        stock: StockReference(appBundleIDs: [], appleNames: [], protectedHomePaths: []), defaults: [],
        knownApps: [KnownApp(pattern: "logi", name: "Logitech", bundleID: nil, customization: true, note: "")])
    #expect(ref.knownApp(for: "LoginItems") == nil)
    #expect(ref.knownApp(for: "logi") != nil)
    #expect(ref.knownApp(for: "Logi Options+") != nil)
    #expect(ref.knownApp(for: "logi.options.agent") != nil)
}
