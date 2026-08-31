import Foundation

enum WorkspaceAccess: String, Codable, Sendable {
    case readOnly
    case readWrite
}

struct AgentWorkspace: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var rootPath: String
    var access: WorkspaceAccess
    var securityScopedBookmark: Data?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        rootPath: String,
        access: WorkspaceAccess = .readOnly,
        securityScopedBookmark: Data? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.access = access
        self.securityScopedBookmark = securityScopedBookmark
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

enum AgentTaskStatus: String, Codable, Sendable {
    case active
    case archived
}

struct AgentTaskRecord: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var workspaceID: UUID?
    var legacyConversationID: UUID?
    var title: String
    var status: AgentTaskStatus
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        workspaceID: UUID? = nil,
        legacyConversationID: UUID? = nil,
        title: String,
        status: AgentTaskStatus = .active,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.legacyConversationID = legacyConversationID
        self.title = title
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

enum AgentRunStatus: String, Codable, Sendable {
    case queued
    case preparing
    case running
    case awaitingApproval
    case compacting
    case suspended
    case completed
    case cancelled
    case failed
}

struct AgentRunRecord: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let taskID: UUID
    var status: AgentRunStatus
    let resumeKey: UUID
    /// The interrupted run this run replaces. Continuation always starts a fresh model turn;
    /// checkpoints restore durable context, never an in-flight token stream.
    var parentRunID: UUID?
    var lastSequence: Int
    var activeCheckpointID: UUID?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        taskID: UUID,
        status: AgentRunStatus = .queued,
        resumeKey: UUID = UUID(),
        parentRunID: UUID? = nil,
        lastSequence: Int = 0,
        activeCheckpointID: UUID? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.taskID = taskID
        self.status = status
        self.resumeKey = resumeKey
        self.parentRunID = parentRunID
        self.lastSequence = lastSequence
        self.activeCheckpointID = activeCheckpointID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

enum PlanStepStatus: String, Codable, Sendable {
    case pending
    case inProgress
    case completed
    case blocked
}

struct AgentPlanStep: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var title: String
    var detail: String?
    var status: PlanStepStatus

    init(id: UUID = UUID(), title: String, detail: String? = nil, status: PlanStepStatus = .pending) {
        self.id = id
        self.title = title
        self.detail = detail
        self.status = status
    }
}

struct AgentPlan: Codable, Equatable, Sendable {
    var revision: Int
    var explanation: String?
    var steps: [AgentPlanStep]
    var updatedAt: Date

    init(revision: Int = 1, explanation: String? = nil, steps: [AgentPlanStep], updatedAt: Date = .now) {
        self.revision = revision
        self.explanation = explanation
        self.steps = steps
        self.updatedAt = updatedAt
    }
}

enum ToolSideEffect: String, Codable, Sendable {
    case none
    case localWrite
    case networkRead
    case externalMutation
}

struct ToolInvocation: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let toolID: String
    let argumentsJSON: String
    let idempotencyKey: String
    let sideEffect: ToolSideEffect

    init(
        id: UUID = UUID(),
        toolID: String,
        argumentsJSON: String,
        idempotencyKey: String = UUID().uuidString,
        sideEffect: ToolSideEffect = .none
    ) {
        self.id = id
        self.toolID = toolID
        self.argumentsJSON = argumentsJSON
        self.idempotencyKey = idempotencyKey
        self.sideEffect = sideEffect
    }
}

struct ToolResultRecord: Codable, Equatable, Sendable {
    let invocationID: UUID
    let content: String
    let isError: Bool
    let completedAt: Date

    init(invocationID: UUID, content: String, isError: Bool = false, completedAt: Date = .now) {
        self.invocationID = invocationID
        self.content = content
        self.isError = isError
        self.completedAt = completedAt
    }
}

enum ApprovalDecision: String, Codable, Sendable {
    case pending
    case approvedOnce
    case approvedForRun
    case rejected
}

