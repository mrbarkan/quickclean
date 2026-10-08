import Foundation

/// Turns an attributed raw finding into a reviewable `Finding`: risk, badges, title, selection.
public struct Classifier: Sendable {
    let reference: ReferenceData
    let env: ScanEnvironment

    static let staleAge: TimeInterval = 180 * 86_400

    private static let protectedDotfiles = [
        ".ssh", ".gnupg", ".zshrc", ".zprofile", ".zshenv", ".bashrc", ".bash_profile", ".profile",
        ".gitconfig", ".Trash", ".CFUserTextEncoding", ".config",
    ]
    private static let backgroundKinds: Set<Kind> = [
        .launchAgent, .launchDaemon, .privilegedHelper, .systemExtension, .kext, .loginItems,
    ]
    private static let reviewKinds: Set<Kind> = [
        .preferences, .appSupport, .container, .groupContainer, .dotfile, .brewFormula, .brewCask, .brewTap, .app,
    ]
    private static let disposableKinds: Set<Kind> = [.cache, .logs, .savedState, .httpStorage, .webkitData, .cookies]

    public init(reference: ReferenceData, env: ScanEnvironment) {
        self.reference = reference
        self.env = env
    }

    public func classify(_ raw: RawFinding, _ a: Attribution) -> Finding {
        let (risk, reason) = risk(raw, a)
        var badges = raw.badges
        if let modified = raw.modified, env.now.timeIntervalSince(modified) > Self.staleAge { badges.insert(.stale) }
        if let id = a.owner?.bundleID, env.runningBundleIDs.contains(id) { badges.insert(.running) }

        let selected = risk == .safe && a.confidence == .high && a.status == .orphaned && !badges.contains(.running)
        return Finding(
            id: raw.idOverride ?? "\(raw.category.rawValue):\(raw.paths.first?.path ?? raw.name)",
            category: raw.category, kind: raw.kind, title: title(raw, a), paths: raw.paths.map(\.path), size: nil,
            owner: a.owner, ownerStatus: a.status, confidence: a.confidence, risk: risk, badges: badges,
            explanation: Explainer.explain(raw, a, home: env.home), evidence: a.evidence, modified: raw.modified,
            defaultSelected: selected, protectedReason: reason)
    }

    /// Most restrictive rule wins: protected › careful › scanner override › review › safe.
    public func risk(_ raw: RawFinding, _ a: Attribution) -> (Risk, String?) {
        if let reason = protectedReason(raw, a) { return (.protected, reason) }
        if Self.backgroundKinds.contains(raw.kind) || raw.inSystemDomain || a.confidence <= .low { return (.careful, nil) }
        if let override = raw.riskOverride { return (override, nil) }
        if Self.reviewKinds.contains(raw.kind) || a.status == .installed { return (.review, nil) }
        if Self.disposableKinds.contains(raw.kind) && a.status == .orphaned { return (.safe, nil) }
        return (.review, nil)
    }

    private func protectedReason(_ raw: RawFinding, _ a: Attribution) -> String? {
        if raw.kind == .settingsKey { return "System setting. Resetting it will come in a later version." }
        if a.status == .apple { return "Part of macOS or an Apple app." }
        let home = env.home.path
        let protectedPaths = reference.stock.protectedHomePaths + Self.protectedDotfiles
        for path in raw.paths.map(\.path) {
            if path == "/System" || path.hasPrefix("/System/") { return "Inside the protected macOS system volume." }
            for rel in protectedPaths {
                let p = "\(home)/\(rel)"
                if path == p || path.hasPrefix(p + "/") { return "Holds your personal data or configuration (\(rel))." }
            }
        }
        return nil
    }

    private func title(_ raw: RawFinding, _ a: Attribution) -> String {
        switch raw.kind {
        case .app, .settingsKey, .brewFormula, .brewCask, .brewTap, .devCache, .devData, .dotfile:
            raw.name
        default:
            "\(a.owner?.displayName ?? raw.name) · \(Explainer.kindLabel(raw.kind))"
        }
    }
}
