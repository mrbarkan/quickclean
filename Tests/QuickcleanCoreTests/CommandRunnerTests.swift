import Foundation
import Testing
@testable import QuickcleanCore

@Test func processRunnerCapturesOutput() async throws {
    let r = try await ProcessCommandRunner().run("/bin/echo", ["hi"], timeout: 5)
    #expect(r.status == 0)
    #expect(r.stdout == "hi\n")
}

@Test func processRunnerTimesOut() async {
    let start = Date()
    await #expect(throws: CommandError.self) {
        try await ProcessCommandRunner().run("/bin/sleep", ["5"], timeout: 0.3)
    }
    #expect(Date().timeIntervalSince(start) < 3)
}

@Test func processRunnerReportsMissingExecutable() async {
    await #expect(throws: CommandError.self) {
        try await ProcessCommandRunner().run("/nonexistent/x", [], timeout: 1)
    }
}

@Test func plistPreferencesReaderReadsGlobalDomainFile() throws {
    let fx = try Fixture()
    try fx.plist("home/Library/Preferences/.GlobalPreferences.plist", ["AppleShowAllExtensions": true])
    try fx.plist("home/Library/Preferences/com.apple.dock.plist", ["autohide": true])
    let reader = PlistPreferencesReader(home: fx.home)
    #expect(reader.values(domain: "NSGlobalDomain")?["AppleShowAllExtensions"] as? Bool == true)
    #expect(reader.values(domain: "com.apple.dock")?["autohide"] as? Bool == true)
    #expect(reader.values(domain: "com.missing") == nil)
}

@Test func liveInspectorRecognizesAppleSignedApp() {
    let sig = LiveBundleInspector().signature(of: URL(fileURLWithPath: "/System/Applications/Calculator.app"))
    #expect(sig.isApple)
}

@Test func liveInspectorTreatsUnsignedFolderAsNotApple() throws {
    let fx = try Fixture()
    let app = try fx.bundle("root/Applications/Fake.app", id: "com.fake.app")
    #expect(LiveBundleInspector().signature(of: app) == SignatureInfo(teamID: nil, isApple: false))
}
