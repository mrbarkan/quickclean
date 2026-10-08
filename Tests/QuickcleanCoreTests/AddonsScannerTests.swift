import Foundation
import Testing
@testable import QuickcleanCore

@Test func addonsAcrossUserAndSystemLibraries() async throws {
    let fx = try Fixture()
    try fx.bundle("home/Library/QuickLook/QLMarkdown.qlgenerator", id: "com.toland.qlmarkdown", name: "QLMarkdown")
    try fx.file("home/Library/Fonts/Inter.ttf")
    try fx.bundle("root/Library/Audio/Plug-Ins/Components/Foo.component", id: "com.foo.audio")
    try fx.bundle("home/Library/Input Methods/Squirrel.app", id: "im.rime.inputmethod.Squirrel")
    try fx.bundle("home/Library/Mail/Bundles/GPGMail.mailbundle", id: "org.gpgtools.gpgmail")

    let out = await AddonsScanner().scan(fx.env(), index: AppIndex(apps: []))
    let byID = Dictionary(out.findings.map { ($0.identifier ?? "", $0) }, uniquingKeysWith: { a, _ in a })
    #expect(byID["com.toland.qlmarkdown"]?.kind == .quickLookPlugin)
    #expect(byID["com.toland.qlmarkdown"]?.name == "QLMarkdown")
    #expect(byID["Inter"]?.kind == .font)
    #expect(byID["com.foo.audio"]?.kind == .audioPlugin)
    #expect(byID["com.foo.audio"]?.inSystemDomain == true)
    #expect(byID["im.rime.inputmethod.Squirrel"]?.kind == .inputMethod)
    #expect(byID["im.rime.inputmethod.Squirrel"]?.detail?.contains("looks or behaves") == true)
    #expect(byID["org.gpgtools.gpgmail"]?.kind == .mailBundle)
    #expect(out.findings.count == 5)
}
