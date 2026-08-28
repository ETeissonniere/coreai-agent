import Foundation
import Testing

@Test func fourKContextReservesEnoughRoomForReasoningToolCallAndAnswer() {
    #expect(CoreAIModelService.responseTokenReserve(for: 4_096) == 1_536)
}

@Test func malformedStructuredGenerationErrorsAreRetryable() {
    let error = NSError(
        domain: "FoundationModels.GenerationError",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Failed to parse generated content."]
    )
    #expect(CoreAIModelService.isMalformedGeneratedContentError(error))
}

@Test func malformedToolRetryPreservesTheActualUserRequest() {
    let prompt = "Can you analyze the relevance of the 2026 Mac Ultra release for local AI?"
    let retry = CoreAIModelService.malformedToolRetryPrompt(for: prompt)

    #expect(retry.hasPrefix(prompt))
    #expect(retry.contains("emit one complete call"))
    #expect(retry.hasSuffix("/no_think"))
    #expect(!retry.contains("(request.prompt)"))
}
@testable import QwenCoreAI

@Test func conversationStartsEmpty() {
    let conversation = Conversation()
    #expect(conversation.title == "New Chat")
    #expect(conversation.messages.isEmpty)
}

@Test func generationMetricsSeparatePrefillAndDecode() {
    let metrics = GenerationMetrics(
        promptTokens: 100,
        cachedTokens: 20,
        generatedTokens: 40,
        reasoningTokens: 8,
        timeToFirstToken: .seconds(2),
        elapsed: .seconds(6)
    )
    #expect(metrics.prefillTokensPerSecond == 40)
    #expect(metrics.tokensPerSecond == 10)
    #expect(metrics.contextTokens == 140)
}

@Test func stoppedMessageRoundTripsThroughJSON() throws {
    let message = ChatMessage(
        role: .assistant,
        text: "**Partial** answer",
        reasoning: "Checking the premise",
        wasStopped: true
    )
    let data = try JSONEncoder().encode(message)
    #expect(try JSONDecoder().decode(ChatMessage.self, from: data) == message)
}

@Test func conversationCanBelongToFolder() {
    let folder = ConversationFolder(name: "Research")
    let conversation = Conversation(title: "Core AI", folderID: folder.id)
    #expect(conversation.folderID == folder.id)
}

@Test func contextPolicyReservesGenerationCapacity() {
    let status = ContextStatus(
        usedTokens: 2_496,
        activeBudget: 3_072,
        state: .elevated,
        compactionCount: 1,
        modelLimit: 4_096,
        outputReserve: 768
    )
    #expect(status.inputLimit == 3_328)
    #expect(status.utilization == 0.75)
}

@Test func pinnedConversationRoundTripsThroughJSON() throws {
    let conversation = Conversation(title: "Pinned chat", isPinned: true)
    let data = try JSONEncoder().encode(conversation)
    #expect(try JSONDecoder().decode(Conversation.self, from: data).isPinned)
}

@Test func kvCacheSnapshotReportsAllocationAndCapacityUsage() {
    let snapshot = KVCacheSnapshot(
        usedTokens: 1_024,
        allocatedTokens: 2_048,
        maximumTokens: 4_096,
        reusedPrefixTokens: 768
    )

    #expect(snapshot.allocationUtilization == 0.5)
    #expect(snapshot.maximumUtilization == 0.25)
}

