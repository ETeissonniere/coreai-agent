import Foundation
import CoreAIAgentRuntime
import Testing
@testable import CoreAIAgent

@MainActor @Test func titleGenerationReplacesImmediateFallbackOnSuccess() async throws {
    let root = temporaryHarnessDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let conversation = Conversation()
    let appStore = JSONAppStateStore(fileURL: root.appending(path: "AppState.json"))
    try appStore.save(PersistedAppState(
        conversations: [conversation], folders: [], openConversationIDs: [conversation.id],
        selectedConversationID: conversation.id
    ))
    let model = AppModel(
        modelService: HarnessModelServiceStub(), appStateStore: appStore,
        harnessStore: JSONHarnessStore(rootURL: root.appending(path: "Harness")),
        titleService: TitleGeneratorStub(result: .generated("Core AI Research")),
        modelResourceURLs: [.deep: root.appending(path: "deep-model")]
    )
    await model.waitForHarnessBootstrap()
    try await waitUntil { model.isSelectedModelReady }
    model.draft = "Research the latest Core AI APIs"
    model.send()

    try await waitUntil { model.conversations[0].title == "Core AI Research" }
    #expect(model.titleGenerationFailuresByConversation[conversation.id] == nil)
}

@MainActor @Test func titleGenerationFailureKeepsImmediateFallbackAndReportsDiagnostic() async throws {
    let root = temporaryHarnessDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let conversation = Conversation()
    let appStore = JSONAppStateStore(fileURL: root.appending(path: "AppState.json"))
    try appStore.save(PersistedAppState(
        conversations: [conversation], folders: [], openConversationIDs: [conversation.id],
        selectedConversationID: conversation.id
    ))
    let model = AppModel(
        modelService: HarnessModelServiceStub(), appStateStore: appStore,
        harnessStore: JSONHarnessStore(rootURL: root.appending(path: "Harness")),
        titleService: TitleGeneratorStub(result: .fallback(.assetMissing)),
        modelResourceURLs: [.deep: root.appending(path: "deep-model")]
    )
    await model.waitForHarnessBootstrap()
    try await waitUntil { model.isSelectedModelReady }
    let prompt = "Research the latest Core AI APIs and explain the agent runtime"
    model.draft = prompt
    model.send()

    let fallbackTitle = String(prompt.prefix(48))
    #expect(model.conversations[0].title == fallbackTitle)
    try await waitUntil { model.titleGenerationFailuresByConversation[conversation.id] == .assetMissing }
    #expect(model.conversations[0].title == fallbackTitle)
}

@MainActor @Test func failedTaskRetryRestoresRequestToComposerAndDismissesRecoveryNotice() async throws {
    let root = temporaryHarnessDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let conversation = Conversation(
        title: "Failed task",
        messages: [
            ChatMessage(role: .user, text: "Research current Apple APIs"),
            ChatMessage(role: .assistant, text: "Generation failed", generationState: .failed),
        ]
    )
    let appStore = JSONAppStateStore(fileURL: root.appending(path: "AppState.json"))
    try appStore.save(PersistedAppState(
        conversations: [conversation], folders: [], openConversationIDs: [conversation.id],
        selectedConversationID: conversation.id
    ))
    let model = AppModel(
        modelService: HarnessModelServiceStub(), appStateStore: appStore,
        harnessStore: JSONHarnessStore(rootURL: root.appending(path: "Harness")),
        modelResourceURLs: [.deep: root.appending(path: "deep-model")]
    )
    await model.waitForHarnessBootstrap()
    try await waitUntil { model.isSelectedModelReady }
    model.runStatusByConversation[conversation.id] = .failed
    model.recoveredConversationIDs.insert(conversation.id)

    model.prepareRetry(in: conversation.id)

    #expect(model.draft == "Research current Apple APIs")
    #expect(!model.recoveredConversationIDs.contains(conversation.id))
    #expect(model.conversations.first?.messages.count == 2)
}

