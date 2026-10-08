import Foundation

/// Things that run without being opened: launchd jobs, privileged helpers, kernel and system extensions.
public struct BackgroundScanner: Scanner {
    public var category: ScanCategory { .background }

    static let loginItemsIssue = ScanIssue(
        subject: "Login Items",
        reason: "macOS only lists login items to administrators. Review them in System Settings › General › Login Items & Extensions.")

    public init() {}

    public func scan(_ env: ScanEnvironment, index: AppIndex) async -> ScanOutput {
        var out = ScanOutput()
        let jobs = await launchdJobs(env)
        let processes = await runningPrograms(env)
        var seenLabels = Set<String>()

        let jobDirs: [(URL, Kind, Bool)] = [
            (env.homePath("Library/LaunchAgents"), .launchAgent, false),
            (env.path("Library/LaunchAgents"), .launchAgent, true),
            (env.path("Library/LaunchDaemons"), .launchDaemon, true),
        ]
        for (dir, kind, system) in jobDirs {
            for url in Listing.children(dir, into: &out) where url.pathExtension == "plist" {
                let job = launchJob(url, kind: kind, system: system, jobs: jobs, processes: processes, into: &out)
                seenLabels.insert(job.identifier ?? "")
                out.findings.append(job)
            }
        }

        for url in Listing.children(env.path("Library/PrivilegedHelperTools"), into: &out) {
            out.findings.append(RawFinding(
                category: .background, kind: .privilegedHelper, name: url.lastPathComponent, paths: [url],
                identifier: url.lastPathComponent, badges: processes.contains(url.path) ? [.running] : [],
                modified: Listing.modified(url),
                detail: "Runs with administrator privileges on behalf of an app.", inSystemDomain: true))
        }

        // Jobs apps register through SMAppService have no plist in the LaunchAgents folders.
        for (label, pid) in jobs.sorted(by: { $0.key < $1.key }) where !seenLabels.contains(label) && Self.isRegisteredJob(label) {
            out.findings.append(RawFinding(
                category: .background, kind: .loginItems, name: label, paths: [], identifier: label,
                badges: pid ? [.running] : [],
                detail: "Registered by an app as a login item or background helper, without a plist file. Managed in System Settings › General › Login Items & Extensions.",
                idOverride: "background:job:\(label)"))
        }

        for url in Listing.children(env.path("Library/Extensions"), into: &out) where url.pathExtension == "kext" {
            let id = Listing.bundleInfo(url)?["CFBundleIdentifier"] as? String ?? url.deletingPathExtension().lastPathComponent
            out.findings.append(RawFinding(
                category: .background, kind: .kext, name: url.lastPathComponent, paths: [url], identifier: id,
                modified: Listing.modified(url), detail: "Legacy kernel extension; loads into the core of macOS.",
                inSystemDomain: true))
        }

        out.findings += await systemExtensions(env, index: index, into: &out)
        out.issues.append(Self.loginItemsIssue)
        return out
    }

    /// Third-party launchd labels, excluding running app instances ("application.…") and macOS's own jobs.
    static func isRegisteredJob(_ label: String) -> Bool {
        let l = label.lowercased()
        return !l.hasPrefix("application.") && !l.hasPrefix("com.apple.") && !l.hasPrefix("com.openssh.")
            && Identifier.isBundleLike(label)
    }

