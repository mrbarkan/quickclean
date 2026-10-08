import Foundation
import Testing
@testable import QuickcleanCore

private func fingerprint(_ root: URL) -> [String] {
    let fm = FileManager.default
    var lines: [String] = []
    let walker = fm.enumerator(atPath: root.path)
    while let rel = walker?.nextObject() as? String {
        let attrs = (try? fm.attributesOfItem(atPath: root.appending(path: rel).path)) ?? [:]
        lines.append("\(rel)|\(attrs[.size] ?? "")|\(attrs[.modificationDate] ?? "")|\(attrs[.posixPermissions] ?? "")")
    }
    return lines.sorted()
}

@Test func fullScanLeavesFixtureUntouched() async throws {
    let (fx, env) = try makeFixtureMac()
    let before = fingerprint(fx.base)
    _ = await ScanEngine(env: env).run()
    #expect(fingerprint(fx.base) == before)
}

@Test func coreSourcesContainNoWriteAPIs() throws {
    let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Sources/QuickcleanCore")
    let forbidden = ["removeItem", "moveItem", "trashItem", "createFile", "write(to:", "replaceItem",
                     "copyItem", "createDirectory", "unlink(", "rename(", "linkItem", "setAttributes"]
    var checked = 0
    let walker = FileManager.default.enumerator(atPath: sources.path)
    while let rel = walker?.nextObject() as? String {
        guard rel.hasSuffix(".swift") else { continue }
        let text = try String(contentsOf: sources.appending(path: rel), encoding: .utf8)
        for token in forbidden {
            #expect(!text.contains(token), "\(rel) uses forbidden write API \(token)")
        }
        checked += 1
    }
    #expect(checked > 10)
}