@Test func contextCompositionKeepsRuntimeTotalsExactAndMarksSemanticAllocationEstimated() {
    let userID = UUID()
    let assistantID = UUID()
    let request = ModelGenerationRequest(
        conversationID: UUID(),
        prompt: "<user_request>Explain KV caching</user_request>",
        enabledSkillIDs: [],
        history: [
            ModelHistoryItem(id: UUID(), kind: .assistant, content: "Earlier answer"),
            ModelHistoryItem(
                id: UUID(), kind: .toolBundle,
                content: "Tool: searchWeb\nArguments: cache\nResult: source"
            ),
        ],
        compaction: nil,
        userMessageID: userID,
        assistantMessageID: assistantID,
        promptComponents: [
            .init(id: userID, category: .user, text: "Explain KV caching"),
            .init(category: .attachments, text: "attached notes"),
        ]
    )

    let composition = CoreAIModelService.contextComposition(
        request: request,
        memory: "Prior preference",
        inputTokens: 900,
        generatedTokens: 100,
        reasoningTokens: 30,
        outputReserve: 1_536
    )

    #expect(composition.inputTokens == 900)
    #expect(composition.generatedTokens == 100)
    #expect(composition.usedTokens == 1_000)
    #expect(composition.remainingTokens == 1_436)
    #expect(composition.slices.filter { $0.basis == .proportionalEstimate }.reduce(0) { $0 + $1.tokens } == 900)
    #expect(composition.tokens(for: .reasoning) == 30)
    #expect(composition.tokens(for: .unclassified) == 70)
    #expect(composition.tokens(for: .toolCalls) > 0)
    #expect(composition.tokens(for: .toolResults) > 0)
    #expect(composition.turns.contains { $0.id == userID })
    #expect(composition.turns.first(where: { $0.id == userID })?.tokens ?? 0 > 0)
}

@Test func persistedMessageRetainsContextAndKVTelemetry() throws {
    let composition = ContextTokenComposition(
        inputTokens: 12,
        generatedTokens: 3,
        outputReserve: 8,
        slices: [.init(
            id: "user-turn",
            turnID: UUID(),
            category: .user,
            tokens: 12,
            basis: .proportionalEstimate
        )]
    )
    let context = ContextStatus(
        usedTokens: 15,
        activeBudget: 512,
        state: .normal,
        compactionCount: 0,
        modelLimit: 4_096,
        outputReserve: 8,
        composition: composition
    )
    let cache = KVCacheSnapshot(
        usedTokens: 15,
        allocatedTokens: 256,
        maximumTokens: 4_096,
        reusedPrefixTokens: 12
    )
    let message = ChatMessage(
        role: .assistant,
        text: "Answer",
        contextSnapshot: context,
        kvCacheSnapshot: cache
    )

    let restored = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(message))
    #expect(restored.contextSnapshot == context)
    #expect(restored.kvCacheSnapshot == cache)
}

@Test func contextCompositionIncludesOnlyHistoryRetainedAfterCompaction() {
    let compactedID = UUID()
    let retainedID = UUID()
    let request = ModelGenerationRequest(
        conversationID: UUID(),
        prompt: "next",
        enabledSkillIDs: [],
        history: [
            .init(id: compactedID, kind: .user, content: "old raw turn"),
            .init(id: retainedID, kind: .assistant, content: "recent retained turn"),
        ],
        compaction: nil
    )
    let composition = CoreAIModelService.contextComposition(
        request: request,
        activeHistory: [.init(id: retainedID, kind: .assistant, content: "recent retained turn")],
        memory: "summary of old turn",
        inputTokens: 100,
        generatedTokens: 0,
        outputReserve: 50
    )

    #expect(!composition.slices.contains { $0.turnID == compactedID })
    #expect(composition.slices.contains { $0.turnID == retainedID })
    #expect(composition.tokens(for: .systemAndMemory) > 0)
}

@Test func futureConversationContextExcludesTransientToolActivity() {
    let user = ModelHistoryItem(id: UUID(), kind: .user, content: "User: Find the current release")
    let tool = ModelHistoryItem(
        id: UUID(),
        kind: .toolBundle,
        content: "Tool: searchWeb\nArguments: secret query\nResult: large transient payload"
    )
    let assistant = ModelHistoryItem(id: UUID(), kind: .assistant, content: "Assistant: Here is the answer")

    let retained = [user, tool, assistant].retainedConversationContext

    #expect(retained == [user, assistant])
    #expect(!retained.map(\.content).joined().contains("transient payload"))
}