    private func launchJob(_ url: URL, kind: Kind, system: Bool, jobs: [String: Bool], processes: Set<String>,
                           into out: inout ScanOutput) -> RawFinding {
        let fallbackID = Identifier.strip(url.lastPathComponent)
        guard let plist = NSDictionary(contentsOf: url) as? [String: Any] else {
            out.issues.append(ScanIssue(subject: url.path, reason: "Not a readable launchd property list."))
            return RawFinding(category: .background, kind: kind, name: url.lastPathComponent, paths: [url],
                              identifier: fallbackID, modified: Listing.modified(url), inSystemDomain: system)
        }
        let label = plist["Label"] as? String ?? fallbackID
        let program = plist["Program"] as? String ?? (plist["ProgramArguments"] as? [String])?.first
        var badges: Set<Badge> = []
        var details: [String] = []
        if let program, program.hasPrefix("/"), !FileManager.default.fileExists(atPath: program) {
            badges.insert(.broken)
            details.append("Its program \(program) no longer exists.")
        }
        if plist.isEmpty {
            details.append("Empty placeholder: launchd ignores it, so it does nothing.")
        }
        if plist["RunAtLoad"] as? Bool == true || plist["KeepAlive"] != nil {
            details.append(kind == .launchDaemon ? "Starts automatically when the Mac starts up." : "Starts automatically at login.")
        }
        if jobs[label] == true || program.map(processes.contains) == true { badges.insert(.running) }
        return RawFinding(
            category: .background, kind: kind, name: label, paths: [url], identifier: label, programPath: program,
            badges: badges, modified: Listing.modified(url), detail: details.isEmpty ? nil : details.joined(separator: " "),
            inSystemDomain: system)
    }

    /// The user's launchd jobs: label → whether it has a running process.
    private func launchdJobs(_ env: ScanEnvironment) async -> [String: Bool] {
        guard let r = try? await env.commands.run("/bin/launchctl", ["list"], timeout: 10), r.status == 0 else { return [:] }
        var jobs: [String: Bool] = [:]
        for line in r.stdout.split(separator: "\n").dropFirst() {
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard cols.count >= 3 else { continue }
            jobs[String(cols[2])] = cols[0] != "-"
        }
        return jobs
    }

    /// Executable paths of every running process, including root daemons.
    private func runningPrograms(_ env: ScanEnvironment) async -> Set<String> {
        guard let r = try? await env.commands.run("/bin/ps", ["-axo", "comm="], timeout: 10), r.status == 0 else { return [] }
        return Set(r.stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
    }

    private func systemExtensions(_ env: ScanEnvironment, index: AppIndex, into out: inout ScanOutput) async -> [RawFinding] {
        let tool = "/usr/bin/systemextensionsctl"
        let result: CommandResult
        do {
            result = try await env.commands.run(tool, ["list"], timeout: 10)
        } catch {
            out.issues.append(ScanIssue(subject: "\(tool) list", reason: "Could not list system extensions (\(error))."))
            return []
        }
        var findings: [RawFinding] = []
        var staged: [String: URL] = [:]
        for folder in (try? FileManager.default.contentsOfDirectory(at: env.path("Library/SystemExtensions"), includingPropertiesForKeys: nil)) ?? [] {
            for ext in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            where ext.pathExtension == "systemextension" {
                staged[ext.deletingPathExtension().lastPathComponent] = ext
            }
        }
        for line in result.stdout.split(separator: "\n") {
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard cols.count >= 6, cols[2].range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) != nil else { continue }
            let team = cols[2]
            let bundleID = cols[3].components(separatedBy: " (").first ?? cols[3]
            let name = cols[4]
            let state = cols[5].trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            findings.append(RawFinding(
                category: .background, kind: .systemExtension, name: name,
                paths: staged[bundleID].map { [$0] } ?? [], identifier: bundleID,
                preset: extensionOwner(bundleID: bundleID, team: team, name: name, index: index),
                detail: "State: \(state). Managed in System Settings › General › Login Items & Extensions.",
                idOverride: "background:sysext:\(bundleID)"))
        }
        return findings
    }

    private func extensionOwner(bundleID: String, team: String, name: String, index: AppIndex) -> PresetAttribution {
        if let app = index.apps(teamID: team).first ?? Identifier.vendorPrefix(bundleID).flatMap(index.app(vendorPrefix:)) {
            return PresetAttribution(
                owner: Owner(bundleID: app.bundleID, displayName: app.name, teamID: team), status: .installed,
                confidence: .medium, evidence: Evidence(rule: "teamID", detail: "Same developer team (\(team)) as \(app.name)."))
        }
        return PresetAttribution(
            owner: Owner(bundleID: nil, displayName: name, teamID: team), status: .orphaned, confidence: .medium,
            evidence: Evidence(rule: "teamIDNotInstalled", detail: "No installed app is from developer team \(team)."))
    }
}
