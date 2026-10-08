import Foundation

/// Homebrew, developer caches and toolchains, and dotfiles in the home folder.
public struct DevToolingScanner: Scanner {
    public var category: Category { .devTooling }

    /// (home-relative path, display name, owning tool)
    static let caches: [(String, String, String)] = [
        ("Library/Developer/Xcode/DerivedData", "Xcode DerivedData", "Xcode"),
        ("Library/Developer/Xcode/iOS DeviceSupport", "Xcode device support files", "Xcode"),
        ("Library/Developer/CoreSimulator/Caches", "Simulator caches", "Xcode"),
        ("Library/Caches/Homebrew", "Homebrew download cache", "Homebrew"),
        (".npm/_cacache", "npm cache", "npm"),
        ("Library/Caches/pnpm", "pnpm cache", "pnpm"),
        ("Library/Caches/Yarn", "Yarn cache", "Yarn"),
        ("Library/Caches/pip", "pip cache", "pip"),
        (".cargo/registry", "Cargo registry cache", "Rust"),
        ("Library/Caches/go-build", "Go build cache", "Go"),
        ("go/pkg/mod", "Go module cache", "Go"),
        (".gradle/caches", "Gradle cache", "Gradle"),
        ("Library/Caches/CocoaPods", "CocoaPods cache", "CocoaPods"),
    ]
    static let data: [(String, String, String)] = [
        ("Library/Developer/Xcode/Archives", "Xcode archives", "Xcode"),
        ("Library/Developer/CoreSimulator/Devices", "Simulator devices", "Xcode"),
        (".pyenv/versions", "pyenv Python versions", "pyenv"),
        (".nvm/versions", "nvm Node versions", "nvm"),
        (".rbenv/versions", "rbenv Ruby versions", "rbenv"),
        (".asdf/installs", "asdf installs", "asdf"),
        (".local/share/mise/installs", "mise installs", "mise"),
        (".rustup/toolchains", "Rust toolchains", "rustup"),
        ("Library/Containers/com.docker.docker", "Docker Desktop data", "Docker"),
        (".docker", "Docker settings and contexts", "Docker"),
        (".ollama/models", "Ollama models", "Ollama"),
    ]
    static let ignoredDotfiles: Set<String> = [".DS_Store", ".localized", ".Trash", ".CFUserTextEncoding"]

    public init() {}

    public func scan(_ env: ScanEnvironment, index: AppIndex) async -> ScanOutput {
        var out = ScanOutput()
        await scanHomebrew(env, into: &out)
        for (rel, name, tool) in Self.caches { add(rel, name, tool, .devCache, .safe, env, &out) }
        for (rel, name, tool) in Self.data { add(rel, name, tool, .devData, .review, env, &out) }
        scanDotfiles(env, into: &out)
        return out
    }

    /// App bundle names installed by Homebrew casks, from `brew info --json=v2 --installed`.
    public static func caskApps(from json: Data) -> Set<String> {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let casks = root["casks"] as? [[String: Any]] else { return [] }
        var apps = Set<String>()
        for cask in casks {
            for artifact in cask["artifacts"] as? [Any] ?? [] {
                guard let dict = artifact as? [String: Any], let list = dict["app"] as? [Any] else { continue }
                apps.formUnion(list.compactMap { $0 as? String })
            }
        }
        return apps
    }

    /// The brew executable under `env.root`, if Homebrew is installed.
    public static func brewPath(_ env: ScanEnvironment) -> String? {
        ["opt/homebrew/bin/brew", "usr/local/bin/brew"].map { env.path($0).path }
            .first { FileManager.default.isExecutableFile(atPath: $0) || FileManager.default.fileExists(atPath: $0) }
    }

    // MARK: Homebrew

    private func scanHomebrew(_ env: ScanEnvironment, into out: inout ScanOutput) async {
        guard let brew = Self.brewPath(env) else {
            out.issues.append(ScanIssue(subject: "Homebrew", reason: "Homebrew is not installed; skipped."))
            return
        }
        let prefix = URL(fileURLWithPath: brew).deletingLastPathComponent().deletingLastPathComponent()
        let info: [String: Any]
        do {
            let r = try await env.commands.run(brew, ["info", "--json=v2", "--installed"], timeout: 30)
            guard let parsed = try? JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any] else {
                out.issues.append(ScanIssue(subject: "Homebrew", reason: "Could not understand `brew info` output."))
                return
            }
            info = parsed
        } catch {
            out.issues.append(ScanIssue(subject: "Homebrew", reason: "`brew info` failed (\(error))."))
            return
        }
        let leavesOutput = (try? await env.commands.run(brew, ["leaves"], timeout: 30))?.stdout ?? ""
        let leaves = Set(leavesOutput.split(separator: "\n").map(String.init))

