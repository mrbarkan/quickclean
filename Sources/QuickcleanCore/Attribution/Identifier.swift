import Foundation

/// Helpers for turning file and folder names into comparable identifiers.
public enum Identifier {
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
