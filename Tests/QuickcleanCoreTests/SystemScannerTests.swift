import Foundation
import Testing
@testable import QuickcleanCore

private let pluginkitOutput = """
     com.apple.Photos.ReliveWidget(1.0)
\t            Path = /System/Applications/Photos.app/Contents/PlugIns/PhotosReliveWidget.appex
\t             SDK = com.apple.widgetkit-extension
\t    Display Name = PhotosReliveWidget

+    com.google.drivefs.finderhelper.findersync(132.0)
\t            Path = /Applications/Google Drive.app/Contents/Applications/FinderHelper.app/Contents/PlugIns/FinderSyncExtension.appex
\t             SDK = com.apple.FinderSync
\t   Parent Bundle = /Applications/Google Drive.app/Contents/Applications/FinderHelper.app
\t    Display Name = FinderSyncExtension

-    com.example.share(1.0)
\t            Path = /Applications/Example.app/Contents/PlugIns/Share.appex
\t             SDK = com.apple.share-services
\t    Display Name = Example Share

"""

private func systemFixture() throws -> (Fixture, ScanEnvironment) {
    let fx = try Fixture()
    // Command-line tools, frameworks, runtimes
    try fx.file("root/usr/local/bin/firebase")
    try fx.symlink("root/usr/local/bin/tailscale", to: fx.root.appending(path: "Applications/Tailscale.app/Contents/MacOS/Tailscale").path)
    try fx.symlink("root/usr/local/bin/node", to: "../Cellar/node/24/bin/node")
    try fx.plist("root/Library/Frameworks/Python.framework/Resources/Info.plist", ["CFBundleIdentifier": "org.python.python"])
    try fx.bundle("root/Library/Java/JavaVirtualMachines/openjdk.jdk", id: "net.java.openjdk.jdk")
    // Receipt payloads
    try fx.file("root/usr/local/bin/vtool")
    // /etc
    try fx.file("root/private/etc/hosts", "127.0.0.1\tlocalhost\n255.255.255.255\tbroadcasthost\n::1             localhost\n0.0.0.0 ads.example.com\n")
    try fx.file("root/private/etc/anydesk/connection_trace.txt")
    try fx.file("root/private/etc/paths.d/10-cryptex")
    try fx.file("root/private/etc/paths.d/homebrew")
    // Default handlers
    try fx.plist("home/Library/Preferences/com.apple.LaunchServices/com.apple.launchservices.secure.plist", ["LSHandlers": [
        ["LSHandlerURLScheme": "steam", "LSHandlerRoleAll": "com.valvesoftware.steam"],
        ["LSHandlerContentType": "public.html", "LSHandlerRoleViewer": "com.google.chrome"],
        ["LSHandlerURLScheme": "mailto", "LSHandlerRoleAll": "com.apple.mail"],
        ["LSHandlerURLScheme": "nothing", "LSHandlerRoleAll": "-"],
    ]])
    let pkg = "/usr/sbin/pkgutil"
    let env = fx.env(commands: [
        "\(pkg) --pkgs": .ok("com.apple.pkg.Core\ncom.tailscale.ipn.macsys\ncom.vendor.tool.pkg\n"),
        "\(pkg) --pkg-info com.tailscale.ipn.macsys": .ok("package-id: com.tailscale.ipn.macsys\nversion: 1.98.1\nvolume: /\nlocation: Applications/Tailscale.app\ninstall-time: 1778808385\n"),
        "\(pkg) --files com.tailscale.ipn.macsys": .ok("Contents\nContents/Info.plist\n"),
        "\(pkg) --pkg-info com.vendor.tool.pkg": .ok("package-id: com.vendor.tool.pkg\nversion: 2\nvolume: /\nlocation: usr/local/bin\ninstall-time: 1778808385\n"),
        "\(pkg) --files com.vendor.tool.pkg": .ok("vtool\n"),
        "/usr/bin/pluginkit -mAvvv": .ok(pluginkitOutput),
    ])
    return (fx, env)
}

private let reference = ReferenceData(
    stock: StockReference(appBundleIDs: [], appleNames: [], protectedHomePaths: [],
                          etcEntries: ["hosts", "paths.d", "paths.d/10-cryptex"]),
    defaults: [], knownApps: ReferenceData.bundled.knownApps)

private func scan() async throws -> (Fixture, ScanOutput) {
    let (fx, env) = try systemFixture()
    return (fx, await SystemScanner(reference: reference).scan(env, index: AppIndex(apps: [])))
}

@Test func receiptsReportWhetherTheirFilesRemain() async throws {
    let (fx, out) = try await scan()
    defer { withExtendedLifetime(fx) {} }
    let receipts = out.findings.filter { $0.kind == .pkgReceipt }
    #expect(Set(receipts.compactMap(\.identifier)) == ["com.tailscale.ipn.macsys", "com.vendor.tool"])
    let tailscale = try #require(receipts.first { $0.identifier == "com.tailscale.ipn.macsys" })
    #expect(tailscale.badges.contains(.broken))
    #expect(tailscale.detail?.contains("None of its files remain") == true)
    #expect(tailscale.programPath?.contains("Tailscale.app") == true)
    let tool = try #require(receipts.first { $0.identifier == "com.vendor.tool" })
    #expect(!tool.badges.contains(.broken))
}

