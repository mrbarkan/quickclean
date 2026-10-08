import AppKit
import Observation
import QuickcleanCore
import UniformTypeIdentifiers

enum SidebarItem: Hashable {
    case overview
    case category(ScanCategory)
}

enum ScanState { case idle, scanning, done }

enum ExportFormat { case json, markdown }

struct OwnerGroup: Identifiable {
    var id: String { name }
    var name: String
    var items: [Finding]
    var bytes: Int64
}

@MainActor @Observable
final class ScanModel {
    private(set) var findings: [Finding] = []
    private var position: [String: Int] = [:]
    private(set) var issues: [ScanIssue] = []
    private(set) var state: [ScanCategory: ScanState] = [:]
    private(set) var isScanning = false
    private(set) var sizesReady = false
    private(set) var lastScan: Date?
    private(set) var hasFullDiskAccess = true

    var checked: Set<String> = []
    var showStock = false
    var groupByOwner = false
    var statusFilter: OwnerStatus?
    var riskFilter: Risk?
    var minimumConfidence: Confidence = .none
    var search = ""

    private var scanTask: Task<Void, Never>?
    let reference = ReferenceData.bundled

    var version: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? Quickclean.version
        let channel = info?["QCChannel"] as? String ?? Quickclean.channel
        return channel == "stable" ? v : "\(v) \(channel.capitalized)"
    }

    var overview: Overview { Overview(findings: findings, reference: reference) }

    // MARK: Scanning

    func refreshFullDiskAccess() {
        hasFullDiskAccess = FullDiskAccess.isGranted(home: FileManager.default.homeDirectoryForCurrentUser)
    }

    func scan() {
        cancel()
        findings = []
        position = [:]
        issues = []
        checked = []
        state = Dictionary(uniqueKeysWithValues: ScanCategory.allCases.map { ($0, ScanState.scanning) })
        isScanning = true
        sizesReady = false
        refreshFullDiskAccess()
        let engine = ScanEngine(env: .live(), reference: reference)
        scanTask = Task { [weak self] in
            for await event in engine.events() {
                guard let self, !Task.isCancelled else { return }
                self.apply(event)
            }
            self?.finish()
        }
    }

    func cancel() {
        scanTask?.cancel()
        scanTask = nil
        if isScanning { finish() }
    }

    private func finish() {
        isScanning = false
        lastScan = Date()
        for (c, s) in state where s == .scanning { state[c] = .done }
    }

    private func apply(_ event: ScanEvent) {
        switch event {
        case .started(let c): state[c] = .scanning
        case .finished(let c): state[c] = .done
        case .finding(let f):
            position[f.id] = findings.count
            findings.append(f)
            if f.defaultSelected { checked.insert(f.id) }
        case .size(let id, let bytes):
            if let i = position[id] { findings[i].size = bytes }
        case .issue(let issue): issues.append(issue)
        case .completed: sizesReady = true
        }
    }

    // MARK: Selection

    func isChecked(_ f: Finding) -> Bool { checked.contains(f.id) }

    func setChecked(_ f: Finding, _ on: Bool) {
        guard f.risk != .protected else { return }
        if on { checked.insert(f.id) } else { checked.remove(f.id) }
    }

    /// Totals are only meaningful once every size has been measured.
    func totalText(_ bytes: Int64) -> String { sizesReady ? ByteFormat.string(bytes) : "Measuring…" }

    var checkedBytes: Int64 {
        checked.compactMap { position[$0].map { findings[$0].size ?? 0 } }.reduce(0, +)
    }

    func finding(id: String?) -> Finding? { id.flatMap { position[$0] }.map { findings[$0] } }

    // MARK: Filtering

    func count(_ c: ScanCategory) -> Int { findings.lazy.filter { $0.category == c && self.passesStock($0) }.count }

    func bytes(_ c: ScanCategory) -> Int64 {
        findings.lazy.filter { $0.category == c && self.passesStock($0) }.reduce(0) { $0 + ($1.size ?? 0) }
    }

    private func passesStock(_ f: Finding) -> Bool {
        showStock || f.category == .settings || f.ownerStatus != .apple
    }

    func visible(_ c: ScanCategory) -> [Finding] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return findings.filter { f in
            f.category == c && passesStock(f)
                && (statusFilter == nil || f.ownerStatus == statusFilter)
                && (riskFilter == nil || f.risk == riskFilter)
                && f.confidence >= minimumConfidence
                && (query.isEmpty || f.title.lowercased().contains(query)
                    || (f.owner?.displayName.lowercased().contains(query) ?? false)
                    || f.paths.contains { $0.lowercased().contains(query) })
        }
    }

    func groups(_ items: [Finding]) -> [OwnerGroup] {
        Dictionary(grouping: items) { $0.owner?.displayName ?? "Unidentified" }
            .map { OwnerGroup(name: $0.key, items: $0.value, bytes: $0.value.reduce(0) { $0 + ($1.size ?? 0) }) }
            .sorted { ($0.bytes, $1.name) > ($1.bytes, $0.name) }
    }

    var hasActiveFilters: Bool {
        statusFilter != nil || riskFilter != nil || minimumConfidence != .none
    }

    func clearFilters() {
        statusFilter = nil
        riskFilter = nil
        minimumConfidence = .none
    }

    // MARK: Export

    func export(_ format: ExportFormat) {
        let report = Report(version: version, generatedAt: lastScan ?? Date(), findings: findings, issues: issues)
        let panel = NSSavePanel()
        let stamp = Date().formatted(.iso8601.year().month().day())
        switch format {
        case .json:
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "Quickclean-\(stamp).json"
        case .markdown:
            panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
            panel.nameFieldStringValue = "Quickclean-\(stamp).md"
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = format == .json ? try report.json() : Data(report.markdown(reference: reference).utf8)
            try data.write(to: url, options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

extension Finding {
    var ownerName: String { owner?.displayName ?? "—" }
    var sortSize: Int64 { size ?? -1 }
    var sortDate: Date { modified ?? .distantPast }
    var primaryURL: URL? { paths.first.map { URL(fileURLWithPath: $0) } }
}
