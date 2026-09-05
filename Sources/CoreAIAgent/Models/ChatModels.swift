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

enum ModelProfile: String, Codable, CaseIterable, Equatable, Sendable {
    case fast
    case deep

    var label: String { self == .fast ? "Fast" : "Deep" }
    var modelName: String { self == .fast ? "Nemotron 3 Nano 4B" : "Qwen3.8 27B" }
    var quantization: String { self == .fast ? "INT8" : "INT4" }
    var defaultReasoningEnabled: Bool { self == .deep }
    var resourcePath: String {
        switch self {
        case .fast:
            "Models/Nemotron-3-Nano-4B-CoreAI/gpu-pipelined/nemotron_3_nano_4b_decode_int8hu"
        case .deep:
            "Models/Qwen3.8-27B-CoreAI/gpu-pipelined/qwen3_8_27b_decode_int4linh8_pf16"
        }
    }
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
    var modelProfile: ModelProfile
    var reasoningEnabled: Bool

    init(
        id: UUID = UUID(),
        title: String = "New Chat",
        messages: [ChatMessage] = [],
        folderID: UUID? = nil,
        isPinned: Bool = false,
        modelProfile: ModelProfile = .deep,
        reasoningEnabled: Bool? = nil
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.folderID = folderID
        self.isPinned = isPinned
        self.updatedAt = .now
        self.modelProfile = modelProfile
        self.reasoningEnabled = reasoningEnabled ?? modelProfile.defaultReasoningEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, messages, folderID, isPinned, updatedAt, modelProfile, reasoningEnabled
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        messages = try values.decode([ChatMessage].self, forKey: .messages)
        folderID = try values.decodeIfPresent(UUID.self, forKey: .folderID)
        isPinned = try values.decode(Bool.self, forKey: .isPinned)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        modelProfile = try values.decodeIfPresent(ModelProfile.self, forKey: .modelProfile) ?? .deep
        reasoningEnabled = try values.decodeIfPresent(Bool.self, forKey: .reasoningEnabled)
            ?? modelProfile.defaultReasoningEnabled
    }
}

struct GenerationMetrics: Codable, Equatable, Sendable {
    var generatedTokens: Int
    var reasoningTokens: Int
    var timeToFirstToken: Duration
    var elapsed: Duration
    var prefillTokensPerSecond: Double
    var decodeTokensPerSecond: Double
    var initialPrefill: Duration
    var toolCallGeneration: Duration
    var toolExecution: Duration
    var continuationPrefill: Duration
    var decode: Duration
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