@MainActor @Test func appModelPersistsRunToolAndCheckpointBoundaries() async throws {
    let root = temporaryHarnessDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let appStateURL = root.appending(path: "AppState.json")
    let harnessURL = root.appending(path: "Harness")
    let conversation = Conversation(title: "Durable task")
    let state = PersistedAppState(
        conversations: [conversation],
        folders: [],
        openConversationIDs: [conversation.id],
        selectedConversationID: conversation.id
    )
    let appStore = JSONAppStateStore(fileURL: appStateURL)
    try appStore.save(state)
    let harnessStore = JSONHarnessStore(rootURL: harnessURL)
    let model = AppModel(
        modelService: HarnessModelServiceStub(),
        appStateStore: appStore,
        harnessStore: harnessStore,
        modelResourceURLs: [.deep: root.appending(path: "deep-model")]
    )
    await model.waitForHarnessBootstrap()
    try await waitUntil { model.isSelectedModelReady }
    model.toggleSkill("web-research")
    model.draft = "Research the latest Core AI APIs"
    model.send()

    try await waitUntil { model.modelPhase == .ready && model.conversations[0].messages.count == 2 }
    let index = try await harnessStore.loadIndex()
    let run = try #require(index.runs.max(by: { $0.updatedAt < $1.updatedAt }))
    let events = try await harnessStore.events(for: run.id)
    let checkpoint = try #require(try await harnessStore.latestCheckpoint(for: run.id))

    #expect(run.status == .completed)
    #expect(events.contains { if case .userInput = $0.payload { true } else { false } })
    #expect(events.contains { if case .toolRequested = $0.payload { true } else { false } })
    #expect(events.contains { if case .toolCompleted = $0.payload { true } else { false } })
    #expect(events.contains { if case .completed = $0.payload { true } else { false } })
    #expect(checkpoint.selectedSkillIDs == ["builtin.web-research"])
    #expect(checkpoint.completedIdempotencyKeys.count == 1)
    #expect(checkpoint.compaction?.generation == 2)
    #expect(checkpoint.compaction?.conversationMemory == "authoritative second memory")
    #expect(model.toolActivitiesByConversation[conversation.id]?.first?.state == .succeeded)
    let assistantMessageID = try #require(model.conversations[0].messages.last?.id)
    let trace = try #require(model.executionTraceByMessage[assistantMessageID])
    let toolID = try #require(model.toolActivitiesByConversation[conversation.id]?.first?.id)
    #expect(trace.entries.map(\.content) == [
        .reasoning("I should search for a primary source."),
        .tool(toolID),
        .reasoning("I checked the primary source."),
    ])
    #expect(model.runStatusByConversation[conversation.id] == .completed)
    let rawEventLog = try String(
        contentsOf: harnessURL.appending(path: "events/\(run.id).jsonl"),
        encoding: .utf8
    )
    let checkpointDirectory = harnessURL.appending(path: "checkpoints/\(run.id)")
    let rawCheckpoints = try FileManager.default.contentsOfDirectory(
        at: checkpointDirectory,
        includingPropertiesForKeys: nil
    ).map { try String(contentsOf: $0, encoding: .utf8) }.joined()
    #expect(!rawEventLog.contains("I checked the primary source."))
    #expect(!rawCheckpoints.contains("I checked the primary source."))
    #expect(!checkpoint.transcript.contains { $0.kind == .reasoning })
}