        let owner = PresetAttribution(
            owner: Owner(bundleID: nil, displayName: "Homebrew", teamID: nil), status: .installed, confidence: .high,
            evidence: Evidence(rule: "homebrew", detail: "Listed by `brew info --installed`."))
        var taps = Set<String>()

        for f in info["formulae"] as? [[String: Any]] ?? [] {
            guard let name = f["name"] as? String else { continue }
            let full = f["full_name"] as? String ?? name
            if let tap = f["tap"] as? String { taps.insert(tap) }
            let isLeaf = leaves.contains(full) || leaves.contains(name)
            let desc = f["desc"] as? String
            let detail = [desc.map { "\($0)." }, isLeaf ? "Installed on its own; nothing else needs it." : "Needed by other formulae."]
                .compactMap { $0 }.joined(separator: " ")
            let path = prefix.appending(path: "Cellar/\(name)")
            out.findings.append(RawFinding(
                category: .devTooling, kind: .brewFormula, name: full, paths: [path], identifier: full, preset: owner,
                modified: Listing.modified(path), detail: detail, riskOverride: isLeaf ? .review : .careful,
                idOverride: "devTooling:brew:formula:\(full)"))
        }
        for c in info["casks"] as? [[String: Any]] ?? [] {
            guard let token = c["token"] as? String else { continue }
            if let tap = c["tap"] as? String { taps.insert(tap) }
            let path = prefix.appending(path: "Caskroom/\(token)")
            out.findings.append(RawFinding(
                category: .devTooling, kind: .brewCask, name: token, paths: [path], identifier: token, preset: owner,
                modified: Listing.modified(path), detail: (c["desc"] as? String).map { "\($0)." }, riskOverride: .review,
                idOverride: "devTooling:brew:cask:\(token)"))
        }
        for tap in taps.subtracting(["homebrew/core", "homebrew/cask"]).sorted() {
            let parts = tap.split(separator: "/")
            guard parts.count == 2 else { continue }
            let path = prefix.appending(path: "Library/Taps/\(parts[0])/homebrew-\(parts[1])")
            out.findings.append(RawFinding(
                category: .devTooling, kind: .brewTap, name: tap, paths: [path], identifier: tap, preset: owner,
                detail: "Third-party Homebrew repository.", riskOverride: .review, idOverride: "devTooling:brew:tap:\(tap)"))
        }
    }

    // MARK: Caches, data, dotfiles

    private func add(_ rel: String, _ name: String, _ tool: String, _ kind: Kind, _ risk: Risk, _ env: ScanEnvironment, _ out: inout ScanOutput) {
        let url = env.homePath(rel)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let preset = PresetAttribution(
            owner: Owner(bundleID: nil, displayName: tool, teamID: nil), status: .installed, confidence: .high,
            evidence: Evidence(rule: "devTool", detail: "Standard location used by \(tool)."))
        out.findings.append(RawFinding(
            category: .devTooling, kind: kind, name: name, paths: [url], identifier: name, preset: preset,
            modified: Listing.modified(url),
            detail: kind == .devCache ? "Rebuilt automatically when needed." : "Removing it means reinstalling or re-downloading.",
            riskOverride: risk))
    }

    private func scanDotfiles(_ env: ScanEnvironment, into out: inout ScanOutput) {
        let covered = Set((Self.caches + Self.data).compactMap { rel, _, _ in
            rel.hasPrefix(".") ? String(rel.split(separator: "/")[0]) : nil
        })
        let entries = (try? FileManager.default.contentsOfDirectory(at: env.home, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = url.lastPathComponent
            guard name.hasPrefix("."), !Self.ignoredDotfiles.contains(name), !covered.contains(name) else { continue }
            out.findings.append(RawFinding(
                category: .devTooling, kind: .dotfile, name: name, paths: [url], identifier: String(name.dropFirst()),
                modified: Listing.modified(url)))
        }
    }
}
