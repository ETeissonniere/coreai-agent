import Foundation

enum MessageRole: String, Codable, Sendable {
    case user
    case assistant
}

enum MessageGenerationState: String, Codable, Equatable, Sendable {
    case streaming
    case complete
    case stopped
    case failed
}

struct ChatMessage: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let role: MessageRole
    var text: String
    var reasoning: String?
    var generationState: MessageGenerationState?
    let createdAt: Date
    var metrics: GenerationMetrics?
    var wasStopped: Bool
    var attachmentContext: String?
    var contextSnapshot: ContextStatus?
    var kvCacheSnapshot: KVCacheSnapshot?

    init(
        id: UUID = UUID(),
        role: MessageRole,
        text: String,
        reasoning: String? = nil,
        generationState: MessageGenerationState? = nil,
        createdAt: Date = .now,
        metrics: GenerationMetrics? = nil,
        wasStopped: Bool = false,
        attachmentContext: String? = nil,
        contextSnapshot: ContextStatus? = nil,
        kvCacheSnapshot: KVCacheSnapshot? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.reasoning = reasoning
        self.generationState = generationState
        self.createdAt = createdAt
        self.metrics = metrics
        self.wasStopped = wasStopped
        self.attachmentContext = attachmentContext
        self.contextSnapshot = contextSnapshot
        self.kvCacheSnapshot = kvCacheSnapshot
    }
}

struct ConversationFolder: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String

    init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}

struct Conversation: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var title: String
    var messages: [ChatMessage]
    var folderID: UUID?
    var isPinned: Bool
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String = "New Chat",
        messages: [ChatMessage] = [],
        folderID: UUID? = nil,
        isPinned: Bool = false
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.folderID = folderID
        self.isPinned = isPinned
        self.updatedAt = .now
    }
}

struct GenerationMetrics: Codable, Equatable, Sendable {
    var promptTokens: Int
    var cachedTokens: Int
    var generatedTokens: Int
    var reasoningTokens: Int
    var timeToFirstToken: Duration
    var elapsed: Duration

    var tokensPerSecond: Double {
        let seconds = elapsed.seconds - timeToFirstToken.seconds
        guard seconds > 0 else { return 0 }
        return Double(generatedTokens) / seconds
    }

    var prefillTokensPerSecond: Double {
        guard timeToFirstToken.seconds > 0 else { return 0 }
        return Double(promptTokens - cachedTokens) / timeToFirstToken.seconds
    }

    var contextTokens: Int { promptTokens + generatedTokens }
}

private extension Duration {
    var seconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

enum ModelPhase: Equatable, Sendable {
    case missing
    case loading
    case ready
    case generating
    case compacting
    case failed(String)

    var label: String {
        switch self {
        case .missing: "Model Required"
        case .loading: "Loading Weights"
        case .ready: "Ready"
        case .generating: "Generating"
        case .compacting: "Compacting Context"
        case .failed: "Unavailable"
        }
    }
}
