import Foundation
import Testing
@testable import QuickcleanCore

/// Background regressions from the real-data audit.

private let launchctl = """
PID\tStatus\tLabel
-\t0\tcom.idle.agent
123\t0\tcom.live.agent
76733\t0\tcom.microsoft.teams2.agent
-\t0\tcom.1password.1password-launcher
940\t0\tapplication.com.adobe.CCXProcess.81722046.81722052
7012\t0\tcom.openssh.ssh-agent
1\t0\tcom.apple.something
"""

private func scan(_ fx: Fixture, ps: String = "", running: Set<String> = []) async -> ScanOutput {
    let env = fx.env(commands: [
        "/bin/launchctl list": .ok(launchctl),
        "/bin/ps -axo comm=": .ok(ps),
        "/usr/bin/systemextensionsctl list": .ok(""),
    ], running: running)
    return await BackgroundScanner().scan(env, index: AppIndex(apps: []))
}

@Test func runningMeansHasAProcessNotJustLoaded() async throws {
    let fx = try Fixture()
    try fx.plist("home/Library/LaunchAgents/com.idle.agent.plist", ["Label": "com.idle.agent"])
    try fx.plist("home/Library/LaunchAgents/com.live.agent.plist", ["Label": "com.live.agent"])
    let out = await scan(fx)
    #expect(out.findings.first { $0.identifier == "com.idle.agent" }?.badges.contains(.running) == false)
    #expect(out.findings.first { $0.identifier == "com.live.agent" }?.badges.contains(.running) == true)
}

@Test func daemonWhoseProgramIsRunningIsRunning() async throws {
    let fx = try Fixture()
    let program = fx.root.appending(path: "Library/PrivilegedHelperTools/com.borisfx.helper").path
    try fx.file("root/Library/PrivilegedHelperTools/com.borisfx.helper")
    try fx.plist("root/Library/LaunchDaemons/com.borisfx.helper.plist", ["Label": "com.borisfx.helper", "Program": program])
    let out = await scan(fx, ps: "/sbin/launchd\n\(program)\n")
    #expect(out.findings.first { $0.kind == .launchDaemon }?.badges.contains(.running) == true)
    #expect(out.findings.first { $0.kind == .privilegedHelper }?.badges.contains(.running) == true)
}

@Test func emptyLaunchdPlistIsCalledOut() async throws {
    let fx = try Fixture()
    try fx.plist("home/Library/LaunchAgents/com.google.keystone.agent.plist", [:])
    let out = await scan(fx)
    let f = try #require(out.findings.first { $0.identifier == "com.google.keystone.agent" })
    #expect(f.detail?.contains("Empty") == true)
}

@Test func systemExtensionsGetTheirStagedPath() async throws {
    let fx = try Fixture()
    try fx.dir("root/Library/SystemExtensions/1406D3B1-1F6E-439E-B85E-06574737A6BD/io.tailscale.ipn.macsys.network-extension.systemextension")
    let sysext = "*\t*\tW5364U7YZB\tio.tailscale.ipn.macsys.network-extension (1.98.8/101.98.8)\tTailscale Network Extension\t[activated enabled]\n"
    let env = fx.env(commands: ["/bin/launchctl list": .ok(""), "/bin/ps -axo comm=": .ok(""),
                                "/usr/bin/systemextensionsctl list": .ok(sysext)])
    let out = await BackgroundScanner().scan(env, index: AppIndex(apps: []))
    let f = try #require(out.findings.first { $0.kind == .systemExtension })
    #expect(f.paths.first?.lastPathComponent == "io.tailscale.ipn.macsys.network-extension.systemextension")
}

@Test func jobsRegisteredWithoutPlistAreReported() async throws {
    let fx = try Fixture()
    try fx.plist("home/Library/LaunchAgents/com.idle.agent.plist", ["Label": "com.idle.agent"])
    try fx.plist("home/Library/LaunchAgents/com.live.agent.plist", ["Label": "com.live.agent"])
    let out = await scan(fx)
    let jobs = out.findings.filter { $0.kind == .loginItems }
    #expect(Set(jobs.compactMap(\.identifier)) == ["com.microsoft.teams2.agent", "com.1password.1password-launcher"])
    #expect(jobs.first { $0.identifier == "com.microsoft.teams2.agent" }?.badges.contains(.running) == true)
}

@Test func backgroundItemsIgnoreOwnerRunningAndFileAge() {
    let env = ScanEnvironment(home: URL(fileURLWithPath: "/Users/t"), root: URL(fileURLWithPath: "/"),
                              commands: StubCommandRunner([:]), bundles: StubBundleInspector([:]),
                              preferences: DictPreferences([:]), now: Fixture.now, runningBundleIDs: ["com.adobe.app"])
    let raw = RawFinding(category: .background, kind: .launchAgent, name: "x", paths: [URL(fileURLWithPath: "/Library/LaunchAgents/x.plist")],
                         identifier: "x", modified: Fixture.now.addingTimeInterval(-400 * 86_400))
    let a = Attribution(owner: Owner(bundleID: "com.adobe.app", displayName: "Adobe", teamID: nil), status: .installed,
                        confidence: .medium, evidence: [])
    let f = Classifier(reference: .bundled, env: env).classify(raw, a)
    #expect(!f.badges.contains(.running))
    #expect(!f.badges.contains(.stale))
}

@Test func sshAgentIsApple() {
    let a = Attributor(index: AppIndex(apps: []), reference: .bundled)
        .attribute(RawFinding(category: .background, kind: .loginItems, name: "x", paths: [], identifier: "com.openssh.ssh-agent"))
    #expect(a.status == .apple)
}
