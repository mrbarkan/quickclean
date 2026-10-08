import Foundation
import UniformTypeIdentifiers

/// System-wide changes: installer receipts, default apps, command-line tools, frameworks,
/// app extensions and /etc.
public struct SystemScanner: Scanner {
    public var category: ScanCategory { .system }
    let reference: ReferenceData

    static let pkgutil = "/usr/sbin/pkgutil"
    static let pluginkit = "/usr/bin/pluginkit"
    static let receiptConcurrency = 8
    static let payloadSample = 300

    public init(reference: ReferenceData = .bundled) { self.reference = reference }

    public func scan(_ env: ScanEnvironment, index: AppIndex) async -> ScanOutput {
        var out = ScanOutput()
        await scanReceipts(env, into: &out)
        scanHandlers(env, into: &out)
        scanCommandLineTools(env, into: &out)
        scanFrameworks(env, into: &out)
        await scanExtensions(env, into: &out)
        scanEtc(env, into: &out)
        return out
    }

    // MARK: Installer receipts

    private struct Receipt: Sendable {
        var id: String
        var base: URL
        var installed: Date?
        var files: [String]
    }

    private func scanReceipts(_ env: ScanEnvironment, into out: inout ScanOutput) async {
        let ids: [String]
        do {
            let r = try await env.commands.run(Self.pkgutil, ["--pkgs"], timeout: 10)
            ids = r.stdout.split(separator: "\n").map(String.init).filter { !$0.lowercased().hasPrefix("com.apple.") }
        } catch {
            out.issues.append(ScanIssue(subject: "\(Self.pkgutil) --pkgs", reason: "Could not list installer receipts (\(error))."))
            return
        }

        let receipts = await withTaskGroup(of: Receipt?.self) { group in
            var pending = ids.makeIterator()
            var results: [Receipt] = []
            func next() -> Bool {
                guard let id = pending.next() else { return false }
                group.addTask { await Self.receipt(id, env) }
                return true
            }
            for _ in 0..<Self.receiptConcurrency where next() {}
            while let result = await group.next() {
                if let result { results.append(result) }
                _ = next()
            }
            return results.sorted { $0.id < $1.id }
        }

        for receipt in receipts {
            let step = max(1, receipt.files.count / Self.payloadSample)
            let sample = stride(from: 0, to: receipt.files.count, by: step).prefix(Self.payloadSample).map { receipt.files[$0] }
            let surviving = sample.filter { FileManager.default.fileExists(atPath: receipt.base.appending(path: $0).path) }.count
            var badges: Set<Badge> = []
            let payload: String
            if sample.isEmpty {
                payload = "It lists no files."
            } else if surviving == 0 {
                badges.insert(.broken)
                payload = "None of its files remain; only the receipt is left."
            } else {
                payload = "\(surviving) of the \(sample.count) files checked still exist."
            }
            let appPath = Self.appPath(base: receipt.base, files: receipt.files)
            var id = receipt.id
            for suffix in [".pkg", ".mpkg"] where id.lowercased().hasSuffix(suffix) { id.removeLast(suffix.count) }
            out.findings.append(RawFinding(
                category: .system, kind: .pkgReceipt, name: receipt.id,
                paths: [env.path("private/var/db/receipts/\(receipt.id).plist")], identifier: id,
                programPath: appPath, badges: badges, modified: receipt.installed,
                detail: "Installed into \(receipt.base.path). \(payload)", inSystemDomain: false,
                idOverride: "system:receipt:\(receipt.id)"))
        }
    }