@Test func reasoningMarkerIsSeparatedFromVisibleAnswer() {
    let separated = CoreAIModelService.separateReasoning(
        from: "Check the premise.\n</think>\n# Answer\n\nFirst line.\nSecond line.",
        transcriptReasoning: nil
    )

    #expect(separated.reasoning == "Check the premise.")
    #expect(separated.response == "# Answer\n\nFirst line.\nSecond line.")
    #expect(!separated.response.contains("</think>"))
}

@Test func modelCompactionSnapshotRoundTripsCumulativeMemoryAndSources() throws {
    let retained = UUID()
    let source = UUID()
    let snapshot = ModelCompactionSnapshot(
        generation: 3,
        memory: "The user chose local-only execution.",
        retainedHistoryIDs: [retained],
        sourceHistoryIDs: [source],
        sourceTokenEstimate: 12_345
    )

    let restored = try JSONDecoder().decode(
        ModelCompactionSnapshot.self,
        from: JSONEncoder().encode(snapshot)
    )
    #expect(restored == snapshot)
}

@MainActor @Test func markdownRenderingPreservesBlockStructure() {
    let source = "# Heading\n\nFirst line\nSecond line\n\n- Item one\n  - Nested item\n\n2. Numbered"
    #expect(
        MarkdownProseView.parse(source) == [
            .heading(1, "Heading"),
            .paragraph(["First line", "Second line"]),
            .bullet(0, "Item one"),
            .bullet(1, "Nested item"),
            .numbered(0, 2, "Numbered"),
        ]
    )
}

@Test func titleModelOutputIsReducedToAPlainShortTitle() {
    #expect(TitleModelService.clean("<think>hidden</think>\n**KV Cache Planning**") == "KV Cache Planning")
    #expect(TitleModelService.clean("   ") == nil)
}

@Test func appStateRoundTripsAndRepairsInterruptedGeneration() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let store = JSONAppStateStore(fileURL: directory.appending(path: "state.json"))
    let folder = ConversationFolder(name: "Saved")
    let conversation = Conversation(
        title: "Persistent chat",
        messages: [ChatMessage(role: .assistant, text: "Partial", generationState: .streaming)],
        folderID: folder.id,
        isPinned: true
    )
    let state = PersistedAppState(
        conversations: [conversation],
        folders: [folder],
        openConversationIDs: [conversation.id],
        selectedConversationID: conversation.id
    )

    try store.save(state)
    let loaded = try store.load()
    let restored = try #require(loaded)

    #expect(restored.conversations.first?.title == "Persistent chat")
    #expect(restored.conversations.first?.isPinned == true)
    #expect(restored.conversations.first?.messages.first?.generationState == .stopped)
    #expect(restored.selectedConversationID == conversation.id)
    #expect(restored.openConversationIDs == [conversation.id])
}

@Test func appStateNeverPersistsPrivateReasoningText() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appending(path: "state.json")
    let store = JSONAppStateStore(fileURL: fileURL)
    let conversation = Conversation(messages: [
        ChatMessage(role: .assistant, text: "Visible answer", reasoning: "Private trace")
    ])

    try store.save(PersistedAppState(
        conversations: [conversation],
        folders: [],
        openConversationIDs: [conversation.id],
        selectedConversationID: conversation.id
    ))

    #expect(!String(decoding: try Data(contentsOf: fileURL), as: UTF8.self).contains("Private trace"))
    #expect(try store.load()?.conversations[0].messages[0].reasoning == nil)
}

@Test func appStateDropsDanglingFolderAndTabReferences() {
    let missingFolderID = UUID()
    let conversation = Conversation(folderID: missingFolderID)
    let state = PersistedAppState(
        conversations: [conversation],
        folders: [],
        openConversationIDs: [UUID()],
        selectedConversationID: UUID()
    ).restored()

    #expect(state.conversations.first?.folderID == nil)
    #expect(state.openConversationIDs == [conversation.id])
    #expect(state.selectedConversationID == conversation.id)
}
