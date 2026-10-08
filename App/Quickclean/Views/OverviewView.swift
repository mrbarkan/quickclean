import QuickcleanCore
import SwiftUI

struct OverviewView: View {
    @Environment(ScanModel.self) private var model
    @Binding var sidebar: SidebarItem?
    @Binding var inspected: Finding.ID?

    var body: some View {
        let overview = model.overview
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("How far from fresh?").font(.largeTitle.weight(.semibold))
                    Text(summary(overview)).foregroundStyle(.secondary)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                    ForEach(ScanCategory.allCases, id: \.self) { c in
                        Button { sidebar = .category(c) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Label(c.label, systemImage: c.symbol).font(.headline)
                                Text("\(model.count(c))").font(.system(size: 28, weight: .semibold)).monospacedDigit()
                                Text(model.totalText(model.bytes(c))).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                            .contentShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }
                }

                card("Customizations still active", symbol: "paintbrush.pointed",
                     subtitle: "Third-party items that still change how macOS looks or behaves.") {
                    if overview.customizations.isEmpty {
                        Text(model.isScanning ? "Scanning…" : "None found.").foregroundStyle(.secondary)
                    }
                    ForEach(overview.customizations) { f in
                        Button { open(f) } label: {
                            HStack {
                                FindingIcon(finding: f)
                                Text(f.title)
                                Spacer()
                                StatusPills(finding: f)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                card("Changed macOS settings", symbol: "slider.horizontal.3",
                     subtitle: "Settings that differ from a clean install, including hidden tweaks made from the command line.") {
                    if overview.changedSettings.isEmpty {
                        Text(model.isScanning ? "Scanning…" : "All tracked settings are at their defaults.").foregroundStyle(.secondary)
                    }
                    ForEach(overview.changedSettings) { f in
                        Button { open(f) } label: {
                            HStack {
                                Image(systemName: "slider.horizontal.3").foregroundStyle(.secondary)
                                Text(f.title)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                card("Top orphan owners", symbol: "person.crop.circle.badge.questionmark",
                     subtitle: "Apps that are gone but left files behind.") {
                    if overview.topOrphanOwners.isEmpty {
                        Text(model.isScanning ? "Scanning…" : "None found.").foregroundStyle(.secondary)
                    }
                    ForEach(overview.topOrphanOwners.prefix(10), id: \.name) { o in
                        HStack {
                            Text(o.name)
                            Spacer()
                            Text("\(o.count) item\(o.count == 1 ? "" : "s")").foregroundStyle(.secondary)
                            Text(model.totalText(o.bytes)).monospacedDigit().frame(width: 80, alignment: .trailing)
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
        }
    }

    private func summary(_ o: Overview) -> String {
        if model.isScanning && model.findings.isEmpty { return "Scanning your Mac…" }
        let items = model.findings.filter { $0.ownerStatus != .apple }.count
        return "\(items) things added since macOS was installed. Orphaned leftovers take up \(model.totalText(o.orphanBytes)). Nothing is changed or deleted — this version only looks."
    }

    private func open(_ f: Finding) {
        sidebar = .category(f.category)
        inspected = f.id
    }

    private func card<Content: View>(_ title: String, symbol: String, subtitle: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol).font(.title3.weight(.semibold))
            Text(subtitle).foregroundStyle(.secondary)
            Divider()
            content()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }
}
