import Foundation
import Testing
@testable import CoreAIAgent

@Test func legacyApplicationSupportDirectoryMigratesWithoutLosingContents() throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "CoreAIAgent-ApplicationSupportTests-\(UUID())",
        directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let legacy = root.appending(path: ApplicationSupportLocation.legacyDirectoryName)
    try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
    try Data("saved chat".utf8).write(to: legacy.appending(path: "AppState.json"))

    let resolved = ApplicationSupportLocation.resolve(in: root)

    #expect(resolved.lastPathComponent == ApplicationSupportLocation.currentDirectoryName)
    #expect(!FileManager.default.fileExists(atPath: legacy.path))
    #expect(try String(contentsOf: resolved.appending(path: "AppState.json"), encoding: .utf8) == "saved chat")
}

@Test func existingCurrentApplicationSupportDirectoryIsNeverOverwritten() throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "CoreAIAgent-ApplicationSupportTests-\(UUID())",
        directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let current = root.appending(path: ApplicationSupportLocation.currentDirectoryName)
    let legacy = root.appending(path: ApplicationSupportLocation.legacyDirectoryName)
    try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
    let legacyHarness = legacy.appending(path: "AgentHarness")
    try FileManager.default.createDirectory(at: legacyHarness, withIntermediateDirectories: true)
    try Data("current".utf8).write(to: current.appending(path: "AppState.json"))
    try Data("legacy".utf8).write(to: legacy.appending(path: "AppState.json"))
    try Data("run".utf8).write(to: legacyHarness.appending(path: "index.json"))

    let resolved = ApplicationSupportLocation.resolve(in: root)

    #expect(resolved.standardizedFileURL.path == current.standardizedFileURL.path)
    #expect(FileManager.default.fileExists(atPath: legacy.path))
    #expect(try String(contentsOf: current.appending(path: "AppState.json"), encoding: .utf8) == "current")
    #expect(try String(
        contentsOf: current.appending(path: "AgentHarness/index.json"),
        encoding: .utf8
    ) == "run")
    #expect(!FileManager.default.fileExists(atPath: legacyHarness.path))
}
