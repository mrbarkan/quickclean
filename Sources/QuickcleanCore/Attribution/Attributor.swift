import Foundation

public struct Attribution: Sendable, Equatable {
    public var owner: Owner?
    public var status: OwnerStatus
    public var confidence: Confidence
    public var evidence: [Evidence]
}

/// Decides who owns a raw finding, using the strongest evidence available.
public struct Attributor: Sendable {
    let index: AppIndex
    let reference: ReferenceData
    let fileExists: @Sendable (String) -> Bool
    let locateApp: @Sendable (String) -> URL?

    public init(
        index: AppIndex, reference: ReferenceData,
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        locateApp: @escaping @Sendable (String) -> URL? = { _ in nil }
    ) {
        self.index = index
        self.reference = reference
        self.fileExists = fileExists
        self.locateApp = locateApp
    }

    public func attribute(_ raw: RawFinding) -> Attribution {
        if let p = raw.preset {
            return Attribution(owner: p.owner, status: p.status, confidence: p.confidence, evidence: [p.evidence])
        }
        let label = raw.identifier ?? raw.name
        if let a = apple(Self.dropGroupPrefix(Identifier.strip(label))) { return a }
        if let program = raw.programPath, let a = byProgram(program, label: label) { return a }
        if let creator = raw.creatorID, !Self.containerBrokers.contains(creator) {
            var a = apple(creator) ?? byBundleID(creator)
            a.evidence.insert(Evidence(rule: "containerCreator", detail: "macOS records that \(creator) created this container."), at: 0)
            return a
        }
        if raw.kind == .dotfile, label.hasPrefix("."), let known = reference.knownApp(for: label), known.pattern.hasPrefix(".") {
            return byKnown(known, id: label)
        }

        var id = Self.dropGroupPrefix(Identifier.strip(label))
        while id.hasPrefix(".") { id.removeFirst() }

        if let (team, rest) = Identifier.teamPrefix(id) { return byTeam(team, rest: Self.dropGroupPrefix(rest)) }
        if Identifier.isBundleLike(id) { return byBundleID(id) }
        if reference.stock.isAppleName(id) {
            if let app = index.app(nameToken: id), !app.isAppleSigned, app.source != .system {
                return installed(app, .low, Evidence(rule: "nameToken", detail: "Named like the installed \(app.name)."))
            }
            return Attribution(owner: Self.appleOwner, status: .apple, confidence: .high,
                               evidence: [Evidence(rule: "apple", detail: "“\(id)” is a name macOS uses for its own data.")])
        }
        return byName(id)
    }

    /// Apple services that create containers on behalf of other apps' extensions.
    static let containerBrokers: Set<String> = [
        "com.apple.pluginkit.pkd", "com.apple.appstoreagent", "com.apple.containermanagerd", "com.apple.installd",
        "com.apple.lsd", "com.apple.mobile.installd",
    ]

    static let applePrefixes = ["com.apple.", "org.cups.", "is.workflow.", "com.openssh."]

    private static func dropGroupPrefix(_ id: String) -> String {
        for prefix in ["systemgroup.", "groups.", "group."] where id.lowercased().hasPrefix(prefix) {
            return String(id.dropFirst(prefix.count))
        }
        return id
    }

    // MARK: Rules

    private func apple(_ id: String) -> Attribution? {
        let lowered = id.lowercased()
        guard let prefix = Self.applePrefixes.first(where: { lowered.hasPrefix($0) }) else { return nil }
        return Attribution(owner: Self.appleOwner, status: .apple, confidence: .high,
                           evidence: [Evidence(rule: "apple", detail: "“\(id)” uses the \(prefix.dropLast()) prefix that macOS uses.")])
    }

