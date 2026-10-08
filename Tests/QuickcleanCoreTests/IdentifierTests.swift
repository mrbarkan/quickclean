import Foundation
import Testing
@testable import QuickcleanCore

@Test(arguments: [
    ("com.x.y.0F1E2D3C-AAAA-BBBB-CCCC-111122223333.plist", "com.x.y"),
    ("com.x.y.plist", "com.x.y"),
    ("com.x.y.savedState", "com.x.y"),
    ("com.x.y.binarycookies", "com.x.y"),
    ("Spotify", "Spotify"),
])
func stripRemovesFileDecorations(input: String, expected: String) {
    #expect(Identifier.strip(input) == expected)
}

@Test func bundleLikeRecognizesReverseDNS() {
    #expect(Identifier.isBundleLike("com.spotify.client"))
    #expect(Identifier.isBundleLike("org.pqrs.karabiner"))
    #expect(Identifier.isBundleLike("io.tailscale.ipn"))
    #expect(!Identifier.isBundleLike("Spotify"))
    #expect(!Identifier.isBundleLike("zoom.us"))
    #expect(!Identifier.isBundleLike("Battle.net"))
}

@Test func teamPrefixParsesGroupContainers() {
    #expect(Identifier.teamPrefix("ABCDE12345.com.foo.shared")?.team == "ABCDE12345")
    #expect(Identifier.teamPrefix("ABCDE12345.com.foo.shared")?.rest == "com.foo.shared")
    #expect(Identifier.teamPrefix("group.com.foo") == nil)
    #expect(Identifier.teamPrefix("com.foo.bar") == nil)
}

@Test func vendorPrefixSkipsSharedHosts() {
    #expect(Identifier.vendorPrefix("com.foo.app.helper") == "com.foo")
    #expect(Identifier.vendorPrefix("com.github.someone.app") == nil)
    #expect(Identifier.vendorPrefix("foo") == nil)
}

@Test func appNameFromPath() {
    #expect(Identifier.appName(fromPath: "/Applications/Foo Bar.app/Contents/MacOS/x") == "Foo Bar")
    #expect(Identifier.appName(fromPath: "/usr/local/bin/x") == nil)
}
