import AppKit
import CoreServices
import Foundation
import Security

// MARK: - Commands

public struct CommandResult: Sendable, Equatable {
    public let status: Int32
    public let stdout: String
    public let stderr: String

    public init(status: Int32, stdout: String, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

public enum CommandError: Error, Sendable, Equatable {
    case notFound(String)
    case timedOut(String)
    case launchFailed(String)
}

public protocol CommandRunner: Sendable {
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> CommandResult
}

/// Runs a program directly (no shell), capturing output, killing it after `timeout`.
public struct ProcessCommandRunner: CommandRunner {
    public init() {}

    public func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> CommandResult {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw CommandError.notFound(executable)
        }
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(with: Result { try Self.runBlocking(executable, arguments, timeout: timeout) })
            }
        }
    }

    private static func runBlocking(_ executable: String, _ arguments: [String], timeout: TimeInterval) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { throw CommandError.launchFailed("\(executable): \(error.localizedDescription)") }

        let outData = Locked(Data()), errData = Locked(Data())
        let readers = DispatchGroup()
        for (pipe, sink) in [(out, outData), (err, errData)] {
            readers.enter()
            DispatchQueue.global().async {
                sink.value = pipe.fileHandleForReading.readDataToEndOfFile()
                readers.leave()
            }
        }

        let timedOut = Locked(false)
        let killer = DispatchWorkItem {
            guard process.isRunning else { return }
            timedOut.value = true
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        process.waitUntilExit()
        killer.cancel()
        _ = readers.wait(timeout: .now() + 2)

        if timedOut.value { throw CommandError.timedOut(executable) }
        return CommandResult(
            status: process.terminationStatus,
            stdout: String(decoding: outData.value, as: UTF8.self),
            stderr: String(decoding: errData.value, as: UTF8.self))
    }
}

/// A value shared between dispatch callbacks.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value
    init(_ value: Value) { _value = value }
    var value: Value {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

// MARK: - Bundles

public struct SignatureInfo: Sendable, Equatable {
    public var teamID: String?
    public var isApple: Bool

    public init(teamID: String?, isApple: Bool) {
        self.teamID = teamID
        self.isApple = isApple
    }
}

public protocol BundleInspector: Sendable {
    func signature(of url: URL) -> SignatureInfo
    func lastUsed(_ url: URL) -> Date?
}

/// Reads code signatures (without hashing the whole bundle) and Spotlight's last-used date.
public struct LiveBundleInspector: BundleInspector {
    public init() {}

    public func signature(of url: URL) -> SignatureInfo {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else {
            return SignatureInfo(teamID: nil, isApple: false)
        }
        var info: CFDictionary?
        SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String

        var requirement: SecRequirement?
        SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement)
        let fast = SecCSFlags(rawValue: kSecCSDoNotValidateExecutable | kSecCSDoNotValidateResources)
        let isApple = requirement.map { SecStaticCodeCheckValidity(code, fast, $0) == errSecSuccess } ?? false
        return SignatureInfo(teamID: team, isApple: isApple)
    }

    public func lastUsed(_ url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(nil, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }
}

// MARK: - Preferences

public protocol PreferencesReader: Sendable {
    /// All values set in `domain` for the current user, or nil if the domain has none.
    func values(domain: String) -> [String: Any]?
}

/// Reads preference plists straight from `home/Library/Preferences` (used for fixtures).
public struct PlistPreferencesReader: PreferencesReader {
    public let home: URL

    public init(home: URL) { self.home = home }

    public func values(domain: String) -> [String: Any]? {
        let file = domain == "NSGlobalDomain" ? ".GlobalPreferences" : domain
        let url = home.appending(path: "Library/Preferences/\(file).plist")
        return NSDictionary(contentsOf: url) as? [String: Any]
    }
}

/// Reads live values through cfprefsd, which may be newer than the files on disk.
public struct CFPreferencesReader: PreferencesReader {
    public init() {}

    public func values(domain: String) -> [String: Any]? {
        let app: CFString = domain == "NSGlobalDomain" ? kCFPreferencesAnyApplication : domain as CFString
        let dict = CFPreferencesCopyMultiple(nil, app, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String: Any]
        return dict?.isEmpty == false ? dict : nil
    }
}

// MARK: - Environment

/// Everything a scan touches outside its own code. Tests swap in fixtures and stubs.
public struct ScanEnvironment: Sendable {
    public var home: URL
    public var root: URL
    public var commands: any CommandRunner
    public var bundles: any BundleInspector
    public var preferences: any PreferencesReader
    public var now: Date
    public var runningBundleIDs: Set<String>

    public init(
        home: URL, root: URL, commands: any CommandRunner, bundles: any BundleInspector,
        preferences: any PreferencesReader, now: Date, runningBundleIDs: Set<String>
    ) {
        self.home = home
        self.root = root
        self.commands = commands
        self.bundles = bundles
        self.preferences = preferences
        self.now = now
        self.runningBundleIDs = runningBundleIDs
    }

    @MainActor
    public static func live() -> ScanEnvironment {
        ScanEnvironment(
            home: FileManager.default.homeDirectoryForCurrentUser,
            root: URL(fileURLWithPath: "/"),
            commands: ProcessCommandRunner(),
            bundles: LiveBundleInspector(),
            preferences: CFPreferencesReader(),
            now: Date(),
            runningBundleIDs: Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)))
    }

    /// A path relative to the volume root, e.g. "Library/LaunchAgents".
    public func path(_ relative: String) -> URL { root.appending(path: relative) }

    /// A path relative to the user's home folder, e.g. "Library/Caches".
    public func homePath(_ relative: String) -> URL { home.appending(path: relative) }
}