@MainActor @Test func retryAttemptReconcilesPendingToolAndScopesReusedExternalID() async throws {
    let root = temporaryHarnessDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let conversation = Conversation(title: "Retry boundary")
    let appStore = JSONAppStateStore(fileURL: root.appending(path: "AppState.json"))
    try appStore.save(PersistedAppState(
        conversations: [conversation], folders: [], openConversationIDs: [conversation.id],
        selectedConversationID: conversation.id
    ))
    let harnessStore = JSONHarnessStore(rootURL: root.appending(path: "Harness"))
    let model = AppModel(
        modelService: AttemptBoundaryModelServiceStub(), appStateStore: appStore,
        harnessStore: harnessStore,
        modelResourceURLs: [.deep: root.appending(path: "deep-model")]
    )
    await model.waitForHarnessBootstrap()
    try await waitUntil { model.isSelectedModelReady }
    model.draft = "Search twice"
    model.send()

    try await waitUntil { model.modelPhase == .ready && model.conversations[0].messages.count == 2 }
    let activities = try #require(model.toolActivitiesByConversation[conversation.id])
    #expect(activities.count == 2)
    #expect(activities[0].id != activities[1].id)
    #expect(activities[0].state == .failed)
    #expect(activities[1].state == .succeeded)
    #expect(activities[0].result?.content.contains("attempt ended") == true)

    let responseID = try #require(model.conversations[0].messages.last?.id)
    let trace = try #require(model.executionTraceByMessage[responseID])
    #expect(trace.entries.compactMap { entry -> UUID? in
        guard case .tool(let id) = entry.content else { return nil }
        return id
    } == activities.map(\.id))
    let run = try #require(try await harnessStore.loadIndex().runs.max { $0.updatedAt < $1.updatedAt })
    let events = try await harnessStore.events(for: run.id)
    #expect(events.contains { event in
        guard case .toolCompleted(let result) = event.payload else { return false }
        return result.invocationID == activities[0].id && result.isError
    })
}

@MainActor @Test func appModelRestoresSkillsApprovalsArtifactsAndStableRunState() async throws {
    let root = temporaryHarnessDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let appStateURL = root.appending(path: "AppState.json")
    let harnessURL = root.appending(path: "Harness")
    let conversation = Conversation(title: "Restorable task")
    let state = PersistedAppState(
        conversations: [conversation],
        folders: [],
        openConversationIDs: [conversation.id],
        selectedConversationID: conversation.id
    )
    let appStore = JSONAppStateStore(fileURL: appStateURL)
    try appStore.save(state)
    let harnessStore = JSONHarnessStore(rootURL: harnessURL)
    var model: AppModel? = AppModel(
        modelService: HarnessModelServiceStub(),
        appStateStore: appStore,
        harnessStore: harnessStore,
        modelResourceURLs: [.deep: root.appending(path: "deep-model")]
    )
    await model?.waitForHarnessBootstrap()
    model?.toggleSkill("document-authoring")
    let invocationID = UUID()
    let approval = TaskApprovalRequest(
        id: UUID(),
        title: "Export report",
        explanation: "Write the generated report to disk.",
        target: "/tmp/report.md",
        sendsDataOffDevice: false,
        decision: .pending
    )
    await model?.recordApprovalRequest(approval, invocationID: invocationID, in: conversation.id)
    await model?.recordArtifact(
        TaskArtifact(
            id: UUID(),
            title: "Report",
            kind: .document,
            detail: "Draft report",
            fileURL: URL(filePath: "/tmp/report.md")
        ),
        in: conversation.id
    )
    model = nil

    let restored = AppModel(
        modelService: HarnessModelServiceStub(),
        appStateStore: appStore,
        harnessStore: JSONHarnessStore(rootURL: harnessURL),
        modelResourceURLs: [.deep: root.appending(path: "deep-model")]
    )
    await restored.waitForHarnessBootstrap()

    // Skills selected for a prior run remain durable run metadata, not sticky UI pins.
    #expect(restored.enabledSkillIDs.isEmpty)
    #expect(restored.approvalsByConversation[conversation.id]?.first?.id == approval.id)
    #expect(restored.approvalsByConversation[conversation.id]?.first?.decision == .denied)
    #expect(restored.artifactsByConversation[conversation.id]?.first?.title == "Report")
    #expect(restored.runStatusByConversation[conversation.id] == .suspended)
    #expect(restored.recoveryCheckpointByConversation[conversation.id] != nil)

    let verificationStore = JSONHarnessStore(rootURL: harnessURL)
    let interruptedRunID = try #require(try await verificationStore.loadIndex().runs.last?.id)
    restored.decideApproval(approval.id, in: conversation.id, decision: .allowedOnce)
    restored.decideApproval(approval.id, in: conversation.id, decision: .denied)
    #expect(restored.approvalsByConversation[conversation.id]?.first?.decision == .denied)
    try await waitUntil { restored.isSelectedModelReady }
    restored.draft = "Continue in a replacement run"
    restored.send()
    try await waitUntil { restored.modelPhase == .ready && restored.runStatusByConversation[conversation.id] == .completed }
    let replacement = try #require(try await JSONHarnessStore(rootURL: harnessURL).loadIndex().runs.last)
    #expect(replacement.id != interruptedRunID)
    #expect(replacement.parentRunID == interruptedRunID)
}

