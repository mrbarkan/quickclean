import Foundation

public struct ScanOutput: Sendable {
    public var findings: [RawFinding] = []
    public var issues: [ScanIssue] = []

    public init(findings: [RawFinding] = [], issues: [ScanIssue] = []) {
        self.findings = findings
        self.issues = issues
    }
}

public protocol Scanner: Sendable {
    var category: ScanCategory { get }
    func scan(_ env: ScanEnvironment, index: AppIndex) async -> ScanOutput
}

/// Read-only directory helpers shared by scanners.
enum Listing {
    /// Visible children of `dir`. A missing folder yields nothing; an unreadable one yields an issue.
    static func children(_ dir: URL, into out: inout ScanOutput) -> [URL] {
        do {
            return try FileManager.default
                .contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey])
                .filter { !$0.lastPathComponent.hasPrefix(".") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        } catch {
            if !FileManager.default.fileExists(atPath: dir.path) { return [] }
            out.issues.append(ScanIssue(subject: dir.path, reason: "Could not read this folder: \(error.localizedDescription)"))
            return []
        }
    }

    static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    static func isDirectory(_ url: URL) -> Bool {
        let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return v?.isDirectory == true && v?.isSymbolicLink != true
    }

    /// Info.plist of a bundle (`Contents/Info.plist`, or flat `Info.plist`).
    static func bundleInfo(_ url: URL) -> [String: Any]? {
        (NSDictionary(contentsOf: url.appending(path: "Contents/Info.plist"))
            ?? NSDictionary(contentsOf: url.appending(path: "Info.plist"))) as? [String: Any]
    }
}