    private static func receipt(_ id: String, _ env: ScanEnvironment) async -> Receipt? {
        guard let info = try? await env.commands.run(pkgutil, ["--pkg-info", id], timeout: 10), info.status == 0 else { return nil }
        var fields: [String: String] = [:]
        for line in info.stdout.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 { fields[parts[0]] = parts[1] }
        }
        let volume = fields["volume"] ?? "/"
        let location = fields["location"] ?? ""
        let volumeURL = volume == "/" ? env.root : URL(fileURLWithPath: volume)
        let base = location.isEmpty ? volumeURL : volumeURL.appending(path: location)
        let installed = fields["install-time"].flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
        // Folders like Applications or Library always exist; only files tell whether the payload survived.
        let files = (try? await env.commands.run(pkgutil, ["--only-files", "--files", id], timeout: 10))?.stdout
            .split(separator: "\n").map(String.init) ?? []
        return Receipt(id: id, base: base, installed: installed, files: files)
    }

    /// A path inside the app the package installed, so attribution can tell whether it's still there.
    private static func appPath(base: URL, files: [String]) -> String? {
        if base.pathExtension == "app" { return base.appending(path: "Contents").path }
        guard let file = files.first(where: { $0.contains(".app/") }),
              let range = file.range(of: ".app/")
        else { return nil }
        return base.appending(path: "\(file[..<range.lowerBound]).app/Contents").path
    }

    // MARK: Default apps

    private func scanHandlers(_ env: ScanEnvironment, into out: inout ScanOutput) {
        let plist = env.homePath("Library/Preferences/com.apple.LaunchServices/com.apple.launchservices.secure.plist")
        guard let handlers = NSDictionary(contentsOf: plist)?["LSHandlers"] as? [[String: Any]] else { return }
        for handler in handlers {
            let roles = ["LSHandlerRoleAll", "LSHandlerRoleViewer", "LSHandlerRoleEditor"].compactMap { handler[$0] as? String }
            guard let app = roles.first(where: { $0 != "-" }), !app.lowercased().hasPrefix("com.apple.") else { continue }
            let name: String
            let key: String
            if let scheme = handler["LSHandlerURLScheme"] as? String {
                name = "Opens \(scheme): links"
                key = "scheme:\(scheme)"
            } else if let type = handler["LSHandlerContentType"] as? String {
                name = "Opens \(UTType(type)?.localizedDescription ?? type) files"
                key = "type:\(type)"
            } else {
                continue
            }
            out.findings.append(RawFinding(
                category: .system, kind: .defaultHandler, name: name, paths: [plist], identifier: app,
                detail: "Chosen as the default app (\(app)). If that app is gone, macOS asks again or falls back to its own app.",
                idOverride: "system:handler:\(key)"))
        }
    }

    // MARK: Command-line tools, frameworks, runtimes

    private func scanCommandLineTools(_ env: ScanEnvironment, into out: inout ScanOutput) {
        let fm = FileManager.default
        for folder in ["usr/local/bin", "usr/local/sbin", "usr/local/lib"] {
            let dir = env.path(folder)
            for url in Listing.children(dir, into: &out) {
                var program: String?
                var badges: Set<Badge> = []
                var detail = "Installed outside any app or package manager."
                if let dest = try? fm.destinationOfSymbolicLink(atPath: url.path) {
                    let target = Self.resolve(dest, from: url.deletingLastPathComponent().path)
                    // Homebrew on Intel Macs lives in /usr/local; Dev Tooling reports it.
                    if target.contains("/Cellar/") || target.contains("/Caskroom/") || target.contains("/Homebrew/") { continue }
                    program = target
                    if fm.fileExists(atPath: target) {
                        detail = "Links to \(target)."
                    } else {
                        badges.insert(.broken)
                        detail = "Links to \(target), which no longer exists."
                    }
                }
                out.findings.append(RawFinding(
                    category: .system, kind: .commandLineTool, name: url.lastPathComponent, paths: [url],
                    identifier: url.lastPathComponent, programPath: program, badges: badges,
                    modified: Listing.modified(url), detail: detail, inSystemDomain: true))
            }
        }
    }

    /// Joins a symlink target to its folder and folds "." and ".." without touching the disk
    /// (URL standardization would also rewrite /private/var to /var).
    static func resolve(_ target: String, from folder: String) -> String {
        var parts: [Substring] = target.hasPrefix("/") ? [] : folder.split(separator: "/")
        for part in target.split(separator: "/") {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    private func scanFrameworks(_ env: ScanEnvironment, into out: inout ScanOutput) {
        let places = [("Library/Frameworks", "Shared framework other apps can load."),
                      ("Library/Java/JavaVirtualMachines", "Java runtime.")]
        for (folder, detail) in places {
            for url in Listing.children(env.path(folder), into: &out) {
                let info = ["Resources/Info.plist", "Versions/Current/Resources/Info.plist", "Contents/Info.plist"]
                    .lazy.compactMap { NSDictionary(contentsOf: url.appending(path: $0)) }.first
                let id = info?["CFBundleIdentifier"] as? String ?? url.deletingPathExtension().lastPathComponent
                out.findings.append(RawFinding(
                    category: .system, kind: .framework, name: url.lastPathComponent, paths: [url], identifier: id,
                    modified: Listing.modified(url), detail: detail, inSystemDomain: true))
            }
        }
    }

    // MARK: App extensions

    static let extensionTypes: [String: String] = [
        "com.apple.FinderSync": "Adds icons and menus to Finder (Finder Sync).",
        "com.apple.share-services": "Adds an entry to the Share menu.",
        "com.apple.quicklook.preview": "Quick Look preview.",
        "com.apple.quicklook.thumbnail": "Quick Look thumbnails.",
        "com.apple.Safari.web-extension": "Safari extension.",
        "com.apple.Safari.content-blocker": "Safari content blocker.",
        "com.apple.widgetkit-extension": "Widget.",
        "com.apple.fileprovider-nonui": "Cloud storage in Finder (File Provider).",
        "com.apple.photo-editing": "Photos editing extension.",
        "com.apple.services": "Action extension.",
        "com.apple.spotlight.import": "Spotlight importer.",
    ]

    private func scanExtensions(_ env: ScanEnvironment, into out: inout ScanOutput) async {
        let output: String
        do {
            output = try await env.commands.run(Self.pluginkit, ["-mAvvv"], timeout: 20).stdout
        } catch {
            out.issues.append(ScanIssue(subject: "\(Self.pluginkit) -mAvvv", reason: "Could not list app extensions (\(error))."))
            return
        }
        var seen = Set<String>()
        for block in output.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n").map(String.init)
            // Header: optional election flag (+ - ! = ? .) anywhere before the ID, then "id(version)".
            guard let header = lines.first(where: { !$0.hasPrefix("\t") && $0.contains("(") }),
                  let match = header.firstMatch(of: /^\s*([+\-!=?.]?)\s*([^\s(]+)\(/)
            else { continue }
            let flag = String(match.1)
            let id = String(match.2)
            var fields: [String: String] = [:]
            for line in lines.dropFirst() {
                let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2 { fields[parts[0]] = parts[1] }
            }
            guard let path = fields["Path"], !path.hasPrefix("/System/"), !id.lowercased().hasPrefix("com.apple."),
                  seen.insert(id).inserted
            else { continue }
            let sdk = fields["SDK"] ?? ""
            var detail = Self.extensionTypes[sdk] ?? (sdk.isEmpty ? "App extension." : "Extension type: \(sdk).")
            if flag == "+" { detail += " Turned on." }
            if flag == "-" { detail += " Turned off." }
            out.findings.append(RawFinding(
                category: .system, kind: .appExtension, name: fields["Display Name"] ?? id,
                paths: [URL(fileURLWithPath: path)], identifier: id, programPath: path, detail: detail,
                idOverride: "system:extension:\(id)"))
        }
    }

    // MARK: /etc

    static let stockHosts: Set<String> = [
        "127.0.0.1 localhost", "255.255.255.255 broadcasthost", "::1 localhost", "fe80::1%lo0 localhost",
    ]

    private func scanEtc(_ env: ScanEnvironment, into out: inout ScanOutput) {
        let etc = env.path("private/etc")
        if let stock = reference.stock.etcEntries {
            var entries = Listing.children(etc, into: &out).map { ($0.lastPathComponent, $0) }
            entries += Listing.children(etc.appending(path: "paths.d"), into: &out).map { ("paths.d/\($0.lastPathComponent)", $0) }
            for (name, url) in entries where !stock.contains(name) {
                out.findings.append(RawFinding(
                    category: .system, kind: .systemConfig, name: name, paths: [url],
                    identifier: URL(fileURLWithPath: name).lastPathComponent, modified: Listing.modified(url),
                    detail: "Not part of a clean macOS install's /etc.", inSystemDomain: true))
            }
        }
        let hosts = etc.appending(path: "hosts")
        if let text = try? String(contentsOf: hosts, encoding: .utf8) {
            let custom = text.components(separatedBy: .newlines).map { line in
                (line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
                    .split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
            }.filter { !$0.isEmpty && !Self.stockHosts.contains($0) }
            if !custom.isEmpty {
                out.findings.append(RawFinding(
                    category: .system, kind: .systemConfig, name: "hosts", paths: [hosts], identifier: "hosts",
                    modified: Listing.modified(hosts),
                    detail: "The hosts file has \(custom.count) custom entr\(custom.count == 1 ? "y" : "ies"), which redirect or block websites.",
                    inSystemDomain: true, idOverride: "system:hosts"))
            }
        }
    }
}
