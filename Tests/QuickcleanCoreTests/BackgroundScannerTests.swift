import Foundation
import Testing
@testable import QuickcleanCore

private let sysextOutput = """
4 extension(s)
--- com.apple.system_extension.network_extension (Go to 'System Settings > General > Login Items & Extensions > Network Extensions' to modify these system extension(s))
enabled\tactive\tteamID\tbundleID (version)\tname\t[state]
*\t*\tW5364U7YZB\tio.tailscale.ipn.macsys.network-extension (1.98.8/101.98.8)\tTailscale Network Extension\t[activated enabled]
\t\tYHUG37CKN8\tcom.surfshark.vpnclient.macos.direct.TransparentProxy (4.29.0/4541)\tSurfshark. TransparentProxy\t[terminated waiting to uninstall on reboot]
--- com.apple.system_extension.cmio (Go to 'System Settings')
enabled\tactive\tteamID\tbundleID (version)\tname\t[state]

"""

private let launchctlOutput = "PID\tStatus\tLabel\n123\t0\tcom.alexzielenski.mousecloak.listener\n-\t0\tcom.apple.x\n"

private func scan(_ fx: Fixture, commands: [String: CommandResult]? = nil) async -> ScanOutput {
    let cmds = commands ?? [
        "/usr/bin/systemextensionsctl list": .ok(sysextOutput),
        "/bin/launchctl list": .ok(launchctlOutput),
    ]
    return await BackgroundScanner().scan(fx.env(commands: cmds), index: AppIndex(apps: []))
}

@Test func launchAgentWithMissingProgramIsBroken() async throws {
    let fx = try Fixture()
    let program = fx.home.appending(path: "Library/Application Support/Mousecape/listener").path
    try fx.plist("home/Library/LaunchAgents/com.alexzielenski.mousecloak.listener.plist", [
        "Label": "com.alexzielenski.mousecloak.listener", "ProgramArguments": [program], "RunAtLoad": true,
    ])
    let out = await scan(fx)
    let agent = try #require(out.findings.first { $0.kind == .launchAgent })
    #expect(agent.identifier == "com.alexzielenski.mousecloak.listener")
    #expect(agent.programPath == program)
    #expect(agent.badges.contains(.broken))
    #expect(agent.badges.contains(.running))
    #expect(agent.detail?.contains("no longer exists") == true)
    #expect(agent.detail?.contains("Starts automatically") == true)
    #expect(agent.inSystemDomain == false)
}

@Test func daemonsHelpersAndKextsInSystemDomain() async throws {
    let fx = try Fixture()
    try fx.plist("root/Library/LaunchDaemons/com.gone.daemon.plist", [
        "Label": "com.gone.daemon", "Program": "/Applications/Gone.app/Contents/MacOS/d",
    ])
    try fx.file("root/Library/PrivilegedHelperTools/com.gone.helper")
    try fx.bundle("root/Library/Extensions/Foo.kext", id: "com.foo.driver")
    let out = await scan(fx)
    let kinds = Dictionary(out.findings.map { ($0.identifier ?? "", $0.kind) }, uniquingKeysWith: { a, _ in a })
    #expect(kinds["com.gone.daemon"] == .launchDaemon)
    #expect(kinds["com.gone.helper"] == .privilegedHelper)
    #expect(kinds["com.foo.driver"] == .kext)
    let nonExtensions = out.findings.filter { $0.kind != .systemExtension }
    #expect(nonExtensions.allSatisfy { $0.inSystemDomain })
}

@Test func malformedPlistStillReportedWithIssue() async throws {
    let fx = try Fixture()
    try fx.file("home/Library/LaunchAgents/com.bad.agent.plist", "not a plist")
    let out = await scan(fx)
    #expect(out.findings.contains { $0.identifier == "com.bad.agent" && $0.kind == .launchAgent })
    #expect(out.issues.contains { $0.subject.hasSuffix("com.bad.agent.plist") })
}

@Test func systemExtensionsParsedFromCommand() async throws {
    let fx = try Fixture()
    let out = await scan(fx)
    let exts = out.findings.filter { $0.kind == .systemExtension }
    #expect(exts.map(\.identifier) == ["io.tailscale.ipn.macsys.network-extension", "com.surfshark.vpnclient.macos.direct.TransparentProxy"])
    #expect(exts.first?.name == "Tailscale Network Extension")
    #expect(exts.first?.preset?.status == .orphaned)
    #expect(exts.first?.preset?.owner?.teamID == "W5364U7YZB")
}

@Test func systemExtensionOfInstalledTeamIsInstalled() async throws {
    let fx = try Fixture()
    let ts = InstalledApp(bundleID: "io.tailscale.ipn.macsys", name: "Tailscale", version: nil, teamID: "W5364U7YZB",
                          isAppleSigned: false, source: .manual, url: URL(fileURLWithPath: "/Applications/Tailscale.app"), lastUsed: nil)
    let env = fx.env(commands: ["/usr/bin/systemextensionsctl list": .ok(sysextOutput), "/bin/launchctl list": .ok("")])
    let out = await BackgroundScanner().scan(env, index: AppIndex(apps: [ts]))
    let ext = try #require(out.findings.first { $0.identifier?.hasPrefix("io.tailscale") == true })
    #expect(ext.preset?.status == .installed)
    #expect(ext.preset?.owner?.displayName == "Tailscale")
}

@Test func loginItemsProduceSingleInformationalIssue() async throws {
    let fx = try Fixture()
    let out = await scan(fx)
    #expect(out.issues.filter { $0.subject == "Login Items" }.count == 1)
}

@Test func failingCommandsBecomeIssues() async throws {
    let fx = try Fixture()
    let out = await scan(fx, commands: [:])
    #expect(out.issues.contains { $0.subject.contains("systemextensionsctl") })
    #expect(out.findings.isEmpty)
}