struct ApprovalRequestRecord: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let invocationID: UUID
    let title: String
    let detail: String
    let target: String
    let sendsDataOffDevice: Bool
    let requestedAt: Date
    var decision: ApprovalDecision
    var resolvedAt: Date?

    init(
        id: UUID = UUID(),
        invocationID: UUID,
        title: String,
        detail: String,
        target: String = "",
        sendsDataOffDevice: Bool = false,
        requestedAt: Date = .now,
        decision: ApprovalDecision = .pending,
        resolvedAt: Date? = nil
    ) {
        self.id = id
        self.invocationID = invocationID
        self.title = title
        self.detail = detail
        self.target = target
        self.sendsDataOffDevice = sendsDataOffDevice
        self.requestedAt = requestedAt
        self.decision = decision
        self.resolvedAt = resolvedAt
    }
}

struct AgentArtifact: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let runID: UUID
    var name: String
    var path: String
    var mediaType: String
    var inlineContent: String?
    var contentHash: String?
    var revision: Int
    var createdAt: Date

    init(
        id: UUID = UUID(),
        runID: UUID,
        name: String,
        path: String,
        mediaType: String,
        inlineContent: String? = nil,
        contentHash: String? = nil,
        revision: Int = 1,
        createdAt: Date = .now
    ) {
        self.id = id
        self.runID = runID
        self.name = name
        self.path = path
        self.mediaType = mediaType
        self.inlineContent = inlineContent
        self.contentHash = contentHash
        self.revision = revision
        self.createdAt = createdAt
    }
}

enum SkillScope: String, Codable, Sendable {
    case bundled
    case user
    case workspace
}

enum SkillTrust: String, Codable, Sendable {
    case builtIn
    case bundled
    case local
}

struct AgentSkillMetadata: Identifiable, Codable, Equatable, Sendable {
    var id: String { identity ?? name }
    let name: String
    let description: String
    let version: String?
    let path: String
    let scope: SkillScope
    let allowedTools: [String]
    let modelInvocable: Bool
    let identity: String?
    let contentHash: String?
    let provenance: String?
    let trust: SkillTrust

    init(
        name: String,
        description: String,
        version: String?,
        path: String,
        scope: SkillScope,
        allowedTools: [String],
        modelInvocable: Bool,
        identity: String? = nil,
        contentHash: String? = nil,
        provenance: String? = nil,
        trust: SkillTrust = .local
    ) {
        self.name = name
        self.description = description
        self.version = version
        self.path = path
        self.scope = scope
        self.allowedTools = allowedTools
        self.modelInvocable = modelInvocable
        self.identity = identity
        self.contentHash = contentHash
        self.provenance = provenance
        self.trust = trust
    }

    private enum CodingKeys: String, CodingKey {
        case name, description, version, path, scope, allowedTools, modelInvocable
        case identity, contentHash, provenance, trust
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decode(String.self, forKey: .description)
        version = try container.decodeIfPresent(String.self, forKey: .version)
        path = try container.decode(String.self, forKey: .path)
        scope = try container.decode(SkillScope.self, forKey: .scope)
        allowedTools = try container.decode([String].self, forKey: .allowedTools)
        modelInvocable = try container.decode(Bool.self, forKey: .modelInvocable)
        identity = try container.decodeIfPresent(String.self, forKey: .identity)
        contentHash = try container.decodeIfPresent(String.self, forKey: .contentHash)
        provenance = try container.decodeIfPresent(String.self, forKey: .provenance)
        trust = try container.decodeIfPresent(SkillTrust.self, forKey: .trust) ?? .local
    }
}

enum CompactionPhase: String, Codable, Sendable {
    case idle
    case requested
    case summarizing
    case validating
    case completed
    case failed
}

struct StructuredCompactionState: Codable, Equatable, Sendable {
    static let currentStrategyVersion = 1

