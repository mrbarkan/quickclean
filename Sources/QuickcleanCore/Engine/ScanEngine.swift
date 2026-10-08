import Foundation

public enum ScanEvent: Sendable {
    case started(ScanCategory)
    case finding(Finding)
    case issue(ScanIssue)
    case finished(ScanCategory)
    case size(id: String, bytes: Int64)
    case completed
}

/// Runs the scanners, attributes and classifies their output, then measures sizes.
public struct ScanEngine: Sendable {
    let env: ScanEnvironment
    let reference: ReferenceData
    let categories: Set<ScanCategory>

    static let sizingConcurrency = 8

    public init(env: ScanEnvironment, reference: ReferenceData = .bundled, categories: Set<ScanCategory> = Set(ScanCategory.allCases)) {
        self.env = env
        self.reference = reference
        self.categories = categories
    }

    /// Streams results as they are found. Cancelling the consuming task stops the scan.
    public func events() -> AsyncStream<ScanEvent> {
        AsyncStream { continuation in
            let task = Task {
                await produce { continuation.yield($0) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Collects a whole scan, sizes included, sorted by category then id.
    public func run() async -> (findings: [Finding], issues: [ScanIssue]) {
        var findings: [Finding] = []
        var sizes: [String: Int64] = [:]
        var issues: [ScanIssue] = []
        for await event in events() {
            switch event {
            case .finding(let f): findings.append(f)
            case .size(let id, let bytes): sizes[id] = bytes
            case .issue(let i): issues.append(i)
            case .started, .finished, .completed: break
            }
        }
        for i in findings.indices { findings[i].size = sizes[findings[i].id] }
        let order = Dictionary(uniqueKeysWithValues: ScanCategory.allCases.enumerated().map { ($1, $0) })
        findings.sort { (order[$0.category]!, $0.id) < (order[$1.category]!, $1.id) }
        return (findings, issues)
    }

    private func produce(_ emit: @escaping @Sendable (ScanEvent) -> Void) async {
        let needsBrew = categories.contains(.apps) || categories.contains(.devTooling) || categories.contains(.leftovers)
        let brewInfo = needsBrew ? await DevToolingScanner.fetchBrewInfo(env) : nil
        let caskApps = (try? brewInfo?.get()).map { DevToolingScanner.caskApps(from: Data($0.utf8)) } ?? []

        let index = AppIndexBuilder.build(env, reference: reference, caskApps: caskApps)
        let bundles = env.bundles
        let attributor = Attributor(index: index, reference: reference, locateApp: { bundles.locateApp(bundleID: $0) })
        let classifier = Classifier(reference: reference, env: env)

        let scanners: [any Scanner] = [
            AppsScanner(), LeftoversScanner(), BackgroundScanner(), AddonsScanner(),
            DevToolingScanner(brewInfo: brewInfo), SettingsScanner(reference: reference),
        ].filter { categories.contains($0.category) }

        let env = env
        var seen = Set<String>()
        var toSize: [Finding] = []
        await withTaskGroup(of: (ScanCategory, ScanOutput).self) { group in
            for scanner in scanners {
                group.addTask {
                    emit(.started(scanner.category))
                    return (scanner.category, await scanner.scan(env, index: index))
                }
            }
            for await (category, output) in group {
                for raw in output.findings {
                    let finding = classifier.classify(raw, attributor.attribute(raw))
                    guard seen.insert(finding.id).inserted else { continue }
                    emit(.finding(finding))
                    if finding.kind != .settingsKey, !finding.paths.isEmpty { toSize.append(finding) }
                }
                output.issues.forEach { emit(.issue($0)) }
                emit(.finished(category))
            }
        }
        guard !Task.isCancelled else { return }

        let calculator = SizeCalculator()
        await withTaskGroup(of: Void.self) { group in
            var pending = toSize.makeIterator()
            func next() -> Bool {
                guard !Task.isCancelled, let f = pending.next() else { return false }
                group.addTask {
                    emit(.size(id: f.id, bytes: await calculator.size(of: f.paths.map { URL(fileURLWithPath: $0) })))
                }
                return true
            }
            for _ in 0..<Self.sizingConcurrency where next() {}
            while await group.next() != nil { _ = next() }
        }
        emit(.completed)
    }
}
