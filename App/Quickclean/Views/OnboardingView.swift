import SwiftUI

private let fullDiskAccessURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

struct OnboardingView: View {
    @Environment(ScanModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Quickclean needs Full Disk Access", systemImage: "lock.open.display").font(.title2.weight(.semibold))
            Text("Most of what apps leave behind lives in folders macOS protects, like ~/Library/Containers and Mail data. Without Full Disk Access, Quickclean can't see them and its results will be incomplete.")
            Text("Quickclean only reads. This version never changes, moves or deletes anything.")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("1. Click **Open System Settings**.")
                Text("2. Turn on **Quickclean** in the list (use **+** if it's missing).")
                Text("3. Come back here and scan again.")
            }
            HStack {
                if model.hasFullDiskAccess {
                    Label("Access granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Spacer()
                Button("Continue Without Access") { dismiss() }
                Button("Open System Settings") { NSWorkspace.shared.open(fullDiskAccessURL) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
        .onChange(of: model.hasFullDiskAccess) { _, granted in
            if granted {
                dismiss()
                model.scan()
            }
        }
    }
}

struct FullDiskAccessBanner: View {
    let action: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text("Results are incomplete without Full Disk Access.")
            Spacer()
            Button("Fix…", action: action)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.yellow.opacity(0.12))
    }
}