    var strategyVersion: Int
    var generation: Int
    var phase: CompactionPhase
    var triggerTokenCount: Int
    var targetTokenCount: Int
    var immutableInstructions: [String]
    var conversationMemory: String
    var currentGoal: String
    var decisions: [String]
    var unresolvedItems: [String]
    var recentEventIDs: [UUID]
    var retainedHistoryIDs: [UUID]
    var sourceHistoryIDs: [UUID]
    var sourceTokenEstimate: Int
    var sourceSequenceRange: ClosedRange<Int>?
    var createdAt: Date

    init(
        strategyVersion: Int = Self.currentStrategyVersion,
        generation: Int,
        phase: CompactionPhase,
        triggerTokenCount: Int,
        targetTokenCount: Int,
        immutableInstructions: [String] = [],
        conversationMemory: String = "",
        currentGoal: String = "",
        decisions: [String] = [],
        unresolvedItems: [String] = [],
        recentEventIDs: [UUID] = [],
        retainedHistoryIDs: [UUID] = [],
        sourceHistoryIDs: [UUID] = [],
        sourceTokenEstimate: Int = 0,
        sourceSequenceRange: ClosedRange<Int>? = nil,
        createdAt: Date = .now
    ) {
        self.strategyVersion = strategyVersion
        self.generation = generation
        self.phase = phase
        self.triggerTokenCount = triggerTokenCount
        self.targetTokenCount = targetTokenCount
        self.immutableInstructions = immutableInstructions
        self.conversationMemory = conversationMemory
        self.currentGoal = currentGoal
        self.decisions = decisions
        self.unresolvedItems = unresolvedItems
        self.recentEventIDs = recentEventIDs
        self.retainedHistoryIDs = retainedHistoryIDs
        self.sourceHistoryIDs = sourceHistoryIDs
        self.sourceTokenEstimate = sourceTokenEstimate
        self.sourceSequenceRange = sourceSequenceRange
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case strategyVersion, generation, phase, triggerTokenCount, targetTokenCount
        case immutableInstructions, conversationMemory, currentGoal, decisions, unresolvedItems
        case recentEventIDs, retainedHistoryIDs, sourceHistoryIDs, sourceTokenEstimate
        case sourceSequenceRange, createdAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        strategyVersion = try values.decode(Int.self, forKey: .strategyVersion)
        generation = try values.decode(Int.self, forKey: .generation)
        phase = try values.decode(CompactionPhase.self, forKey: .phase)
        triggerTokenCount = try values.decode(Int.self, forKey: .triggerTokenCount)
        targetTokenCount = try values.decode(Int.self, forKey: .targetTokenCount)
        immutableInstructions = try values.decodeIfPresent([String].self, forKey: .immutableInstructions) ?? []
        conversationMemory = try values.decodeIfPresent(String.self, forKey: .conversationMemory) ?? ""
        currentGoal = try values.decodeIfPresent(String.self, forKey: .currentGoal) ?? ""
        decisions = try values.decodeIfPresent([String].self, forKey: .decisions) ?? []
        unresolvedItems = try values.decodeIfPresent([String].self, forKey: .unresolvedItems) ?? []
        recentEventIDs = try values.decodeIfPresent([UUID].self, forKey: .recentEventIDs) ?? []
        retainedHistoryIDs = try values.decodeIfPresent([UUID].self, forKey: .retainedHistoryIDs) ?? recentEventIDs
        sourceHistoryIDs = try values.decodeIfPresent([UUID].self, forKey: .sourceHistoryIDs) ?? []
        sourceTokenEstimate = try values.decodeIfPresent(Int.self, forKey: .sourceTokenEstimate) ?? triggerTokenCount
        sourceSequenceRange = try values.decodeIfPresent(ClosedRange<Int>.self, forKey: .sourceSequenceRange)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
    }
}

