import Foundation
import Testing
@testable import CoreAIAgent

@Suite("Attachment ingestion")
struct AttachmentIngestionTests {
    @Test("recursively ingests supported text while skipping hidden, binary, and symlink files")
    func boundedRecursiveIngestion() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "nested"), withIntermediateDirectories: true)
        try Data("hello\nworld".utf8).write(to: root.appending(path: "notes.md"))
        try Data("let value = 1".utf8).write(to: root.appending(path: "nested/code.swift"))
        try Data([0, 1, 2]).write(to: root.appending(path: "binary.txt"))
        try Data("hidden".utf8).write(to: root.appending(path: ".hidden.md"))
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: "alias.md"),
            withDestinationURL: root.appending(path: "notes.md")
        )

        let attachments = try AttachmentIngestion().ingest([root])

        #expect(attachments.map(\.name) == ["code.swift", "notes.md"])
        #expect(attachments.first(where: { $0.name == "notes.md" })?.content == "hello\nworld")
    }

    @Test("model context labels attached data as untrusted and preserves newlines")
    func contextEnvelope() {
        let attachments = [ComposerAttachment(
            name: "a&b.md",
            sourcePath: "/tmp/a&b.md",
            content: "first\nsecond",
            byteCount: 12
        )]

        #expect(attachments.modelContext.contains("untrusted data"))
        #expect(attachments.modelContext.contains("name=\"a&amp;b.md\""))
        #expect(attachments.modelContext.contains("first\nsecond"))
    }
}
