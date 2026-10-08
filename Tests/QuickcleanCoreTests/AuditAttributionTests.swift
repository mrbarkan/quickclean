import Foundation
import Testing
@testable import QuickcleanCore

/// Regressions from the real-data audit of 2026-10-08.

private func app(_ id: String, _ name: String, team: String? = nil, path: String? = nil) -> InstalledApp {
    InstalledApp(bundleID: id, name: name, version: nil, teamID: team, isAppleSigned: false, source: .manual,
                 url: URL(fileURLWithPath: path ?? "/Applications/\(name).app"), lastUsed: nil)
}

private func attr(_ apps: [InstalledApp], _ raw: RawFinding, exists: @escaping @Sendable (String) -> Bool = { _ in false },
                  reference: ReferenceData = .bundled) -> Attribution {
    Attributor(index: AppIndex(apps: apps), reference: reference, fileExists: exists).attribute(raw)
}

private func leftover(_ id: String, kind: Kind = .appSupport, program: String? = nil, creator: String? = nil) -> RawFinding {
    var r = RawFinding(category: .leftovers, kind: kind, name: id, paths: [], identifier: id, programPath: program)
    r.creatorID = creator
    return r
}

@Test func existingProgramOutsideAppsFolderIsInstalled() {
    let program = "/Library/Application Support/Logitech.localized/LogiRightSight.app/Contents/MacOS/LogiRightSight"
    let a = attr([], leftover("com.logitech.LogiRightSight.Agent", kind: .launchAgent, program: program), exists: { $0 == program })
    #expect(a.status == .installed)
    #expect(a.owner?.displayName == "LogiRightSight")
}

@Test func embeddedExtensionBelongsToHostApp() throws {
    let fx = try Fixture()
    try fx.bundle("root/Applications/Frame.io Transfer.app", id: "io.frame.transfer", name: "Frame.io Transfer")
    try fx.bundle("root/Applications/Frame.io Transfer.app/Contents/PlugIns/FinderExtension.appex", id: "io.suite.frameiofs.SuiteExtensions.Finder")
    let index = AppIndexBuilder.build(fx.env(), reference: .bundled, caskApps: [])
    #expect(index.app(bundleID: "io.suite.frameiofs.SuiteExtensions.Finder")?.name == "Frame.io Transfer")
}

@Test func containerCreatorDecidesOwner() {
    let whatsapp = app("net.whatsapp.WhatsApp", "WhatsApp")
    let a = attr([whatsapp], leftover("group.com.facebook.family", kind: .groupContainer, creator: "net.whatsapp.WhatsApp"))
    #expect(a.status == .installed && a.owner?.displayName == "WhatsApp")
    let shortcuts = attr([], leftover("group.is.workflow.my.app", kind: .groupContainer, creator: "com.apple.siriactionsd"))
    #expect(shortcuts.status == .apple)
    // System brokers create containers on behalf of extensions; fall back to the name.
    let broker = attr([whatsapp], leftover("net.whatsapp.WhatsApp.ext", kind: .container, creator: "com.apple.pluginkit.pkd"))
    #expect(broker.status == .installed)
}

@Test func applePrefixesBeyondComApple() {
    #expect(attr([], leftover("org.cups.printers")).status == .apple)
    #expect(attr([], leftover("is.workflow.shortcuts")).status == .apple)
}

@Test func installedAppNameBeatsAppleComponentName() {
    let ref = ReferenceData(stock: StockReference(appBundleIDs: [], appleNames: ["purge"], protectedHomePaths: []),
                            defaults: [], knownApps: [])
    let a = attr([app("io.getpurge.app", "Purge")], leftover("Purge"), reference: ref)
    #expect(a.status == .installed)
}

@Test func genericNamesAreNotAppleNames() {
    for name in ["caches", "purge", "default.store", "profiles", "ambientsettingstests"] {
        #expect(!ReferenceData.bundled.stock.isAppleName(name), "\(name)")
    }
}

@Test func specificKnownAppNotInstalledBeatsVendorFallback() {
    let onedrive = app("com.microsoft.OneDrive-mac", "OneDrive")
    let a = attr([onedrive], leftover("com.microsoft.VSCode.ShipIt", kind: .cache))
    #expect(a.status == .orphaned)
    #expect(a.owner?.displayName == "Visual Studio Code")
}

@Test func vendorLevelKnownAppShowsVendorName() {
    let word = app("com.microsoft.Word", "Microsoft Word")
    let a = attr([word], leftover("Microsoft"))
    #expect(a.status == .installed && a.owner?.displayName == "Microsoft")
}

@Test func teamContainerPrefersSameProductApp() {
    let apps = [app("com.mrbarkan.cleanmode", "CleanMode", team: "L26TPPMPF3"), app("com.cratedigger.app", "CrateDigger", team: "L26TPPMPF3")]
    let a = attr(apps, leftover("L26TPPMPF3.com.cratedigger.shared", kind: .groupContainer))
    #expect(a.owner?.displayName == "CrateDigger")
}

@Test func otherProductFromSameVendorIsNotInstalled() {
    let a = attr([app("com.mrbarkan.DINDIN", "DINDIN")], leftover("com.mrbarkan.DriveDroid.FileProvider", kind: .container))
    #expect(a.status == .orphaned)
    #expect(a.owner?.displayName == "DriveDroid")
    let helper = attr([app("com.foo.app", "Foo")], leftover("com.foo.helper", kind: .cache))
    #expect(helper.status == .installed)
}

@Test func logSuffixIsStripped() {
    #expect(Identifier.strip("MCXTools.log") == "MCXTools")
}

@Test func dotfilesUseDotfilePatterns() {
    let gemini = app("com.google.GeminiMacOS", "Gemini")
    var r = RawFinding(category: .devTooling, kind: .dotfile, name: ".gemini", paths: [], identifier: ".gemini")
    let a = attr([gemini], r)
    #expect(a.owner?.displayName != "Gemini")
    r.identifier = ".claude"
    #expect(attr([], r).owner?.displayName == "Claude Code CLI")
}

@Test func exactKnownBundleIDIsNotCreditedToAnotherVendorApp() {
    let excel = app("com.microsoft.Excel", "Microsoft Excel")
    for id in ["com.microsoft.VSCode", "com.microsoft.edgemac"] {
        let a = attr([excel], leftover(id, kind: .preferences))
        #expect(a.status == .orphaned, "\(id)")
        #expect(a.confidence == .high, "\(id)")
    }
}