    private func byProgram(_ program: String, label: String) -> Attribution? {
        if let app = index.app(containing: program) {
            return installed(app, .high, Evidence(rule: "programInsideApp", detail: "Its program is inside \(app.name).app."))
        }
        if fileExists(program) {
            let name = Identifier.appName(fromPath: program)
                ?? reference.knownApp(for: label)?.name
                ?? URL(fileURLWithPath: program).lastPathComponent
            return Attribution(
                owner: Owner(bundleID: nil, displayName: name, teamID: nil), status: .installed, confidence: .medium,
                evidence: [Evidence(rule: "programPresent", detail: "Its program \(program) is still installed.")])
        }
        guard let name = Identifier.appName(fromPath: program) else { return nil }
        return Attribution(
            owner: Owner(bundleID: nil, displayName: name, teamID: nil), status: .orphaned, confidence: .high,
            evidence: [Evidence(rule: "programInsideMissingApp", detail: "Its program was inside \(name).app, which no longer exists.")])
    }

    private func byTeam(_ team: String, rest: String) -> Attribution {
        if let a = apple(rest) { return a }
        if let app = index.app(bundleID: rest) {
            return installed(app, .high, Evidence(rule: "exactBundleID", detail: "Named after \(app.bundleID)."))
        }
        let teamApps = index.apps(teamID: team)
        if let app = Self.closest(to: rest, among: teamApps) ?? teamApps.first {
            return installed(app, .medium, Evidence(rule: "teamID", detail: "Same developer team (\(team)) as \(app.name)."))
        }
        let known = reference.knownApp(for: rest)
        return Attribution(
            owner: Owner(bundleID: nil, displayName: known?.name ?? "Developer team \(team)", teamID: team),
            status: .orphaned, confidence: .medium,
            evidence: [Evidence(rule: "teamIDNotInstalled", detail: "Belongs to developer team \(team); no installed app is from that team.")])
    }

    private func byBundleID(_ id: String) -> Attribution {
        if let app = index.app(bundleID: id) {
            return installed(app, .high, Evidence(rule: "exactBundleID", detail: "Named after \(app.bundleID)."))
        }
        if let url = locateApp(id) {
            let name = url.deletingPathExtension().lastPathComponent
            return Attribution(
                owner: Owner(bundleID: id, displayName: name, teamID: nil), status: .installed, confidence: .high,
                evidence: [Evidence(rule: "launchServices", detail: "macOS knows an app with this ID at \(url.path).")])
        }
        let lowered = id.lowercased()
        if let app = index.apps.first(where: { lowered.hasPrefix($0.bundleID.lowercased() + ".") }) {
            return installed(app, .medium, Evidence(rule: "extendsAppID", detail: "Its ID extends \(app.bundleID), the ID of \(app.name)."))
        }
        let known = reference.knownApp(for: id)
        if let known, known.bundleID?.lowercased() != lowered { return byKnown(known, id: id) }
        if let vendor = Identifier.vendorPrefix(id) {
            let vendorApps = index.apps.filter { $0.bundleID.lowercased().hasPrefix(vendor + ".") }
            let parts = id.split(separator: ".")
            if !vendorApps.isEmpty, parts.count >= 4 {
                // com.vendor.Product.part — another product from the same vendor doesn't count.
                let product = Identifier.normalize(String(parts[2]))
                let sameProduct = vendorApps.filter { app in
                    let p = app.bundleID.split(separator: ".")
                    return p.count >= 3 && Identifier.normalize(String(p[2])) == product
                }
                if let app = Self.closest(to: id, among: sameProduct) {
                    return installed(app, .medium, Evidence(rule: "vendorPrefix", detail: "Same developer and product as \(app.name)."))
                }
                return Attribution(
                    owner: Owner(bundleID: nil, displayName: String(parts[2]), teamID: nil), status: .orphaned, confidence: .medium,
                    evidence: [Evidence(rule: "vendorProductNotInstalled",
                                        detail: "Named after \(parts[2]) from \(vendor); other apps from that developer are installed, but not this one.")])
            }
            if let app = Self.closest(to: id, among: vendorApps) {
                return installed(app, .medium, Evidence(rule: "vendorPrefix", detail: "Same developer prefix (\(vendor)) as \(app.name)."))
            }
        }
        return Attribution(
            owner: Owner(bundleID: id, displayName: known?.name ?? Identifier.displayName(forBundleID: id), teamID: nil),
            status: .orphaned, confidence: .high,
            evidence: [Evidence(rule: "exactBundleIDNotInstalled", detail: "Named after \(id); no app with that ID is installed.")])
    }

