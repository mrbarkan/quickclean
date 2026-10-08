import Foundation
import Testing
@testable import QuickcleanCore

private let brewJSON = """
{"formulae": [
  {"name": "node", "full_name": "node", "tap": "homebrew/core", "desc": "JavaScript runtime",
   "installed": [{"version": "24.1.0", "installed_on_request": true}]},
  {"name": "abseil", "full_name": "abseil", "tap": "homebrew/core", "desc": "C++ Common Libraries",
   "installed": [{"version": "20260817.0", "installed_on_request": false}]},
  {"name": "bun", "full_name": "oven-sh/bun/bun", "tap": "oven-sh/bun", "desc": "Bun runtime",
   "installed": [{"version": "1.3.0", "installed_on_request": true}]}
 ],
 "casks": [
  {"token": "iterm2", "name": ["iTerm2"], "desc": "Terminal emulator", "tap": "homebrew/cask",
   "artifacts": [{"app": ["iTerm.app"]}, {"zap": [{"trash": ["~/Library/Caches/com.googlecode.iterm2"]}]}]}
 ]}
"""

private func brewFixture() throws -> (Fixture, String) {
    let fx = try Fixture()
    let brew = try fx.file("root/opt/homebrew/bin/brew", "#!/bin/sh").path
    return (fx, brew)
}

@Test func homebrewFormulaeCasksAndTaps() async throws {
    let (fx, brew) = try brewFixture()
    let env = fx.env(commands: [
        "\(brew) info --json=v2 --installed": .ok(brewJSON),
        "\(brew) leaves": .ok("node\noven-sh/bun/bun\n"),
    ])
    let out = await DevToolingScanner().scan(env, index: AppIndex(apps: []))
    let byName = Dictionary(out.findings.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
    #expect(byName["node"]?.kind == .brewFormula)
    #expect(byName["node"]?.riskOverride == .review)
    #expect(byName["node"]?.paths.first?.path == fx.root.appending(path: "opt/homebrew/Cellar/node").path)
    #expect(byName["abseil"]?.riskOverride == .careful)
    #expect(byName["abseil"]?.detail?.contains("Needed by other formulae") == true)
    #expect(byName["oven-sh/bun/bun"]?.riskOverride == .review)
    #expect(byName["iterm2"]?.kind == .brewCask)
    #expect(byName["oven-sh/bun"]?.kind == .brewTap)
    #expect(byName["node"]?.preset?.owner?.displayName == "Homebrew")
    #expect(out.issues.isEmpty)
}

@Test func caskAppsFromJSON() {
    #expect(DevToolingScanner.caskApps(from: Data(brewJSON.utf8)) == ["iTerm.app"])
    #expect(DevToolingScanner.caskApps(from: Data("garbage".utf8)).isEmpty)
}

@Test func missingHomebrewIsAnIssueButCachesStillFound() async throws {
    let fx = try Fixture()
    try fx.dir("home/.npm/_cacache")
    try fx.dir("home/Library/Developer/Xcode/DerivedData/Foo-abc")
    let out = await DevToolingScanner().scan(fx.env(), index: AppIndex(apps: []))
    #expect(out.issues.map(\.subject) == ["Homebrew"])
    let caches = out.findings.filter { $0.kind == .devCache }
    #expect(Set(caches.map(\.name)) == ["npm cache", "Xcode DerivedData"])
    #expect(caches.allSatisfy { $0.riskOverride == .safe })
}

@Test func garbageBrewOutputIsAnIssue() async throws {
    let (fx, brew) = try brewFixture()
    let env = fx.env(commands: ["\(brew) info --json=v2 --installed": .ok("garbage"), "\(brew) leaves": .ok("")])
    let out = await DevToolingScanner().scan(env, index: AppIndex(apps: []))
    #expect(out.issues.count == 1)
    #expect(out.findings.allSatisfy { $0.kind != .brewFormula })
}

@Test func devDataAndDotfiles() async throws {
    let fx = try Fixture()
    try fx.dir("home/.pyenv/versions/3.12.0")
    try fx.dir("home/.cursor")
    try fx.dir("home/.ssh")
    try fx.file("home/.DS_Store")
    try fx.file("home/.CFUserTextEncoding")
    let out = await DevToolingScanner().scan(fx.env(), index: AppIndex(apps: []))
    #expect(out.findings.first { $0.kind == .devData }?.name == "pyenv Python versions")
    let dotfiles = Set(out.findings.filter { $0.kind == .dotfile }.map(\.name))
    #expect(dotfiles == [".cursor", ".ssh"])
    #expect(out.findings.first { $0.name == ".cursor" }?.identifier == "cursor")
}
