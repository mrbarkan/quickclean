import QuickcleanCore
import QuickLook
import SwiftUI

struct FindingsTable: View {
    @Environment(ScanModel.self) private var model
    let category: ScanCategory
    @Binding var inspected: Finding.ID?
    @State private var sortOrder = [KeyPathComparator(\Finding.sortSize, order: .reverse)]
    @State private var previewURL: URL?

    var body: some View {
        let rows = model.visible(category).sorted(using: sortOrder)
        Table(of: Finding.self, selection: $inspected, sortOrder: $sortOrder) {
            TableColumn("") { (f: Finding) in
                Toggle("", isOn: Binding(get: { model.isChecked(f) }, set: { model.setChecked(f, $0) }))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .disabled(f.risk == .protected)
                    .help(f.risk == .protected ? (f.protectedReason ?? "Protected") : "Mark for removal (removal arrives in a later version)")
            }
            .width(22)
            TableColumn("Name", value: \.title) { (f: Finding) in
                HStack(spacing: 6) {
                    FindingIcon(finding: f)
                    Text(f.title).lineLimit(1).truncationMode(.middle)
                    if f.risk == .protected { Image(systemName: "lock.fill").foregroundStyle(.secondary).imageScale(.small) }
                }
                .help(f.paths.first ?? f.title)
            }
            .width(min: 220, ideal: 320)
            TableColumn("Owner", value: \.ownerName) { (f: Finding) in Text(f.ownerName).lineLimit(1) }
                .width(min: 90, ideal: 140)
            TableColumn("Status", value: \.ownerStatus.rawValue) { (f: Finding) in StatusPills(finding: f) }
                .width(min: 90, ideal: 150)
            TableColumn("Risk", value: \.risk) { (f: Finding) in Pill(text: f.risk.label, color: f.risk.color).help(f.risk.help) }
                .width(70)
            TableColumn("Confidence", value: \.confidence) { (f: Finding) in Text(f.confidence.label).foregroundStyle(.secondary) }
                .width(80)
            TableColumn("Size", value: \.sortSize) { (f: Finding) in
                Text(ByteFormat.string(f.size)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(80)
            TableColumn(category == .apps ? "Last Used" : "Modified", value: \.sortDate) { (f: Finding) in
                Text(f.modified?.formatted(date: .abbreviated, time: .omitted) ?? "—").foregroundStyle(.secondary)
            }
            .width(100)
        } rows: {
            if model.groupByOwner {
                ForEach(model.groups(rows)) { group in
                    Section("\(group.name) — \(group.items.count) · \(ByteFormat.string(group.bytes))") {
                        ForEach(group.items) { TableRow($0) }
                    }
                }
            } else {
                ForEach(rows) { TableRow($0) }
            }
        }
        .contextMenu(forSelectionType: Finding.ID.self) { ids in
            let selected = ids.compactMap { model.finding(id: $0) }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(selected.compactMap(\.primaryURL))
            }
            .disabled(selected.allSatisfy { $0.primaryURL == nil })
            Button("Quick Look") { previewURL = selected.first?.primaryURL }
            Divider()
            Button("Copy Path") { copy(selected.flatMap(\.paths).joined(separator: "\n")) }
            Button("Copy Explanation") { copy(selected.map(\.explanation).joined(separator: "\n\n")) }
        }
        .onKeyPress(.space) {
            previewURL = model.finding(id: inspected)?.primaryURL
            return previewURL == nil ? .ignored : .handled
        }
        .quickLookPreview($previewURL)
        .overlay {
            if rows.isEmpty && !model.isScanning {
                ContentUnavailableView(
                    model.search.isEmpty && !model.hasActiveFilters ? "Nothing Found" : "No Matches",
                    systemImage: category.symbol,
                    description: Text(model.search.isEmpty && !model.hasActiveFilters
                                      ? "Nothing in \(category.label) besides stock macOS items."
                                      : "Try a different search or clear the filters."))
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct FindingIcon: View {
    let finding: Finding

    var body: some View {
        if finding.kind == .app, let path = finding.paths.first {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 16, height: 16)
        } else {
            Image(systemName: finding.kind.symbol).foregroundStyle(.secondary).frame(width: 16)
        }
    }
}

extension Kind {
    var symbol: String {
        switch self {
        case .app: "app"
        case .appSupport, .container, .groupContainer: "folder"
        case .cache, .devCache: "internaldrive"
        case .preferences, .settingsKey: "slider.horizontal.3"
        case .savedState: "macwindow"
        case .httpStorage, .webkitData, .cookies, .internetPlugin, .safariExtension: "globe"
        case .logs: "doc.text"
        case .launchAgent, .launchDaemon, .loginItems: "gearshape"
        case .privilegedHelper: "lock.shield"
        case .systemExtension, .kext: "cpu"
        case .quickLookPlugin: "eye"
        case .spotlightImporter: "magnifyingglass"
        case .preferencePane: "switch.2"
        case .inputMethod: "keyboard"
        case .font: "textformat"
        case .colorProfile: "paintpalette"
        case .screenSaver: "sparkles.tv"
        case .audioPlugin: "waveform"
        case .mailBundle: "envelope"
        case .fileSystem: "externaldrive"
        case .cameraPlugin: "web.camera"
        case .service: "gearshape.arrow.trianglehead.2.clockwise.rotate.90"
        case .appScripts: "applescript"
        case .brewFormula, .brewCask, .brewTap: "mug"
        case .devData: "shippingbox"
        case .dotfile: "doc.badge.gearshape"
        }
    }
}
