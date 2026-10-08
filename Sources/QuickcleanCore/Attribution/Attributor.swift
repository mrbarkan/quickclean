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
        if let program = raw.programPath, let a = byProgram(program) { return a }

        var id = Self.dropGroupPrefix(Identifier.strip(raw.identifier ?? raw.name))
        while id.hasPrefix(".") { id.removeFirst() }

        if let a = apple(id) { return a }
        if let (team, rest) = Identifier.teamPrefix(id) { return byTeam(team, rest: Self.dropGroupPrefix(rest)) }
        if Identifier.isBundleLike(id) { return byBundleID(id) }
        return byName(id)
    }

    private static func dropGroupPrefix(_ id: String) -> String {
        for prefix in ["systemgroup.", "groups.", "group."] where id.lowercased().hasPrefix(prefix) {
            return String(id.dropFirst(prefix.count))
        }
        return id
    }

    // MARK: Rules

    private func apple(_ id: String) -> Attribution? {
        if id.lowercased().hasPrefix("com.apple.") {
            return Attribution(owner: Self.appleOwner, status: .apple, confidence: .high,
                               evidence: [Evidence(rule: "apple", detail: "“\(id)” uses Apple’s com.apple prefix.")])
        }
        if reference.stock.isAppleName(id) {
            return Attribution(owner: Self.appleOwner, status: .apple, confidence: .high,
                               evidence: [Evidence(rule: "apple", detail: "“\(id)” is a name macOS uses for its own data.")])
        }
        return nil
    }

    private func byProgram(_ program: String) -> Attribution? {
        if let app = index.app(containing: program) {
            return installed(app, .high, Evidence(rule: "programInsideApp", detail: "Its program is inside \(app.name).app."))
        }
        guard let name = Identifier.appName(fromPath: program), !fileExists(program) else { return nil }
        return Attribution(
            owner: Owner(bundleID: nil, displayName: name, teamID: nil), status: .orphaned, confidence: .high,
            evidence: [Evidence(rule: "programInsideMissingApp", detail: "Its program was inside \(name).app, which no longer exists.")])
    }

    private func byTeam(_ team: String, rest: String) -> Attribution {
        if let a = apple(rest) { return a }
        if let app = index.app(bundleID: rest) {
            return installed(app, .high, Evidence(rule: "exactBundleID", detail: "Named after \(app.bundleID)."))
        }
        if let app = index.apps(teamID: team).first {
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
        if let known, known.isLibrary { return library(known) }
        if let known, let a = installedKnown(known) { return a }
        if let vendor = Identifier.vendorPrefix(id), let app = index.app(vendorPrefix: vendor) {
            return installed(app, .medium, Evidence(rule: "vendorPrefix", detail: "Same developer prefix (\(vendor)) as \(app.name)."))
        }
        if let known, known.bundleID?.lowercased() != id.lowercased() {
            return Attribution(
                owner: Owner(bundleID: known.bundleID, displayName: known.name, teamID: nil), status: .orphaned,
                confidence: .medium,
                evidence: [Evidence(rule: "knownApp", detail: "Matches the known pattern for \(known.name), which is not installed.")])
        }
        return Attribution(
            owner: Owner(bundleID: id, displayName: known?.name ?? Identifier.displayName(forBundleID: id), teamID: nil),
            status: .orphaned, confidence: .high,
            evidence: [Evidence(rule: "exactBundleIDNotInstalled", detail: "Named after \(id); no app with that ID is installed.")])
    }

    private func byName(_ name: String) -> Attribution {
        if let known = reference.knownApp(for: name) {
            if known.isLibrary { return library(known) }
            if let a = installedKnown(known) { return a }
            return Attribution(
                owner: Owner(bundleID: known.bundleID, displayName: known.name, teamID: nil), status: .orphaned,
                confidence: .medium,
                evidence: [Evidence(rule: "knownApp", detail: "Matches the known pattern for \(known.name), which is not installed.")])
        }
        if let app = index.app(nameToken: name) {
            return installed(app, .low, Evidence(rule: "nameToken", detail: "Only the name matches \(app.name)."))
        }
        return Attribution(owner: nil, status: .unknown, confidence: .none,
                           evidence: [Evidence(rule: "noMatch", detail: "No installed app, known app or macOS component matches “\(name)”.")])
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
            if let app { return installed(app, .medium, evidence) }
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
