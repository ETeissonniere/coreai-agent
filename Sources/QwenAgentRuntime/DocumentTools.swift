import Foundation
import FoundationModels

public struct DocumentDraft: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var markdown: String
    public var revision: Int

    public init(id: UUID = UUID(), title: String, markdown: String, revision: Int = 1) {
        self.id = id
        self.title = title
        self.markdown = markdown
        self.revision = revision
    }
}

public actor DocumentArtifactStore {
    private var drafts: [UUID: DocumentDraft] = [:]
    private var insertionOrder: [UUID] = []
    private var storedCharacterCount = 0
    public let maximumDrafts: Int
    public let maximumStoredCharacters: Int

    public init(maximumDrafts: Int = 32, maximumStoredCharacters: Int = 1_000_000) {
        self.maximumDrafts = max(1, maximumDrafts)
        self.maximumStoredCharacters = max(1, maximumStoredCharacters)
    }

    public func create(title: String, markdown: String) throws -> DocumentDraft {
        guard markdown.count <= maximumStoredCharacters else {
            throw DocumentToolError.storeQuotaExceeded(maximumCharacters: maximumStoredCharacters)
        }
        while drafts.count >= maximumDrafts
            || storedCharacterCount + markdown.count > maximumStoredCharacters {
            guard let oldestID = insertionOrder.first else { break }
            insertionOrder.removeFirst()
            if let removed = drafts.removeValue(forKey: oldestID) {
                storedCharacterCount -= removed.markdown.count
            }
        }
        let draft = DocumentDraft(title: title, markdown: markdown)
        drafts[draft.id] = draft
        insertionOrder.append(draft.id)
        storedCharacterCount += markdown.count
        return draft
    }

    public func draft(id: UUID) -> DocumentDraft? { drafts[id] }
    public func allDrafts() -> [DocumentDraft] { insertionOrder.compactMap { drafts[$0] } }
    public func retainedCharacterCount() -> Int { storedCharacterCount }
}

public enum DocumentToolError: Error, LocalizedError, Equatable {
    case invalidTitle
    case contentTooLarge(maximumCharacters: Int)
    case storeQuotaExceeded(maximumCharacters: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidTitle: "The document title is empty or too long."
        case .contentTooLarge(let maximum): "The document exceeds \(maximum) characters."
        case .storeQuotaExceeded(let maximum): "The draft exceeds the store quota of \(maximum) characters."
        }
    }
}

@Generable(description: "A document draft to create in memory")
public struct CreateDocumentArguments: Sendable, Equatable {
    @Guide(description: "A short filename-safe document title")
    public var title: String
    @Guide(description: "The complete document in Markdown")
    public var markdown: String

    public init(title: String, markdown: String) {
        self.title = title
        self.markdown = markdown
    }
}

public struct CreateDocumentDraftTool: Tool {
    public let name = "createDocumentDraft"
    public let description = "Creates a Markdown document draft in memory for the user to preview. It does not save files."
    private let store: DocumentArtifactStore
    private let maximumCharacters: Int
    private let journal: AgentEventJournal?
    private let budget: ToolCallBudget?

    public init(
        store: DocumentArtifactStore,
        maximumCharacters: Int = 100_000,
        journal: AgentEventJournal? = nil,
        budget: ToolCallBudget? = nil
    ) {
        self.store = store
        self.maximumCharacters = maximumCharacters
        self.journal = journal
        self.budget = budget
    }

    public func call(arguments: CreateDocumentArguments) async throws -> String {
        try Task.checkCancellation()
        try await budget?.consume()
        let title = arguments.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 160 else { throw DocumentToolError.invalidTitle }
        guard arguments.markdown.count <= maximumCharacters else {
            throw DocumentToolError.contentTooLarge(maximumCharacters: maximumCharacters)
        }
        let draft = try await store.create(title: title, markdown: arguments.markdown)
        await journal?.record(.artifact(.init(
            id: draft.id,
            title: draft.title,
            mediaType: "text/markdown",
            content: draft.markdown,
            revision: draft.revision
        )))
        return "Created in-memory document draft \(draft.id.uuidString), revision \(draft.revision), titled \"\(draft.title)\". The user must explicitly approve any file export."
    }
}
