import Foundation
import CoreAIAgentRuntime

protocol ModelServing: AnyObject, Sendable {
    func load(resourcesAt url: URL, for profile: ModelProfile) async throws
    func generate(request: ModelGenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error>
    func cancel() async
    func resolveApproval(id: UUID, approved: Bool) async -> Bool
}

enum GenerationEvent: Sendable {
    case attemptStarted(UUID)
    case context(ContextStatus)
    case content(GenerationUpdate)
    case agent(AgentLifecycleEvent)
    case compaction(ModelCompactionSnapshot)
}

struct ModelGenerationRequest: Sendable {
    var conversationID: UUID
    var prompt: String
    var enabledSkillIDs: Set<String>
    /// Canonical persisted context, excluding `prompt`, in chronological order.
    var history: [ModelHistoryItem]
    var compaction: ModelCompactionSnapshot?
    var userMessageID: UUID?
    var assistantMessageID: UUID?
    /// Semantic pieces of the current prompt. Counts for these pieces are
    /// tokenizer-based estimates; the runtime only publishes aggregate input usage.
    var promptComponents: [ContextPromptComponent]
    var modelProfile: ModelProfile
    var reasoningEnabled: Bool

    init(
        conversationID: UUID,
        prompt: String,
        enabledSkillIDs: Set<String>,
        history: [ModelHistoryItem],
        compaction: ModelCompactionSnapshot?,
        userMessageID: UUID? = nil,
        assistantMessageID: UUID? = nil,
        promptComponents: [ContextPromptComponent] = [],
        modelProfile: ModelProfile = .deep,
        reasoningEnabled: Bool = true
    ) {
        self.conversationID = conversationID
        self.prompt = prompt
        self.enabledSkillIDs = enabledSkillIDs
        self.history = history
        self.compaction = compaction
        self.userMessageID = userMessageID
        self.assistantMessageID = assistantMessageID
        self.promptComponents = promptComponents
        self.modelProfile = modelProfile
        self.reasoningEnabled = reasoningEnabled
    }
}

struct ContextPromptComponent: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var category: ContextTokenCategory
    var text: String

    init(id: UUID = UUID(), category: ContextTokenCategory, text: String) {
        self.id = id
        self.category = category
        self.text = text
    }
}

struct ModelHistoryItem: Codable, Equatable, Sendable, Identifiable {
    /// `toolBundle` remains decodable for saved state created by older builds,
    /// but it is transient activity rather than conversation context.
    enum Kind: String, Codable, Sendable { case user, assistant, toolBundle }
    var id: UUID
    var kind: Kind
    var content: String
    var turnID: UUID? = nil

    var isRetainedConversationContext: Bool {
        switch kind {
        case .user, .assistant: true
        case .toolBundle: false
        }
    }
}

extension Sequence where Element == ModelHistoryItem {
    var retainedConversationContext: [ModelHistoryItem] {
        filter(\.isRetainedConversationContext)
    }
}

struct ModelCompactionSnapshot: Codable, Equatable, Sendable {
    var generation: Int
    var memory: String
    var retainedHistoryIDs: [UUID]
    var sourceHistoryIDs: [UUID]
    var sourceTokenEstimate: Int
}

enum ContextState: String, Codable, Equatable, Sendable {
    case normal
    case elevated
    case high
    case compacting
}

struct ContextStatus: Codable, Equatable, Sendable {
    var usedTokens: Int
    var activeBudget: Int
    var state: ContextState
    var compactionCount: Int
    var modelLimit: Int
    var outputReserve: Int
    var conversationMemory: String? = nil
    var composition: ContextTokenComposition? = nil

    var inputLimit: Int { modelLimit - outputReserve }

    var utilization: Double {
        guard inputLimit > 0 else { return 1 }
        return min(Double(usedTokens) / Double(inputLimit), 1)
    }
}

enum ContextTokenCategory: String, Codable, CaseIterable, Sendable {
    case systemAndMemory
    case user
    case attachments
    case reasoning
    case assistant
    case toolCalls
    case toolResults
    case unclassified
}

enum TokenCountBasis: String, Codable, Sendable {
    /// Supplied by FoundationModels/Core AI usage or KV-cache telemetry.
    case runtimeExact
    /// Allocated from text byte estimates because the runtime does not expose
    /// token spans for individual transcript entries.
    case proportionalEstimate
}

struct ContextTokenSlice: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var turnID: UUID?
    var category: ContextTokenCategory
    var tokens: Int
    var basis: TokenCountBasis
}

struct ContextTokenComposition: Codable, Equatable, Sendable {
    var inputTokens: Int
    var generatedTokens: Int
    var outputReserve: Int
    var slices: [ContextTokenSlice]

    var usedTokens: Int { inputTokens + generatedTokens }
    var remainingTokens: Int { max(0, outputReserve - generatedTokens) }

    func tokens(for category: ContextTokenCategory) -> Int {
        slices.lazy.filter { $0.category == category }.reduce(0) { $0 + $1.tokens }
    }

    var turns: [ContextTokenTurn] {
        var order = [UUID]()
        var grouped = [UUID: [ContextTokenSlice]]()
        for slice in slices {
            guard let turnID = slice.turnID else { continue }
            if grouped[turnID] == nil { order.append(turnID) }
            grouped[turnID, default: []].append(slice)
        }
        return order.map { ContextTokenTurn(id: $0, slices: grouped[$0] ?? []) }
    }
}

struct ContextTokenTurn: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var slices: [ContextTokenSlice]
    var tokens: Int { slices.reduce(0) { $0 + $1.tokens } }
}

struct GenerationUpdate: Sendable {
    let text: String
    let reasoning: String?
    let metrics: GenerationMetrics
    let kvCache: KVCacheSnapshot
}

struct KVCacheSnapshot: Codable, Equatable, Sendable {
    let usedTokens: Int
    let allocatedTokens: Int
    let maximumTokens: Int
    let reusedPrefixTokens: Int

    var allocationUtilization: Double {
        guard allocatedTokens > 0 else { return 0 }
        return min(Double(usedTokens) / Double(allocatedTokens), 1)
    }

    var maximumUtilization: Double {
        guard maximumTokens > 0 else { return 0 }
        return min(Double(usedTokens) / Double(maximumTokens), 1)
    }
}

enum ModelServiceError: LocalizedError {
    case invalidBundle
    case unsupportedModel

    var errorDescription: String? {
        switch self {
        case .invalidBundle:
            "The selected folder is not a valid exported Core AI language bundle."
        case .unsupportedModel:
            "Qwen3.8 is not yet supported by Apple's Core AI exporter."
        }
    }
}
