import Foundation

/// What a clean macOS 27 install contains outside /System.
public struct StockReference: Codable, Sendable {
    /// Bundle IDs of apps that ship with macOS (e.g. Safari).
    public var appBundleIDs: Set<String>
    /// Lowercased names Apple uses for its own Library folders, daemons and frameworks.
    public var appleNames: Set<String>
    /// Home-relative paths that are never offered for removal.
    public var protectedHomePaths: [String]

    public init(appBundleIDs: Set<String>, appleNames: Set<String>, protectedHomePaths: [String]) {
        self.appBundleIDs = appBundleIDs
        self.appleNames = appleNames
        self.protectedHomePaths = protectedHomePaths
    }

    public func isAppleName(_ name: String) -> Bool { appleNames.contains(name.lowercased()) }
}

/// A plist scalar, comparable across Foundation bridging.
public enum JSONValue: Codable, Sendable, Hashable {
    case bool(Bool), number(Double), string(String), null

    public init?(any value: Any) {
        switch value {
        case let n as NSNumber where CFGetTypeID(n) == CFBooleanGetTypeID(): self = .bool(n.boolValue)
        case let n as NSNumber: self = .number(n.doubleValue)
        case let s as String: self = .string(s)
        default: return nil
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else { self = .string(try c.decode(String.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .null: try c.encodeNil()
        }
    }

    /// Equal as a setting: plists store switches as either booleans or 0/1 numbers.
    public func sameSetting(as other: JSONValue) -> Bool {
        switch (self, other) {
        case (.bool(let b), .number(let n)), (.number(let n), .bool(let b)): return n == (b ? 1 : 0)
        case (.number(let a), .number(let b)): return abs(a - b) < 0.000_1
        default: return self == other
        }
    }

    public var display: String {
        switch self {
        case .bool(let b): b ? "on" : "off"
        case .number(let n): n == n.rounded() ? String(Int(n)) : String(n)
        case .string(let s): "“\(s)”"
        case .null: "not set"
        }
    }
}

public struct DefaultSetting: Codable, Sendable {
    public var domain: String
    public var key: String
    public var title: String
    /// `.null` means macOS leaves the key unset.
    public var defaultValue: JSONValue
    public var note: String?
}

public struct KnownApp: Codable, Sendable, Equatable {
    /// Lowercased prefix matched against bundle IDs, launchd labels and folder names.
    public var pattern: String
    public var name: String
    public var bundleID: String?
    /// True when the app changes how macOS looks or behaves.
    public var customization: Bool
    public var note: String
    /// A framework or command-line tool many apps embed: its data can't be tied to one app.
    public var library: Bool?
    /// For non-app software (e.g. Homebrew): installed when any of these paths exists.
    public var installedPaths: [String]?

    public init(
        pattern: String, name: String, bundleID: String?, customization: Bool, note: String,
        library: Bool? = nil, installedPaths: [String]? = nil
    ) {
        self.pattern = pattern
        self.name = name
        self.bundleID = bundleID
        self.customization = customization
        self.note = note
        self.library = library
        self.installedPaths = installedPaths
    }

    public var isLibrary: Bool { library == true }
}

public struct ReferenceData: Sendable {
    public var stock: StockReference
    public var defaults: [DefaultSetting]
    public var knownApps: [KnownApp]

    public init(stock: StockReference, defaults: [DefaultSetting], knownApps: [KnownApp]) {
        self.stock = stock
        self.defaults = defaults
        self.knownApps = knownApps.sorted { $0.pattern.count > $1.pattern.count }
    }

    public static let bundled: ReferenceData = {
        func load<T: Decodable>(_ name: String) -> T {
            guard let url = Bundle.module.url(forResource: name, withExtension: "json"),
                  let data = try? Data(contentsOf: url),
                  let value = try? JSONDecoder().decode(T.self, from: data)
            else { fatalError("Quickclean: bundled \(name).json is missing or invalid") }
            return value
        }
        return ReferenceData(
            stock: load("stock-macos27"), defaults: load("defaults-macos27"), knownApps: load("known-apps"))
    }()

    /// The most specific known app whose pattern prefixes `identifier` at a word boundary.
    public func knownApp(for identifier: String) -> KnownApp? {
        let id = identifier.lowercased()
        return knownApps.first { app in
            guard id.hasPrefix(app.pattern) else { return false }
            guard let next = id.dropFirst(app.pattern.count).first else { return true }
            return !(next.isLetter || next.isNumber)
        }
    }
}