@MainActor @Test func userSavePersistsMarkdownArtifactAndDurableDestination() async throws {
    let root = temporaryHarnessDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let appStore = JSONAppStateStore(fileURL: root.appending(path: "AppState.json"))
    let harnessStore = JSONHarnessStore(rootURL: root.appending(path: "Harness"))
    let conversation = Conversation(title: "Document task")
    try appStore.save(PersistedAppState(
        conversations: [conversation], folders: [], openConversationIDs: [conversation.id],
        selectedConversationID: conversation.id
    ))
    let model = AppModel(
        modelService: HarnessModelServiceStub(), appStateStore: appStore, harnessStore: harnessStore
    )
    await model.waitForHarnessBootstrap()
    let artifact = TaskArtifact(
        id: UUID(), title: "Report", kind: .document, detail: "text/markdown",
        content: "# Report\n\nEvidence.", fileURL: nil
    )
    await model.recordArtifact(artifact, in: conversation.id)
    let destination = root.appending(path: "Report.md")

    try await model.saveMarkdownArtifact(artifact.id, in: conversation.id, to: destination)

    #expect(try String(contentsOf: destination, encoding: .utf8) == artifact.content)
    #expect(model.artifactsByConversation[conversation.id]?.first?.fileURL == destination)
    let index = try await harnessStore.loadIndex()
    let run = try #require(index.runs.max(by: { $0.updatedAt < $1.updatedAt }))
    let checkpoint = try #require(try await harnessStore.latestCheckpoint(for: run.id))
    #expect(checkpoint.artifacts.first?.path == destination.path)
    await #expect(throws: ArtifactSaveError.markdownDestinationRequired) {
        try await model.saveMarkdownArtifact(artifact.id, in: conversation.id, to: root.appending(path: "Report.txt"))
    }
}

@MainActor @Test func brokerApprovalMapsHashedKeyToPendingSearchAndGatesResolution() async throws {
    let root = temporaryHarnessDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let conversation = Conversation(title: "Approval mapping")
    let appStore = JSONAppStateStore(fileURL: root.appending(path: "AppState.json"))
    try appStore.save(PersistedAppState(
        conversations: [conversation], folders: [],
        openConversationIDs: [conversation.id], selectedConversationID: conversation.id
    ))
    let harness = JSONHarnessStore(rootURL: root.appending(path: "Harness"))
    let service = ApprovalBrokerModelServiceStub()
    let model = AppModel(
        modelService: service,
        appStateStore: appStore,
        harnessStore: harness,
        modelResourceURLs: [.deep: root.appending(path: "deep-model")]
    )
    await model.waitForHarnessBootstrap()
    try await waitUntil(timeout: .seconds(15)) { model.isSelectedModelReady }
    model.toggleSkill("builtin.web-research")
    model.draft = "Search for current Core AI documentation"
    model.send()

    try await waitUntil(timeout: .seconds(15)) {
        model.approvalsByConversation[conversation.id]?.first?.decision == .pending
            && model.runStatusByConversation[conversation.id] == .awaitingApproval
    }
    let approval = try #require(model.approvalsByConversation[conversation.id]?.first)
    #expect(model.runStatusByConversation[conversation.id] == .awaitingApproval)
    let harnessIndex = try await harness.loadIndex()
    let runID = try #require(harnessIndex.runs.last?.id)
    let projection = try await harness.projection(for: runID)
    let durableApproval = try #require(projection.approvals.first)
    let targetInvocation = try #require(projection.pendingInvocations.first {
        $0.argumentsJSON.contains("Core AI")
    })
    let distractorInvocation = try #require(projection.pendingInvocations.first {
        $0.argumentsJSON.contains("Swift")
    })

    #expect(durableApproval.id == approval.id)
    #expect(durableApproval.invocationID == targetInvocation.id)
    #expect(durableApproval.invocationID != distractorInvocation.id)
    #expect(await service.resolvedApprovalID == nil)

    model.decideApproval(approval.id, in: conversation.id, decision: .allowedOnce)
    try await waitUntil(timeout: .seconds(15)) {
        model.modelPhase == .ready && model.runStatusByConversation[conversation.id] == .completed
    }

    #expect(await service.resolvedApprovalID == approval.id)
    #expect(await service.resolvedApproved == true)
    #expect(model.toolActivitiesByConversation[conversation.id]?.first?.state == .succeeded)
}