    private func byName(_ name: String) -> Attribution {
        if let known = reference.knownApp(for: name) { return byKnown(known, id: name) }
        if let app = index.app(nameToken: name) {
            return installed(app, .low, Evidence(rule: "nameToken", detail: "Only the name matches \(app.name)."))
        }
        return Attribution(owner: nil, status: .unknown, confidence: .none,
                           evidence: [Evidence(rule: "noMatch", detail: "No installed app, known app or macOS component matches “\(name)”.")])
    }

    /// A known app or component: shared library, installed, or gone.
    private func byKnown(_ known: KnownApp, id: String) -> Attribution {
        if known.isLibrary { return library(known) }
        if let a = installedKnown(known) { return a }
        return Attribution(
            owner: Owner(bundleID: known.bundleID, displayName: known.name, teamID: nil), status: .orphaned,
            confidence: .medium,
            evidence: [Evidence(rule: "knownApp", detail: "Matches the known pattern for \(known.name), which is not installed.")])
    }

    /// The app whose bundle ID shares the most leading components with `id`.
    static func closest(to id: String, among apps: [InstalledApp]) -> InstalledApp? {
        let target = id.lowercased().split(separator: ".")
        func shared(_ app: InstalledApp) -> Int {
            zip(target, app.bundleID.lowercased().split(separator: ".")).prefix { $0 == $1 }.count
        }
        return apps.max { shared($0) < shared($1) }
    }

    /// A known app counts as installed when its own app, any app from the same vendor, or its tool is present.
    private func installedKnown(_ known: KnownApp) -> Attribution? {
        let evidence = Evidence(rule: "knownApp", detail: "Matches the known pattern for \(known.name).")
        if let app = known.bundleID.flatMap(index.app(bundleID:)) { return installed(app, .medium, evidence) }
        if let id = known.bundleID, let url = locateApp(id) {
            return Attribution(
                owner: Owner(bundleID: id, displayName: known.name, teamID: nil), status: .installed, confidence: .medium,
                evidence: [evidence, Evidence(rule: "launchServices", detail: "macOS knows \(known.name) at \(url.path).")])
        }
        for k in reference.knownApps where k.name == known.name {
            if let path = k.installedPaths?.first(where: fileExists) {
                return Attribution(
                    owner: Owner(bundleID: nil, displayName: known.name, teamID: nil), status: .installed, confidence: .medium,
                    evidence: [evidence, Evidence(rule: "toolPresent", detail: "\(known.name) is installed at \(path).")])
            }
            let app = Identifier.isBundleLike(k.pattern + ".x")
                ? index.app(vendorPrefix: k.pattern)
                : index.apps.first { Identifier.normalize($0.name).hasPrefix(Identifier.normalize(k.pattern)) }
            guard let app else { continue }
            var a = installed(app, .medium, evidence)
            // A vendor-wide entry (Adobe, Microsoft) names the vendor, not whichever of its apps matched.
            if known.bundleID == nil {
                a.owner = Owner(bundleID: nil, displayName: known.name, teamID: app.teamID)
                a.evidence.append(Evidence(rule: "vendorInstalled", detail: "\(app.name) from the same developer is installed."))
            }
            return a
        }
        return nil
    }

    private func library(_ known: KnownApp) -> Attribution {
        Attribution(
            owner: Owner(bundleID: nil, displayName: known.name, teamID: nil), status: .unknown, confidence: .low,
            evidence: [Evidence(rule: "sharedComponent", detail: "Created by \(known.name), \(known.note) It can't be tied to one app.")])
    }

    private func installed(_ app: InstalledApp, _ confidence: Confidence, _ evidence: Evidence) -> Attribution {
        Attribution(
            owner: Owner(bundleID: app.bundleID, displayName: app.name, teamID: app.teamID),
            status: app.isAppleSigned || app.source == .system ? .apple : .installed,
            confidence: confidence, evidence: [evidence])
    }

    static let appleOwner = Owner(bundleID: nil, displayName: "Apple", teamID: nil)
}
