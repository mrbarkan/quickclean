import Foundation

public enum Category: String, Codable, Sendable, CaseIterable, Hashable {
    case apps, leftovers, background, addons, devTooling, settings

    public var label: String {
        switch self {
        case .apps: "Apps"
        case .leftovers: "Leftovers"
        case .background: "Background"
        case .addons: "Add-ons"
        case .devTooling: "Dev Tooling"
        case .settings: "Settings"
        }
    }
}

public enum Kind: String, Codable, Sendable, Hashable {
    case app, appSupport, cache, preferences, container, groupContainer, savedState, httpStorage
    case webkitData, logs, cookies
    case launchAgent, launchDaemon, privilegedHelper, systemExtension, kext, loginItems
    case quickLookPlugin, spotlightImporter, preferencePane, inputMethod, font, colorProfile
    case screenSaver, audioPlugin, internetPlugin, safariExtension, mailBundle
    case brewFormula, brewCask, brewTap, devCache, devData, dotfile
    case settingsKey
}

public enum OwnerStatus: String, Codable, Sendable, Hashable {
    case installed, orphaned, apple, unknown
}

public enum Confidence: String, Codable, Sendable, Hashable, Comparable {
    case none, low, medium, high

    private var order: Int {
        switch self { case .none: 0; case .low: 1; case .medium: 2; case .high: 3 }
    }
    public static func < (a: Self, b: Self) -> Bool { a.order < b.order }
}

public enum Risk: String, Codable, Sendable, Hashable, Comparable {
    case safe, review, careful, protected

    private var order: Int {
        switch self { case .safe: 0; case .review: 1; case .careful: 2; case .protected: 3 }
    }
    public static func < (a: Self, b: Self) -> Bool { a.order < b.order }
}

public enum Badge: String, Codable, Sendable, Hashable {
    case broken, stale, running
}

public struct Owner: Codable, Sendable, Hashable {
    public var bundleID: String?
    public var displayName: String
    public var teamID: String?

    public init(bundleID: String?, displayName: String, teamID: String?) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.teamID = teamID
    }
}

public struct Evidence: Codable, Sendable, Hashable {
    public var rule: String
    public var detail: String

    public init(rule: String, detail: String) {
        self.rule = rule
        self.detail = detail
    }
}

public struct ScanIssue: Codable, Sendable, Hashable {
    public var subject: String
    public var reason: String

    public init(subject: String, reason: String) {
        self.subject = subject
        self.reason = reason
    }
}

/// A fully attributed and classified item, ready for review.
public struct Finding: Identifiable, Codable, Sendable, Hashable {
    public var id: String
    public var category: Category
    public var kind: Kind
    public var title: String
    public var paths: [String]
    public var size: Int64?
    public var owner: Owner?
    public var ownerStatus: OwnerStatus
    public var confidence: Confidence
    public var risk: Risk
    public var badges: Set<Badge>
    public var explanation: String
    public var evidence: [Evidence]
    public var modified: Date?
    public var defaultSelected: Bool
    public var protectedReason: String?

    public init(
        id: String, category: Category, kind: Kind, title: String, paths: [String], size: Int64?,
        owner: Owner?, ownerStatus: OwnerStatus, confidence: Confidence, risk: Risk, badges: Set<Badge>,
        explanation: String, evidence: [Evidence], modified: Date?, defaultSelected: Bool,
        protectedReason: String?
    ) {
        self.id = id
        self.category = category
        self.kind = kind
        self.title = title
        self.paths = paths
        self.size = size
        self.owner = owner
        self.ownerStatus = ownerStatus
        self.confidence = confidence
        self.risk = risk
        self.badges = badges
        self.explanation = explanation
        self.evidence = evidence
        self.modified = modified
        self.defaultSelected = defaultSelected
        self.protectedReason = protectedReason
    }
}

/// Attribution a scanner already knows (Homebrew items, settings keys, apps).
public struct PresetAttribution: Sendable {
    public var owner: Owner?
    public var status: OwnerStatus
    public var confidence: Confidence
    public var evidence: Evidence

    public init(owner: Owner?, status: OwnerStatus, confidence: Confidence, evidence: Evidence) {
        self.owner = owner
        self.status = status
        self.confidence = confidence
        self.evidence = evidence
    }
}

/// What a scanner reports before attribution and classification.
public struct RawFinding: Sendable {
    public var category: Category
    public var kind: Kind
    public var name: String
    public var paths: [URL]
    public var identifier: String?
    public var programPath: String?
    public var preset: PresetAttribution?
    public var badges: Set<Badge>
    public var modified: Date?
    public var detail: String?
    public var riskOverride: Risk?
    public var inSystemDomain: Bool
    public var idOverride: String?

    public init(
        category: Category, kind: Kind, name: String, paths: [URL], identifier: String? = nil,
        programPath: String? = nil, preset: PresetAttribution? = nil, badges: Set<Badge> = [],
        modified: Date? = nil, detail: String? = nil, riskOverride: Risk? = nil,
        inSystemDomain: Bool = false, idOverride: String? = nil
    ) {
        self.category = category
        self.kind = kind
        self.name = name
        self.paths = paths
        self.identifier = identifier
        self.programPath = programPath
        self.preset = preset
        self.badges = badges
        self.modified = modified
        self.detail = detail
        self.riskOverride = riskOverride
        self.inSystemDomain = inSystemDomain
        self.idOverride = idOverride
    }
}
