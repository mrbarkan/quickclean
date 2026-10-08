import Foundation

/// Plain-language descriptions built from the evidence.
public enum Explainer {
    public static func explain(_ raw: RawFinding, _ a: Attribution, home: URL) -> String {
        var parts: [String] = []
        if let path = raw.paths.first {
            parts.append("\(kindLabel(raw.kind)) at \(abbreviate(path.deletingLastPathComponent().path, home: home)).")
        }
        parts.append(ownerSentence(a))
        if let detail = raw.detail { parts.append(detail) }
        let why = a.evidence.map(\.detail).joined(separator: " ")
        if !why.isEmpty { parts.append("Why: \(why)") }
        return parts.joined(separator: " ")
    }

    static func ownerSentence(_ a: Attribution) -> String {
        let name = a.owner?.displayName ?? "an unknown app"
        switch a.status {
        case .installed: return "Belongs to \(name), which is installed."
        case .orphaned: return "Belongs to \(name), which is no longer installed."
        case .apple: return "Part of macOS or an Apple app."
        case .unknown: return "Could not identify which app created this."
        }
    }

    public static func abbreviate(_ path: String, home: URL) -> String {
        let h = home.path
        if path == h { return "~" }
        return path.hasPrefix(h + "/") ? "~" + path.dropFirst(h.count) : path
    }

    public static func kindLabel(_ kind: Kind) -> String {
        switch kind {
        case .app: "App"
        case .appSupport: "App data"
        case .cache: "Cache"
        case .preferences: "Settings file"
        case .container: "Sandbox container"
        case .groupContainer: "Shared container"
        case .savedState: "Saved window state"
        case .httpStorage: "Web storage"
        case .webkitData: "Web data"
        case .logs: "Logs"
        case .cookies: "Cookies"
        case .launchAgent: "Launch agent"
        case .launchDaemon: "Launch daemon"
        case .privilegedHelper: "Privileged helper"
        case .systemExtension: "System extension"
        case .kext: "Kernel extension"
        case .loginItems: "Login items"
        case .quickLookPlugin: "Quick Look plugin"
        case .spotlightImporter: "Spotlight importer"
        case .preferencePane: "Settings pane"
        case .inputMethod: "Input method"
        case .font: "Font"
        case .colorProfile: "Color profile"
        case .screenSaver: "Screen saver"
        case .audioPlugin: "Audio plug-in"
        case .internetPlugin: "Internet plug-in"
        case .safariExtension: "Safari extension"
        case .mailBundle: "Mail plug-in"
        case .fileSystem: "File system plug-in"
        case .cameraPlugin: "Camera plug-in"
        case .service: "Quick Action or service"
        case .appScripts: "App scripts folder"
        case .pkgReceipt: "Installer receipt"
        case .defaultHandler: "Default app"
        case .commandLineTool: "Command-line tool"
        case .framework: "Shared framework or runtime"
        case .appExtension: "App extension"
        case .systemConfig: "System configuration"
        case .settingsReference: "Setting that points elsewhere"
        case .brewFormula: "Homebrew formula"
        case .brewCask: "Homebrew cask"
        case .brewTap: "Homebrew tap"
        case .devCache: "Developer cache"
        case .devData: "Developer data"
        case .dotfile: "Dotfile"
        case .settingsKey: "Setting"
        }
    }
}
