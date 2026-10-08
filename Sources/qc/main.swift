import Foundation
import QuickcleanCore

let usage = """
usage: qc scan [--category <name>]... [--json | --markdown]
       qc --version

Categories: \(ScanCategory.allCases.map(\.rawValue).joined(separator: ", "))
Quickclean is read-only: it never changes or deletes anything.
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("qc: \(message)\n\n\(usage)\n".utf8))
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { print(usage); exit(0) }
args.removeFirst()

switch command {
case "--version", "version":
    print("qc \(Quickclean.version) (\(Quickclean.channel))")
    exit(0)
case "-h", "--help", "help":
    print(usage)
    exit(0)
case "scan":
    break
default:
    fail("unknown command “\(command)”")
}

var categories = Set<ScanCategory>()
var format = "text"
while !args.isEmpty {
    let arg = args.removeFirst()
    switch arg {
    case "--json": format = "json"
    case "--markdown": format = "markdown"
    case "--category":
        guard let name = args.first, let c = ScanCategory(rawValue: name) else { fail("--category needs one of the listed names") }
        args.removeFirst()
        categories.insert(c)
    default: fail("unknown option “\(arg)”")
    }
}

let env = ScanEnvironment.live()
if !FullDiskAccess.isGranted(home: env.home) {
    FileHandle.standardError.write(Data("""
    qc: warning: no Full Disk Access — results are incomplete. Grant it to your terminal in
        System Settings › Privacy & Security › Full Disk Access.\n
    """.utf8))
}

let result = await ScanEngine(env: env, categories: categories.isEmpty ? Set(ScanCategory.allCases) : categories).run()
let report = Report(version: Quickclean.version, generatedAt: Date(), findings: result.findings, issues: result.issues)

switch format {
case "json":
    FileHandle.standardOutput.write(try report.json())
    print()
case "markdown":
    print(report.markdown())
default:
    let overview = Overview(findings: result.findings, reference: .bundled)
    let marks: [Risk: String] = [.safe: "·", .review: "?", .careful: "!", .protected: "🔒"]
    print("Quickclean \(Quickclean.version) — \(result.findings.count) items, orphaned items use \(ByteFormat.string(overview.orphanBytes))\n")
    if !overview.customizations.isEmpty {
        print("Customizations still active")
        for f in overview.customizations { print("  \(f.title) — \(f.ownerStatus.rawValue), \(f.risk.rawValue)") }
        print()
    }
    for category in ScanCategory.allCases {
        let items = result.findings.filter { $0.category == category }
        guard !items.isEmpty else { continue }
        print("\(category.label) (\(items.count), \(ByteFormat.string(overview.totals[category]?.bytes)))")
        for f in items {
            let badges = f.badges.isEmpty ? "" : " [" + f.badges.map(\.rawValue).sorted().joined(separator: ", ") + "]"
            let selected = f.defaultSelected ? "✓" : " "
            print("  \(selected) \(marks[f.risk] ?? " ") \(f.title) — \(f.ownerStatus.rawValue)/\(f.confidence.rawValue), \(ByteFormat.string(f.size))\(badges)")
        }
        print()
    }
    if !result.issues.isEmpty {
        print("Issues")
        for i in result.issues { print("  \(i.subject): \(i.reason)") }
    }
}