@MainActor @Test func durableMessageTimestampAndOrderOverrideStaleAppStateProjection() async throws {
    let root = temporaryHarnessDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let conversationID = UUID()
    let messageID = UUID()
    let originalDate = Date(timeIntervalSince1970: 1_600_000_000)
    let staleDate = Date(timeIntervalSince1970: 1_700_000_000)
    let staleConversation = Conversation(
        id: conversationID,
        title: "Stale projection",
        messages: [ChatMessage(id: messageID, role: .user, text: "stale text", createdAt: staleDate)]
    )
    let appStore = JSONAppStateStore(fileURL: root.appending(path: "AppState.json"))
    try appStore.save(PersistedAppState(
        conversations: [staleConversation], folders: [],
        openConversationIDs: [conversationID], selectedConversationID: conversationID
    ))
    let harnessURL = root.appending(path: "Harness")
    let harness = JSONHarnessStore(rootURL: harnessURL)
    let task = AgentTaskRecord(legacyConversationID: conversationID, title: "Durable projection")
    try await harness.createTask(task)
    let run = AgentRunRecord(taskID: task.id)
    try await harness.createRun(run)
    try await harness.append(
        .userInput(messageID: messageID, text: "durable text"),
        to: run.id,
        timestamp: originalDate
    )
    try await harness.append(.completed, to: run.id, timestamp: originalDate.addingTimeInterval(1))

    let model = AppModel(modelService: HarnessModelServiceStub(), appStateStore: appStore, harnessStore: harness)
    await model.waitForHarnessBootstrap()
    let restored = try #require(model.conversations.first(where: { $0.id == conversationID })?.messages.first)

    #expect(restored.id == messageID)
    #expect(restored.text == "durable text")
    #expect(restored.createdAt == originalDate)
}

private final class HarnessModelServiceStub: ModelServing, @unchecked Sendable {
    func load(resourcesAt url: URL, for profile: ModelProfile) async throws {}

