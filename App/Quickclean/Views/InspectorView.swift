import QuickcleanCore
import SwiftUI

struct InspectorView: View {
    let finding: Finding?
    @State private var showEvidence = false

    var body: some View {
        if let f = finding {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 8) {
                        FindingIcon(finding: f).font(.title2)
                        Text(f.title).font(.title3.weight(.semibold)).textSelection(.enabled)
                    }
                    HStack(spacing: 4) {
                        StatusPills(finding: f)
                        Pill(text: f.risk.label, color: f.risk.color)
                        Pill(text: "\(f.confidence.label) confidence", color: .secondary)
                    }
                    if let reason = f.protectedReason {
                        Label(reason, systemImage: "lock.fill").foregroundStyle(.secondary)
                    }
                    Text(explanationBody(f)).textSelection(.enabled)
                    Text(f.risk.help).font(.callout).foregroundStyle(.secondary)

                    DisclosureGroup("Why Quickclean thinks so", isExpanded: $showEvidence) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(f.evidence, id: \.self) { e in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(e.rule).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    Text(e.detail)
                                }
                            }
                        }
                        .padding(.top, 4)
                    }

                    if !f.paths.isEmpty {
                        section("Location") {
                            ForEach(f.paths, id: \.self) { path in
                                HStack(alignment: .top) {
                                    Text(path).font(.callout.monospaced()).textSelection(.enabled)
                                    Spacer()
                                    Button("Reveal", systemImage: "arrow.right.circle") {
                                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                                    }
                                    .labelStyle(.iconOnly)
                                    .buttonStyle(.borderless)
                                }
                            }
                        }
                    }
                    section("Details") {
                        Grid(alignment: .leading, verticalSpacing: 4) {
                            row("Owner", f.owner?.displayName ?? "Unidentified")
                            if let id = f.owner?.bundleID { row("Bundle ID", id) }
                            if let team = f.owner?.teamID { row("Team ID", team) }
                            row("Size", ByteFormat.string(f.size))
                            if let m = f.modified { row(f.kind == .app ? "Last used" : "Modified", m.formatted(date: .abbreviated, time: .shortened)) }
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView("No Selection", systemImage: "sidebar.trailing",
                                   description: Text("Select an item to see what it is and who owns it."))
        }
    }

    /// The explanation without the trailing "Why:" sentence, which the evidence section shows.
    private func explanationBody(_ f: Finding) -> String {
        f.explanation.components(separatedBy: " Why: ").first ?? f.explanation
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content()
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}
