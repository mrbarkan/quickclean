import QuickcleanCore
import SwiftUI

struct SidebarView: View {
    @Environment(ScanModel.self) private var model
    @Binding var selection: SidebarItem?

    var body: some View {
        List(selection: $selection) {
            Label("Overview", systemImage: "gauge.with.dots.needle.33percent").tag(SidebarItem.overview)
            Section("Inventory") {
                ForEach(ScanCategory.allCases, id: \.self) { c in
                    HStack {
                        Label(c.label, systemImage: c.symbol)
                        Spacer()
                        if model.state[c] == .scanning {
                            ProgressView().controlSize(.mini)
                        } else if model.state[c] == .done {
                            VStack(alignment: .trailing, spacing: 0) {
                                Text("\(model.count(c))").monospacedDigit()
                                Text(model.totalText(model.bytes(c))).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .tag(SidebarItem.category(c))
                }
            }
        }
    }
}

extension ScanCategory {
    var symbol: String {
        switch self {
        case .apps: "app.badge"
        case .leftovers: "archivebox"
        case .background: "gearshape.2"
        case .addons: "puzzlepiece.extension"
        case .devTooling: "hammer"
        case .settings: "slider.horizontal.3"
        case .system: "wrench.and.screwdriver"
        }
    }
}