    func generate(request: ModelGenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.context(ContextStatus(
                usedTokens: 3_500, activeBudget: 3_000, state: .compacting,
                compactionCount: 1, modelLimit: 4_096, outputReserve: 768
            )))
            continuation.yield(.compaction(ModelCompactionSnapshot(
                generation: 1, memory: "first memory", retainedHistoryIDs: [],
                sourceHistoryIDs: [UUID()], sourceTokenEstimate: 3_500
            )))
            continuation.yield(.context(ContextStatus(
                usedTokens: 1_000, activeBudget: 3_000, state: .normal,
                compactionCount: 1, modelLimit: 4_096, outputReserve: 768,
                conversationMemory: "degraded telemetry memory"
            )))
            continuation.yield(.context(ContextStatus(
                usedTokens: 3_600, activeBudget: 3_000, state: .compacting,
                compactionCount: 2, modelLimit: 4_096, outputReserve: 768
            )))
            continuation.yield(.compaction(ModelCompactionSnapshot(
                generation: 2, memory: "authoritative second memory", retainedHistoryIDs: [],
                sourceHistoryIDs: [UUID()], sourceTokenEstimate: 3_600
            )))
            continuation.yield(.context(ContextStatus(
                usedTokens: 1_100, activeBudget: 3_000, state: .normal,
                compactionCount: 2, modelLimit: 4_096, outputReserve: 768,
                conversationMemory: "stale context memory"
            )))
            continuation.yield(.agent(.reasoning("I should search for a primary source.")))
            continuation.yield(.content(GenerationUpdate(
                text: "",
                reasoning: "I should search for a primary source.",
                metrics: GenerationMetrics(
                    generatedTokens: 1, reasoningTokens: 1,
                    timeToFirstToken: .milliseconds(5), elapsed: .milliseconds(10),
                    prefillTokensPerSecond: 2_000, decodeTokensPerSecond: 0,
                    initialPrefill: .milliseconds(8), toolCallGeneration: .zero,
                    toolExecution: .zero, continuationPrefill: .zero, decode: .zero
                ),
                kvCache: KVCacheSnapshot(
                    usedTokens: 11, allocatedTokens: 32, maximumTokens: 4_096, reusedPrefixTokens: 0
                )
            )))
            continuation.yield(.agent(.toolCall(
                id: "call-1",
                name: "web.search",
                argumentsJSON: #"{"query":"Core AI"}"#
            )))
            continuation.yield(.agent(.toolOutput(
                id: "call-1",
                name: "web.search",
                content: "https://developer.apple.com/documentation/foundationmodels"
            )))
            continuation.yield(.agent(.reasoning("I checked the primary source.")))
            continuation.yield(.content(GenerationUpdate(
                text: "Finished.",
                reasoning: "I should search for a primary source.\n\nI checked the primary source.",
                metrics: GenerationMetrics(
                    generatedTokens: 2,
                    reasoningTokens: 4,
                    timeToFirstToken: .milliseconds(10),
                    elapsed: .milliseconds(20),
                    prefillTokensPerSecond: 1_000,
                    decodeTokensPerSecond: 100,
                    initialPrefill: .milliseconds(8), toolCallGeneration: .milliseconds(2),
                    toolExecution: .milliseconds(4), continuationPrefill: .milliseconds(3),
                    decode: .milliseconds(2)
                ),
                kvCache: KVCacheSnapshot(
                    usedTokens: 12,
                    allocatedTokens: 32,
                    maximumTokens: 4_096,
                    reusedPrefixTokens: 0
                )
            )))
            continuation.finish()
        }
    }

    func cancel() async {}
    func resolveApproval(id: UUID, approved: Bool) async -> Bool { true }
}

private final class AttemptBoundaryModelServiceStub: ModelServing, @unchecked Sendable {
    func load(resourcesAt url: URL, for profile: ModelProfile) async throws {}

    func generate(request: ModelGenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.attemptStarted(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!))
            continuation.yield(.agent(.toolCall(
                id: "reused-call", name: "searchWeb", argumentsJSON: #"{"query":"first"}"#
            )))
            continuation.yield(.attemptStarted(UUID(uuidString: "00000000-0000-0000-0000-000000000002")!))
            continuation.yield(.agent(.toolCall(
                id: "reused-call", name: "searchWeb", argumentsJSON: #"{"query":"retry"}"#
            )))
            continuation.yield(.agent(.toolOutput(
                id: "reused-call", name: "searchWeb", content: "Retry result"
            )))
            continuation.yield(.content(GenerationUpdate(
                text: "Finished.", reasoning: nil,
                metrics: GenerationMetrics(
                    generatedTokens: 1, reasoningTokens: 0,
                    timeToFirstToken: .milliseconds(1), elapsed: .milliseconds(2),
                    prefillTokensPerSecond: 4_000, decodeTokensPerSecond: 0,
                    initialPrefill: .milliseconds(1), toolCallGeneration: .zero,
                    toolExecution: .zero, continuationPrefill: .zero, decode: .zero
                ),
                kvCache: KVCacheSnapshot(
                    usedTokens: 5, allocatedTokens: 32, maximumTokens: 4_096, reusedPrefixTokens: 0
                )
            )))
            continuation.finish()
        }
    }

    func cancel() async {}
    func resolveApproval(id: UUID, approved: Bool) async -> Bool { false }
}