@Test func thirdPartyDefaultHandlersAreListed() async throws {
    let (fx, out) = try await scan()
    defer { withExtendedLifetime(fx) {} }
    let handlers = out.findings.filter { $0.kind == .defaultHandler }
    #expect(Set(handlers.compactMap(\.identifier)) == ["com.valvesoftware.steam", "com.google.chrome"])
    #expect(handlers.first { $0.identifier == "com.valvesoftware.steam" }?.name.contains("steam:") == true)
    #expect(Set(handlers.compactMap(\.idOverride)).count == 2)
}

@Test func commandLineToolsFrameworksAndRuntimes() async throws {
    let (fx, out) = try await scan()
    defer { withExtendedLifetime(fx) {} }
    let tools = Dictionary(out.findings.filter { $0.kind == .commandLineTool }.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
    #expect(Set(tools.keys) == ["firebase", "tailscale", "vtool"])
    #expect(tools["tailscale"]?.badges.contains(.broken) == true)
    #expect(tools["tailscale"]?.programPath?.hasSuffix("Tailscale.app/Contents/MacOS/Tailscale") == true)
    #expect(tools["firebase"]?.inSystemDomain == true)
    let frameworks = Set(out.findings.filter { $0.kind == .framework }.compactMap(\.identifier))
    #expect(frameworks == ["org.python.python", "net.java.openjdk.jdk"])
}

@Test func thirdPartyAppExtensionsAreListed() async throws {
    let (fx, out) = try await scan()
    defer { withExtendedLifetime(fx) {} }
    let exts = out.findings.filter { $0.kind == .appExtension }
    #expect(Set(exts.compactMap(\.identifier)) == ["com.google.drivefs.finderhelper.findersync", "com.example.share"])
    let finder = try #require(exts.first { $0.identifier == "com.google.drivefs.finderhelper.findersync" })
    #expect(finder.detail?.contains("Finder") == true)
    #expect(finder.programPath?.contains("Google Drive.app") == true)
    #expect(exts.first { $0.identifier == "com.example.share" }?.detail?.contains("Turned off") == true)
}

@Test func etcChangesAreListed() async throws {
    let (fx, out) = try await scan()
    defer { withExtendedLifetime(fx) {} }
    let config = out.findings.filter { $0.kind == .systemConfig }
    #expect(Set(config.map(\.name)) == ["anydesk", "paths.d/homebrew", "hosts"])
    #expect(config.first { $0.name == "hosts" }?.detail?.contains("1 custom entry") == true)
    #expect(config.allSatisfy { $0.inSystemDomain })
}

@Test func missingCommandsBecomeIssues() async throws {
    let fx = try Fixture()
    let out = await SystemScanner(reference: reference).scan(fx.env(), index: AppIndex(apps: []))
    #expect(out.issues.contains { $0.subject.contains("pkgutil") })
    #expect(out.issues.contains { $0.subject.contains("pluginkit") })
}

@Test func sharedFolderIsScannedAsLeftovers() async throws {
    let fx = try Fixture()
    try fx.dir("root/Users/Shared/Paragon Software")
    try fx.dir("root/Users/Shared/SC Info")
    let out = await LeftoversScanner().scan(fx.env(), index: AppIndex(apps: []))
    #expect(out.findings.map(\.name) == ["Paragon Software"])
    #expect(out.findings.first?.inSystemDomain == true)
}

@Test func wallpaperPointingIntoAnAppIsReported() async throws {
    let fx = try Fixture()
    let image = fx.root.appending(path: "Applications/RetroMac.app/Contents/Resources/Themes/Maik.retromactheme/wallpaper.jpg")
    let config = try PropertyListSerialization.data(fromPropertyList: ["url": ["relative": image.absoluteString]], format: .binary, options: 0)
    let stock = try PropertyListSerialization.data(fromPropertyList: ["url": ["relative": "file:///System/Library/Desktop%20Pictures/Monterey.madesktop"]], format: .binary, options: 0)
    try fx.plist("home/Library/Application Support/com.apple.wallpaper/Store/Index.plist", [
        "Spaces": ["A": ["Default": ["Desktop": ["Content": ["Choices": [["Configuration": config, "Provider": "com.apple.wallpaper.choice.image"]]]]]],
                   "B": ["Default": ["Desktop": ["Content": ["Choices": [["Configuration": stock]]]]]]],
    ])
    let out = await SettingsScanner().scan(fx.env(preferences: [:]), index: AppIndex(apps: []))
    let refs = out.findings.filter { $0.kind == .settingsReference }
    #expect(refs.count == 1)
    #expect(refs.first?.programPath == image.path)
    #expect(refs.first?.name.contains("Wallpaper") == true)
}

@Test func systemChangesAreTitledByWhatTheyAre() {
    let env = ScanEnvironment(home: URL(fileURLWithPath: "/Users/t"), root: URL(fileURLWithPath: "/"),
                              commands: StubCommandRunner([:]), bundles: StubBundleInspector([:]),
                              preferences: DictPreferences([:]), now: Fixture.now, runningBundleIDs: [])
    let a = Attribution(owner: Owner(bundleID: nil, displayName: "Adobe", teamID: nil), status: .installed, confidence: .medium, evidence: [])
    let classifier = Classifier(reference: .bundled, env: env)
    for kind in [Kind.pkgReceipt, .defaultHandler, .commandLineTool, .framework, .appExtension, .systemConfig, .settingsReference] {
        let raw = RawFinding(category: .system, kind: kind, name: "Specific Thing", paths: [], identifier: "x")
        #expect(classifier.classify(raw, a).title == "Specific Thing", "\(kind)")
    }
}