struct HarnessTranscriptEntry: Identifiable, Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case instructions
        case user
        case reasoning
        case assistant
        case toolCall
        case toolResult
        case memory
    }

    let id: UUID
    let kind: Kind
    let content: String
    let createdAt: Date?

    init(id: UUID = UUID(), kind: Kind, content: String, createdAt: Date? = nil) {
        self.id = id
        self.kind = kind
        self.content = content
        self.createdAt = createdAt
    }
}

struct AgentRunCheckpoint: Identifiable, Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int = Self.currentVersion
    let id: UUID
    let runID: UUID
    let sequence: Int
    let resumeKey: UUID
    var transcript: [HarnessTranscriptEntry]
    var plan: AgentPlan?
    var pendingApprovals: [ApprovalRequestRecord]
    var pendingInvocations: [ToolInvocation]
    var completedIdempotencyKeys: [String]
    var artifacts: [AgentArtifact]
    var selectedSkillIDs: [String]
    var compaction: StructuredCompactionState?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        runID: UUID,
        sequence: Int,
        resumeKey: UUID,
        transcript: [HarnessTranscriptEntry] = [],
        plan: AgentPlan? = nil,
        pendingApprovals: [ApprovalRequestRecord] = [],
        pendingInvocations: [ToolInvocation] = [],
        completedIdempotencyKeys: [String] = [],
        artifacts: [AgentArtifact] = [],
        selectedSkillIDs: [String] = [],
        compaction: StructuredCompactionState? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.runID = runID
        self.sequence = sequence
        self.resumeKey = resumeKey
        self.transcript = transcript
        self.plan = plan
        self.pendingApprovals = pendingApprovals
        self.pendingInvocations = pendingInvocations
        self.completedIdempotencyKeys = completedIdempotencyKeys
        self.artifacts = artifacts
        self.selectedSkillIDs = selectedSkillIDs
        self.compaction = compaction
        self.createdAt = createdAt
    }
}

enum AgentRunEventPayload: Codable, Equatable, Sendable {
    case runCreated
    case runRegistered(run: AgentRunRecord, task: AgentTaskRecord)
    case statusChanged(AgentRunStatus)
    case userInput(messageID: UUID, text: String)
    case reasoningDelta(String)
    case responseDelta(String)
    case reasoningMessage(messageID: UUID, text: String)
    case responseMessage(messageID: UUID, text: String)
    case planUpdated(AgentPlan)
    case toolRequested(ToolInvocation)
    case toolStarted(invocationID: UUID)
    case toolCompleted(ToolResultRecord)
    case approvalRequested(ApprovalRequestRecord)
    case approvalResolved(approvalID: UUID, decision: ApprovalDecision)
    case artifactCreated(AgentArtifact)
    case skillSelected(skillID: String)
    case skillsChanged([String])
    case compactionUpdated(StructuredCompactionState)
    case checkpointSaved(checkpointID: UUID)
    case failed(message: String, retryable: Bool)
    case cancelled
    case completed
    case legacyMessage(ChatMessage)
}

struct AgentRunProjection: Equatable, Sendable {
    var status: AgentRunStatus
    var lastSequence: Int
    var pendingInvocations: [ToolInvocation]
    var approvals: [ApprovalRequestRecord]
    var artifacts: [AgentArtifact]
    var selectedSkillIDs: [String]
    var plan: AgentPlan?
    var compaction: StructuredCompactionState?
    var completedIdempotencyKeys: [String]
    var activeCheckpointID: UUID?
}

struct AgentRunEvent: Identifiable, Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = Self.currentSchemaVersion
    let id: UUID
    let runID: UUID
    let sequence: Int
    let timestamp: Date
    let idempotencyKey: String?
    let payload: AgentRunEventPayload

    init(
        id: UUID = UUID(),
        runID: UUID,
        sequence: Int,
        timestamp: Date = .now,
        idempotencyKey: String? = nil,
        payload: AgentRunEventPayload
    ) {
        self.id = id
        self.runID = runID
        self.sequence = sequence
        self.timestamp = timestamp
        self.idempotencyKey = idempotencyKey
        self.payload = payload
    }
}