private struct TitleGeneratorStub: TitleGenerating {
    let result: TitleGenerationResult

    func generateTitle(for firstMessage: String) async -> TitleGenerationResult {
        result
    }
}

private actor ApprovalBrokerModelServiceStub: ModelServing {
    private var continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation?
    private(set) var resolvedApprovalID: UUID?
    private(set) var resolvedApproved: Bool?
    private let approvalID = UUID()

    func load(resourcesAt url: URL, for profile: ModelProfile) async throws {}

    nonisolated func generate(request: ModelGenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { await self.begin(continuation) }
        }
    }

    private func begin(_ continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation) {
        self.continuation = continuation
        continuation.yield(.attemptStarted(
            UUID(uuidString: "00000000-0000-0000-0000-000000000017")!
        ))
        continuation.yield(.agent(.toolCall(
            id: "foundation-call-17", name: "searchWeb", argumentsJSON: #"{"query":"Core AI"}"#
        )))
        continuation.yield(.agent(.toolCall(
            id: "foundation-call-18", name: "searchWeb", argumentsJSON: #"{"query":"Swift"}"#
        )))
        // The approval for the first call deliberately arrives after the second call.
        continuation.yield(.agent(.approvalRequested(AgentApprovalRequest(
            id: approvalID,
            invocationID: "sha256:stable-broker-key-not-foundation-call-17",
            toolCallID: "foundation-call-17",
            idempotencyKey: "sha256:stable-broker-key-not-foundation-call-17",
            title: "Search the web",
            detail: "Send the query to the configured search provider.",
            target: "duckduckgo.com"
        ))))
    }

    func resolveApproval(id: UUID, approved: Bool) async -> Bool {
        guard id == approvalID, let continuation else { return false }
        resolvedApprovalID = id
        resolvedApproved = approved
        if approved {
            continuation.yield(.agent(.toolOutput(
                id: "foundation-call-17", name: "searchWeb", content: "Approved search result"
            )))
            continuation.yield(.agent(.toolOutput(
                id: "foundation-call-18", name: "searchWeb", content: "Second search result"
            )))
            continuation.yield(.content(GenerationUpdate(
                text: "Search complete.", reasoning: nil,
                metrics: GenerationMetrics(
                    generatedTokens: 2, reasoningTokens: 0,
                    timeToFirstToken: .milliseconds(1), elapsed: .milliseconds(2),
                    prefillTokensPerSecond: 8_000, decodeTokensPerSecond: 1_000,
                    initialPrefill: .milliseconds(1), toolCallGeneration: .zero,
                    toolExecution: .zero, continuationPrefill: .zero,
                    decode: .milliseconds(1)
                ),
                kvCache: KVCacheSnapshot(
                    usedTokens: 10, allocatedTokens: 32, maximumTokens: 4_096, reusedPrefixTokens: 0
                )
            )))
            continuation.finish()
        } else {
            continuation.finish(throwing: CancellationError())
        }
        self.continuation = nil
        return true
    }

    func cancel() async { continuation?.finish(throwing: CancellationError()) }
}

@MainActor
private func waitUntil(
    timeout: Duration = .seconds(5),
    condition: @escaping @MainActor () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        guard clock.now < deadline else { throw HarnessIntegrationTestError.timedOut }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private enum HarnessIntegrationTestError: Error {
    case timedOut
}

private func temporaryHarnessDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "CoreAIAgent-AppModelHarnessTests-\(UUID())", directoryHint: .isDirectory)
}
