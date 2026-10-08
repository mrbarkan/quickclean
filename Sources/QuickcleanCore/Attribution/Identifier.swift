import Foundation

/// Helpers for turning file and folder names into comparable identifiers.
public enum Identifier {
    private static let topLevelDomains: Set<String> = [
        "com", "org", "net", "io", "de", "us", "uk", "co", "me", "app", "dev", "ai", "fr", "jp", "ch", "ca",
        "nl", "se", "it", "es", "edu", "gov", "info", "cc", "tv", "eu", "at", "be", "au", "ru", "cn", "pl",
        "br", "in", "sh", "xyz", "so", "is", "ly", "fm", "gg", "dk", "no", "fi", "cz", "kr", "tw", "hk", "nz",
        "mx", "ar", "pt", "ie", "il", "sg", "biz", "tech", "studio", "games", "pro", "cloud", "one", "zone",
    ]

    /// Hosts shared by many unrelated developers; their first two components say nothing about the owner.
    private static let sharedVendors: Set<String> = [
        "com.github", "io.github", "com.electron", "org.chromium", "com.example", "org.sparkle-project",
    ]

    /// Reverse-DNS like "com.vendor.app": at least three non-empty parts starting with a known TLD.
    public static func isBundleLike(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts.allSatisfy({ !$0.isEmpty }),
              !parts[0].contains(" "), !parts[1].contains(" ") else { return false }
        return topLevelDomains.contains(parts[0].lowercased())
    }

    /// Removes file decorations: .plist, .savedState, .binarycookies and ByHost UUID/hex suffixes.
    public static func strip(_ name: String) -> String {
        var s = name
        for suffix in [".plist", ".savedState", ".binarycookies"] where s.hasSuffix(suffix) {
            s.removeLast(suffix.count)
        }
        if let r = s.range(of: #"\.([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}|[0-9A-Fa-f]{12})$"#,
                           options: .regularExpression) {
            s.removeSubrange(r)
        }
        return s
    }

    /// Splits "TEAMID123.rest" (group containers, team-scoped helpers).
    public static func teamPrefix(_ s: String) -> (team: String, rest: String)? {
        guard let r = s.range(of: #"^[A-Z0-9]{10}\."#, options: .regularExpression) else { return nil }
        let team = String(s[r].dropLast())
        guard team.contains(where: \.isNumber) || team.contains(where: \.isLetter) else { return nil }
        return (team, String(s[r.upperBound...]))
    }

    /// "com.vendor" for "com.vendor.app…", unless the host is shared by many developers.
    public static func vendorPrefix(_ bundleID: String) -> String? {
        let parts = bundleID.lowercased().split(separator: ".")
        guard parts.count >= 3 else { return nil }
        let vendor = "\(parts[0]).\(parts[1])"
        return sharedVendors.contains(vendor) ? nil : vendor
    }

    /// "Foo Bar" for "/Applications/Foo Bar.app/Contents/…".
    public static func appName(fromPath path: String) -> String? {
        path.split(separator: "/").first { $0.hasSuffix(".app") }.map { String($0.dropLast(4)) }
    }

    /// A readable guess for a bundle ID's owner: "com.spotify.client" → "Spotify".
    public static func displayName(forBundleID id: String) -> String {
        let parts = id.split(separator: ".")
        guard parts.count >= 2 else { return id }
        let word = parts[1]
        return word.prefix(1).uppercased() + word.dropFirst()
    }

    /// Lowercase alphanumerics only, without a trailing ".app" or version number.
    public static func normalize(_ name: String) -> String {
        var s = name.lowercased()
        if s.hasSuffix(".app") { s.removeLast(4) }
        while let last = s.last, last.isNumber || last == " " || last == "." || last == "-" || last == "_" {
            s.removeLast()
        }
        return String(s.filter { $0.isLetter || $0.isNumber })
    }
}
