import QuickcleanCore
import SwiftUI

struct ContentView: View {
    @Environment(ScanModel.self) private var model
    @State private var sidebar: SidebarItem? = .overview
    @State private var inspected: Finding.ID?
    @State private var showInspector = true
    @State private var showOnboarding = false
    @State private var showIssues = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView(selection: $sidebar)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            VStack(spacing: 0) {
                if !model.hasFullDiskAccess {
                    FullDiskAccessBanner { showOnboarding = true }
                }
                switch sidebar {
                case .category(let c):
                    FindingsTable(category: c, inspected: $inspected)
                default:
                    OverviewView(sidebar: $sidebar, inspected: $inspected)
                }
                StatusBar(showIssues: $showIssues)
            }
            .inspector(isPresented: $showInspector) {
                InspectorView(finding: model.finding(id: inspected))
                    .inspectorColumnWidth(min: 240, ideal: 290, max: 420)
            }
        }
        .navigationTitle("Quickclean")
        .navigationSubtitle(model.version)
        .searchable(text: $model.search, placement: .toolbar, prompt: "Search names, owners, paths")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.isScanning {
                    Button("Cancel", systemImage: "stop.circle") { model.cancel() }
                } else {
                    Button("Scan", systemImage: "arrow.clockwise") { model.scan() }
                }
                Toggle(isOn: $model.groupByOwner) { Label("Group by Owner", systemImage: "rectangle.3.group") }
                FilterMenu()
                Menu("Export", systemImage: "square.and.arrow.up") {
                    Button("JSON Report…") { model.export(.json) }
                    Button("Markdown Summary…") { model.export(.markdown) }
                }
                .disabled(model.findings.isEmpty)
                Button("Inspector", systemImage: "sidebar.trailing") { showInspector.toggle() }
            }
        }
        .sheet(isPresented: $showOnboarding) { OnboardingView() }
        .onAppear {
            model.refreshFullDiskAccess()
            if !model.hasFullDiskAccess { showOnboarding = true }
            if model.findings.isEmpty && !model.isScanning { model.scan() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshFullDiskAccess()
        }
        .onChange(of: sidebar) { inspected = nil }
    }
}

struct FilterMenu: View {
    @Environment(ScanModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Menu {
            Picker("Owner Status", selection: $model.statusFilter) {
                Text("Any Owner Status").tag(OwnerStatus?.none)
                Divider()
                ForEach([OwnerStatus.orphaned, .installed, .unknown, .apple], id: \.self) {
                    Text($0.label).tag(OwnerStatus?.some($0))
                }
            }
            Picker("Risk", selection: $model.riskFilter) {
                Text("Any Risk").tag(Risk?.none)
                Divider()
                ForEach([Risk.safe, .review, .careful, .protected], id: \.self) { Text($0.label).tag(Risk?.some($0)) }
            }
            Picker("Minimum Confidence", selection: $model.minimumConfidence) {
                ForEach([Confidence.none, .low, .medium, .high], id: \.self) {
                    Text($0 == .none ? "Any Confidence" : "\($0.label) or Higher").tag($0)
                }
            }
            Divider()
            Toggle("Show Stock macOS Items", isOn: $model.showStock)
            if model.hasActiveFilters {
                Divider()
                Button("Clear Filters") { model.clearFilters() }
            }
        } label: {
            Label("Filter", systemImage: model.hasActiveFilters
                  ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
    }
}

struct StatusBar: View {
    @Environment(ScanModel.self) private var model
    @Binding var showIssues: Bool

    var body: some View {
        HStack(spacing: 12) {
            if model.isScanning {
                ProgressView().controlSize(.small)
                Text("Scanning…")
            } else if let last = model.lastScan {
                Text("Scanned \(last.formatted(date: .omitted, time: .shortened))")
            }
            Spacer()
            if !model.checked.isEmpty {
                Text("\(model.checked.count) selected · \(model.totalText(model.checkedBytes))")
                    .help("Removal arrives in a later version. Selections are included in exported reports.")
            }
            if !model.issues.isEmpty {
                Button("\(model.issues.count) issue\(model.issues.count == 1 ? "" : "s")", systemImage: "exclamationmark.triangle") {
                    showIssues.toggle()
                }
                .buttonStyle(.borderless)
                .popover(isPresented: $showIssues, arrowEdge: .top) { IssuesList() }
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

struct IssuesList: View {
    @Environment(ScanModel.self) private var model

    var body: some View {
        List(model.issues, id: \.self) { issue in
            VStack(alignment: .leading, spacing: 2) {
                Text(issue.subject).font(.headline).lineLimit(1).truncationMode(.middle)
                Text(issue.reason).foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
        .frame(width: 420, height: 280)
    }
}
