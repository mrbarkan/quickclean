import QuickcleanCore
import SwiftUI

extension Risk {
    var label: String {
        switch self { case .safe: "Safe"; case .review: "Review"; case .careful: "Careful"; case .protected: "Protected" }
    }
    var color: Color {
        switch self { case .safe: .green; case .review: .blue; case .careful: .orange; case .protected: .gray }
    }
    var help: String {
        switch self {
        case .safe: "Rebuilt automatically or no longer used by anything."
        case .review: "Might hold settings, licenses or saved data. Look before removing."
        case .careful: "Runs in the background, needs admin rights, or its owner is uncertain."
        case .protected: "Part of macOS or your personal data. Never offered for removal."
        }
    }
}

extension Confidence {
    var label: String {
        switch self { case .none: "None"; case .low: "Low"; case .medium: "Medium"; case .high: "High" }
    }
}

extension OwnerStatus {
    var label: String {
        switch self { case .installed: "Installed"; case .orphaned: "Orphaned"; case .apple: "Apple"; case .unknown: "Unidentified" }
    }
    var color: Color {
        switch self { case .installed: .secondary; case .orphaned: .purple; case .apple: .gray; case .unknown: .brown }
    }
}

extension Badge {
    var label: String {
        switch self { case .broken: "Broken"; case .stale: "Stale"; case .running: "Running" }
    }
    var color: Color {
        switch self { case .broken: .red; case .stale: .secondary; case .running: .teal }
    }
    var help: String {
        switch self {
        case .broken: "Points to a program that no longer exists."
        case .stale: "Not changed or used in more than 180 days."
        case .running: "Currently running or loaded."
        }
    }
}

struct Pill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: Capsule())
    }
}

struct StatusPills: View {
    let finding: Finding

    var body: some View {
        HStack(spacing: 4) {
            Pill(text: finding.ownerStatus.label, color: finding.ownerStatus.color)
            ForEach(finding.badges.sorted { $0.rawValue < $1.rawValue }, id: \.self) { b in
                Pill(text: b.label, color: b.color).help(b.help)
            }
        }
    }
}
