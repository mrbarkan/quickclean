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

        var id = Identifier.strip(raw.identifier ?? raw.name)
        if id.lowercased().hasPrefix("group.") { id = String(id.dropFirst(6)) }

        if let a = apple(id) { return a }
        if let (team, rest) = Identifier.teamPrefix(id) { return byTeam(team, rest: rest) }
        if Identifier.isBundleLike(id) { return byBundleID(id) }
        return byName(id)
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
        let known = reference.knownApp(for: id)
        if let known, let installedApp = known.bundleID.flatMap(index.app(bundleID:)) {
            return installed(installedApp, .medium, Evidence(rule: "knownApp", detail: "Matches the known pattern for \(known.name)."))
        }
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
            if let app = known.bundleID.flatMap(index.app(bundleID:)) ?? index.app(nameToken: known.name) {
                return installed(app, .medium, Evidence(rule: "knownApp", detail: "Matches the known pattern for \(known.name)."))
            }
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

    private func installed(_ app: InstalledApp, _ confidence: Confidence, _ evidence: Evidence) -> Attribution {
        Attribution(
            owner: Owner(bundleID: app.bundleID, displayName: app.name, teamID: app.teamID),
            status: app.isAppleSigned || app.source == .system ? .apple : .installed,
            confidence: confidence, evidence: [evidence])
    }

    static let appleOwner = Owner(bundleID: nil, displayName: "Apple", teamID: nil)
}
