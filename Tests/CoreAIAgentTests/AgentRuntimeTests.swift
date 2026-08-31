import Foundation
import FoundationModels
import CoreAIAgentRuntime
import Testing

@Test func toolIdentityScopesReusedOpaqueIDsByGenerationAttempt() {
    let first = ToolIdentity.uuid(forOpaqueID: "call-1", scope: "attempt-a")
    let retry = ToolIdentity.uuid(forOpaqueID: "call-1", scope: "attempt-b")

    #expect(first != retry)
    #expect(first == ToolIdentity.uuid(forOpaqueID: "call-1", scope: "attempt-a"))
}

@Test func deterministicToolCountsExtendedGraphemeClusters() async throws {
    let tool = CharacterCountTool()
    let output = try await tool.call(arguments: CharacterCountArguments(text: "A👨‍👩‍👧‍👦é"))
    #expect(output == "Character count: 3")
}

@Test func deterministicToolRejectsOversizedInput() async {
    let tool = CharacterCountTool(maximumCharacters: 3)

    await #expect(throws: CharacterCountToolError.inputTooLarge(maximumCharacters: 3)) {
        try await tool.call(arguments: CharacterCountArguments(text: "four"))
    }
}

@Test func deterministicToolHonorsCancellationBeforeSideEffects() async {
    let tool = CharacterCountTool()
    let task = Task {
        try await tool.call(arguments: CharacterCountArguments(text: "cancel me"))
    }
    task.cancel()

    await #expect(throws: CancellationError.self) {
        try await task.value
    }
}

@Test func malformedToolArgumentsFailGuidedDecodingBoundary() throws {
    let malformed = try GeneratedContent(json: #"{"unexpected":"value"}"#)
    #expect(throws: (any Error).self) {
        try CharacterCountArguments(malformed)
    }
}

@Test func transcriptMapperPreservesAgentEventSequence() throws {
    let arguments = try GeneratedContent(json: #"{"text":"abc"}"#)
    let call = Transcript.ToolCall(id: "call-1", toolName: "countCharacters", arguments: arguments)
    let entries: [Transcript.Entry] = [
        .reasoning(.init(segments: [.text(.init(content: "I should count exactly."))])),
        .toolCalls(.init([call])),
        .toolOutput(.init(
            id: "call-1",
            toolName: "countCharacters",
            segments: [.text(.init(content: "Character count: 3"))]
        )),
        .response(.init(segments: [.text(.init(content: "The answer is 3."))])),
    ]

    #expect(TranscriptEventMapper.events(from: entries) == [
        .reasoning("I should count exactly."),
        .toolCall(
            id: "call-1",
            name: "countCharacters",
            argumentsJSON: arguments.jsonString
        ),
        .toolOutput(id: "call-1", name: "countCharacters", content: "Character count: 3"),
        .response("The answer is 3."),
    ])
}

@Test func transcriptCanRehydrateAgentEventsWithoutLosingToolPairs() throws {
    let arguments = try GeneratedContent(json: #"{"text":"abc"}"#)
    let transcript = Transcript([
        .toolCalls(.init([
            Transcript.ToolCall(id: "call-1", toolName: "countCharacters", arguments: arguments)
        ])),
        .toolOutput(.init(
            id: "call-1",
            toolName: "countCharacters",
            segments: [.text(.init(content: "Character count: 3"))]
        )),
    ])

    let restored = try JSONDecoder().decode(
        Transcript.self,
        from: JSONEncoder().encode(transcript)
    )

    #expect(
        TranscriptEventMapper.events(from: restored)
            == TranscriptEventMapper.events(from: transcript)
    )
}

@Test func webSearchIsBoundedAndKeepsSourceProvenance() async throws {
    let provider = StubSearchProvider(sources: (1...10).map {
        WebSource(title: "Result \($0)", url: URL(string: "https://example.com/\($0)")!, snippet: "Evidence \($0)")
    })
    let output = try await WebSearchTool(provider: provider).call(
        arguments: WebSearchArguments(query: "Core AI")
    )

    #expect(output.contains("https://example.com/1"))
    #expect(output.contains("https://example.com/3"))
    #expect(output.contains("https://example.com/5"))
    #expect(!output.contains("https://example.com/6"))
    #expect(await provider.lastLimit == 5)
}

@Test func webSearchRejectsPrivateSourceURLs() async {
    let provider = StubSearchProvider(sources: [
        WebSource(title: "Unsafe", url: URL(string: "https://127.0.0.1/private")!, snippet: "No")
    ])
    await #expect(throws: WebToolError.disallowedHost) {
        try await WebSearchTool(provider: provider).call(
            arguments: WebSearchArguments(query: "unsafe")
        )
    }
}

@Test func webSearchReturnsStructuredStatusWhenProviderHasNoResults() async throws {
    let output = try await WebSearchTool(provider: StubSearchProvider(sources: [])).call(
        arguments: WebSearchArguments(query: "narrow query")
    )

    #expect(output.contains("<web_search_status>"))
    #expect(output.contains("No results were returned"))
    #expect(!output.isEmpty)
}

@Test func webSearchRetriesTransientFailureAndReturnsSources() async throws {
    let provider = RecoveringSearchProvider(failuresBeforeSuccess: 2)
    let output = try await WebSearchTool(
        provider: provider,
        retryDelays: [.zero, .zero]
    ).call(arguments: WebSearchArguments(query: "retry me"))

    #expect(output.contains("https://example.com/recovered"))
    #expect(await provider.callCount == 3)
}

@Test func webSearchReportsExhaustedAvailabilityFailureToModel() async throws {
    let provider = RecoveringSearchProvider(failuresBeforeSuccess: .max)
    let output = try await WebSearchTool(
        provider: provider,
        retryDelays: [.zero, .zero]
    ).call(arguments: WebSearchArguments(query: "unavailable service"))

    #expect(output.contains("<web_search_status outcome=\"temporarily_unavailable\" attempts=\"3\">"))
    #expect(output.contains("Web search is temporarily unavailable"))
    #expect(output.contains("current information could not be verified"))
    #expect(await provider.callCount == 3)
}

@Test func webSearchDoesNotRetryPolicyFailure() async {
    let provider = FailingSearchProvider(error: .disallowedHost)
    let tool = WebSearchTool(provider: provider, retryDelays: [.zero, .zero])

    await #expect(throws: WebToolError.disallowedHost) {
        try await tool.call(arguments: WebSearchArguments(query: "unsafe"))
    }
    #expect(await provider.callCount == 1)
}

@Test func webSearchCancellationStopsRetryBackoff() async throws {
    let provider = RecoveringSearchProvider(failuresBeforeSuccess: .max)
    let tool = WebSearchTool(provider: provider, retryDelays: [.seconds(30), .seconds(30)])
    let task = Task { try await tool.call(arguments: WebSearchArguments(query: "cancel retries")) }

    while await provider.callCount == 0 { await Task.yield() }
    task.cancel()

    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await provider.callCount == 1)
}

@Test func webSearchReportsExhaustedTurnBudgetWithoutCallingProvider() async throws {
    let provider = CountingSearchProvider()
    let budget = ToolCallBudget(maximumCalls: 1)
    let tool = WebSearchTool(provider: provider, budget: budget, retryDelays: [])
    _ = try await tool.call(arguments: WebSearchArguments(query: "first"))

    let output = try await tool.call(arguments: WebSearchArguments(query: "second"))

    #expect(output.contains("per-turn limit of 1 web searches was reached"))
    #expect(await provider.callCount == 1)
}

@Test func fixedSearchProviderUsesOnlyPinnedOriginAndBoundedResponse() async throws {
    let payload = #"{"AbstractText":"A concise answer","AbstractURL":"https://example.com/source","Heading":"Topic","RelatedTopics":[]}"#
    let fetcher = RecordingWebFetcher(response: WebFetchResponse(
        finalURL: URL(string: "https://api.duckduckgo.com/")!,
        mimeType: "application/json",
        data: Data(payload.utf8)
    ))
    let results = try await DuckDuckGoSearchProvider(fetcher: fetcher).search(query: "swift", maximumResults: 3)

    #expect(results.count == 1)
    #expect(results[0].url.absoluteString == "https://example.com/source")
    #expect(await fetcher.requestedURL?.host == "api.duckduckgo.com")
    #expect(await fetcher.maximumBytes == 128_000)
    #expect(await fetcher.allowedMIMETypes.contains("application/x-javascript"))
}

@Test func fixedSearchProviderIncludesDirectResults() async throws {
    let payload = #"{"AbstractText":"","Heading":"","Results":[{"Text":"Direct result","FirstURL":"https://example.com/direct"}],"RelatedTopics":[]}"#
    let fetcher = RecordingWebFetcher(response: WebFetchResponse(
        finalURL: URL(string: "https://api.duckduckgo.com/")!,
        mimeType: "application/x-javascript",
        data: Data(payload.utf8)
    ))

    let results = try await DuckDuckGoSearchProvider(fetcher: fetcher).search(
        query: "direct",
        maximumResults: 3
    )

    #expect(results.map(\.title) == ["Direct result"])
    #expect(results.map(\.url.absoluteString) == ["https://example.com/direct"])
}

@Test func fixedSearchProviderFallsBackToBoundedHTMLResultsForEmptyInstantAnswer() async throws {
    let instantAnswer = #"{"AbstractText":"","AbstractURL":"","Heading":"","Results":[],"RelatedTopics":[]}"#
    let html = #"<a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fdeveloper.apple.com%2Fcore-ml">Apple &amp; Core ML</a>"#
    let fetcher = SequenceWebFetcher(responses: [
        WebFetchResponse(finalURL: URL(string: "https://api.duckduckgo.com/")!, mimeType: "application/json", data: Data(instantAnswer.utf8)),
        WebFetchResponse(finalURL: URL(string: "https://html.duckduckgo.com/html/")!, mimeType: "text/html", data: Data(html.utf8)),
    ])

    let results = try await DuckDuckGoSearchProvider(fetcher: fetcher).search(
        query: "recent Apple Core AI", maximumResults: 3
    )

    #expect(results.map(\.title) == ["Apple & Core ML"])
    #expect(results.map(\.url.absoluteString) == ["https://developer.apple.com/core-ml"])
    #expect(await fetcher.requestedHosts == ["api.duckduckgo.com", "html.duckduckgo.com"])
}

@Test func toolCallBudgetResetsForEachConversationTurn() async throws {
    let budget = ToolCallBudget(maximumCalls: 1)
    try await budget.consume()
    await #expect(throws: WebToolError.toolCallLimitExceeded(1)) { try await budget.consume() }

    await budget.beginTurn()

    try await budget.consume()
}

@Test func fixedSearchProviderRejectsRedirectAwayFromPinnedOrigin() async {
    let fetcher = RecordingWebFetcher(response: WebFetchResponse(
        finalURL: URL(string: "https://evil.example/search")!,
        mimeType: "application/json",
        data: Data(#"{"AbstractText":"","Heading":"","RelatedTopics":[]}"#.utf8)
    ))
    await #expect(throws: WebToolError.disallowedHost) {
        try await DuckDuckGoSearchProvider(fetcher: fetcher).search(query: "swift", maximumResults: 3)
    }
}

@Test func webSearchDenialPreventsEveryNetworkSideEffect() async throws {
    let provider = CountingSearchProvider()
    let journal = AgentEventJournal()
    let broker = ToolExecutionBroker(journal: journal)
    let tool = WebSearchTool(provider: provider, broker: broker, invocationNamespace: "turn-1")
    let task = Task { try await tool.call(arguments: WebSearchArguments(query: "private query")) }
    let request = try await nextApproval(in: journal)

    #expect(await provider.callCount == 0)
    #expect(await broker.resolve(id: request.id, approved: false))
    await #expect(throws: ToolApprovalError.denied) { try await task.value }
    #expect(await provider.callCount == 0)
}

@Test func webSearchAllowOnceRequiresApprovalForEachInvocation() async throws {
    let provider = CountingSearchProvider()
    let journal = AgentEventJournal()
    let broker = ToolExecutionBroker(journal: journal)
    let tool = WebSearchTool(provider: provider, broker: broker, invocationNamespace: "turn-2")
    let arguments = WebSearchArguments(query: "approved query")
    let first = Task { try await tool.call(arguments: arguments) }
    let request = try await nextApproval(in: journal)
    #expect(await broker.resolve(id: request.id, approved: true))
    let firstOutput = try await first.value
    let second = Task { try await tool.call(arguments: arguments) }
    let secondRequest = try await nextApproval(in: journal, after: 2)
    #expect(await broker.resolve(id: secondRequest.id, approved: true))
    let secondOutput = try await second.value

    #expect(firstOutput == secondOutput)
    #expect(await provider.callCount == 2)
    let journalEvents = await journal.snapshot()
    let approvals = journalEvents.compactMap { event -> AgentApprovalRequest? in
        guard case .approvalRequested(let value) = event else { return nil }
        return value
    }
    #expect(approvals.count == 2)
    #expect(approvals[0].idempotencyKey == request.idempotencyKey)
    #expect(approvals[1].idempotencyKey != request.idempotencyKey)
}

@Test func cancellingPendingWebApprovalDoesNotCallProvider() async throws {
    let provider = CountingSearchProvider()
    let journal = AgentEventJournal()
    let broker = ToolExecutionBroker(journal: journal)
    let tool = WebSearchTool(provider: provider, broker: broker, invocationNamespace: "turn-3")
    let task = Task { try await tool.call(arguments: WebSearchArguments(query: "cancelled query")) }
    _ = try await nextApproval(in: journal)
    task.cancel()

    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await provider.callCount == 0)
}

@Test func approvalIdentityIsStableForSameTurnAndArguments() async throws {
    let firstJournal = AgentEventJournal()
    let secondJournal = AgentEventJournal()
    let firstBroker = ToolExecutionBroker(journal: firstJournal)
    let secondBroker = ToolExecutionBroker(journal: secondJournal)
    await firstBroker.registerInvocation(toolName: "searchWeb", toolCallID: "same-call")
    await secondBroker.registerInvocation(toolName: "searchWeb", toolCallID: "same-call")
    let firstTool = WebSearchTool(provider: CountingSearchProvider(), broker: firstBroker, invocationNamespace: "stable-turn")
    let secondTool = WebSearchTool(provider: CountingSearchProvider(), broker: secondBroker, invocationNamespace: "stable-turn")
    let firstTask = Task { try await firstTool.call(arguments: WebSearchArguments(query: "same")) }
    let secondTask = Task { try await secondTool.call(arguments: WebSearchArguments(query: "same")) }
    let firstRequest = try await nextApproval(in: firstJournal)
    let secondRequest = try await nextApproval(in: secondJournal)
    firstTask.cancel()
    secondTask.cancel()

    #expect(firstRequest.id == secondRequest.id)
    #expect(firstRequest.idempotencyKey == secondRequest.idempotencyKey)
}

@Test func interleavedApprovalsResolveTheirExactExternalToolCalls() async throws {
    let provider = CountingSearchProvider()
    let journal = AgentEventJournal()
    let broker = ToolExecutionBroker(journal: journal)
    await broker.registerInvocation(toolName: "searchWeb", toolCallID: "opaque-call-a")
    await broker.registerInvocation(toolName: "searchWeb", toolCallID: "opaque-call-b")
    let firstTool = WebSearchTool(provider: provider, broker: broker, invocationNamespace: "interleaved")
    let secondTool = WebSearchTool(provider: provider, broker: broker, invocationNamespace: "interleaved")

    let firstTask = Task { try await firstTool.call(arguments: WebSearchArguments(query: "first")) }
    let first = try await nextApproval(in: journal, after: 0)
    let secondTask = Task { try await secondTool.call(arguments: WebSearchArguments(query: "second")) }
    let second = try await nextApproval(in: journal, after: 1)

    #expect(first.toolCallID == "opaque-call-a")
    #expect(second.toolCallID == "opaque-call-b")
    #expect(await broker.resolve(id: second.id, approved: true))
    _ = try await secondTask.value
    #expect(await broker.resolve(id: first.id, approved: false))
    await #expect(throws: ToolApprovalError.denied) { try await firstTask.value }
    #expect(await provider.callCount == 1)
}

@Test func concurrentIdenticalSearchesKeepIndependentApprovalWaiters() async throws {
    let provider = CountingSearchProvider()
    let journal = AgentEventJournal()
    let broker = ToolExecutionBroker(journal: journal)
    await broker.registerInvocation(toolName: "searchWeb", toolCallID: "identical-a")
    await broker.registerInvocation(toolName: "searchWeb", toolCallID: "identical-b")
    let tool = WebSearchTool(provider: provider, broker: broker, invocationNamespace: "same-query")
    let firstTask = Task { try await tool.call(arguments: WebSearchArguments(query: "same")) }
    let first = try await nextApproval(in: journal)
    let secondTask = Task { try await tool.call(arguments: WebSearchArguments(query: "same")) }
    let second = try await nextApproval(in: journal, after: 1)

    #expect(first.id != second.id)
    #expect(await broker.resolve(id: first.id, approved: true))
    #expect(await broker.resolve(id: second.id, approved: true))
    _ = try await firstTask.value
    _ = try await secondTask.value
    #expect(await provider.callCount == 2)
}

@Test func opaqueDocumentToolCallIdentityIsStableForCompactionAndRestore() {
    let opaqueID = "provider/document-call:not-a-uuid"
    let first = ToolIdentity.uuid(forOpaqueID: opaqueID)
    let restored = ToolIdentity.uuid(forOpaqueID: opaqueID)

    #expect(first == restored)
    #expect(first != ToolIdentity.uuid(forOpaqueID: opaqueID + "-different"))
}

@Test func cancellingOneInterleavedApprovalDoesNotAffectTheOther() async throws {
    let provider = CountingSearchProvider()
    let journal = AgentEventJournal()
    let broker = ToolExecutionBroker(journal: journal)
    await broker.registerInvocation(toolName: "searchWeb", toolCallID: "cancel-a")
    await broker.registerInvocation(toolName: "searchWeb", toolCallID: "allow-b")
    let tool = WebSearchTool(provider: provider, broker: broker, invocationNamespace: "cancel-interleaved")
    let cancelledTask = Task { try await tool.call(arguments: WebSearchArguments(query: "cancel me")) }
    _ = try await nextApproval(in: journal)
    let allowedTask = Task { try await tool.call(arguments: WebSearchArguments(query: "allow me")) }
    let allowedRequest = try await nextApproval(in: journal, after: 1)

    cancelledTask.cancel()
    #expect(await broker.resolve(id: allowedRequest.id, approved: true))
    _ = try await allowedTask.value
    await #expect(throws: CancellationError.self) { try await cancelledTask.value }
    #expect(await provider.callCount == 1)
}

@Test func webFetchStripsActiveHTMLAndReportsFinalSource() async throws {
    let response = WebFetchResponse(
        finalURL: URL(string: "https://example.com/final")!,
        mimeType: "text/html",
        data: Data("<h1>Title</h1><script>steal()</script><p>Body &amp; facts.</p>".utf8)
    )
    let tool = WebFetchTool(fetcher: StubWebFetcher(response: response), maximumBytes: 1_024)
    let output = try await tool.call(arguments: WebFetchArguments(url: "https://example.com/start"))

    #expect(output.contains("Source: https://example.com/final"))
    #expect(output.contains("Title"))
    #expect(output.contains("Body & facts."))
    #expect(!output.contains("steal()"))
}

@Test func webFetchEnforcesMIMEAndSizeAgainstInjectedClients() async {
    let badMIME = WebFetchResponse(
        finalURL: URL(string: "https://example.com/file")!,
        mimeType: "application/octet-stream",
        data: Data([0, 1])
    )
    await #expect(throws: WebToolError.unsupportedMIMEType("application/octet-stream")) {
        try await WebFetchTool(fetcher: StubWebFetcher(response: badMIME)).call(
            arguments: WebFetchArguments(url: "https://example.com/file")
        )
    }

    let oversized = WebFetchResponse(
        finalURL: URL(string: "https://example.com/large")!,
        mimeType: "text/plain",
        data: Data(repeating: 65, count: 5)
    )
    await #expect(throws: WebToolError.responseTooLarge(maximumBytes: 4)) {
        try await WebFetchTool(fetcher: StubWebFetcher(response: oversized), maximumBytes: 4).call(
            arguments: WebFetchArguments(url: "https://example.com/large")
        )
    }
}

@Test func documentDraftStaysInMemoryAndEmitsAnArtifact() async throws {
    let store = DocumentArtifactStore()
    let journal = AgentEventJournal()
    let output = try await CreateDocumentDraftTool(store: store, journal: journal).call(
        arguments: CreateDocumentArguments(title: "Report", markdown: "# Report\n\nEvidence.")
    )
    let draft = try #require(await store.allDrafts().first)
    #expect(output.contains(draft.id.uuidString))
    #expect(await journal.snapshot() == [.artifact(.init(
        id: draft.id,
        title: "Report",
        mediaType: "text/markdown",
        content: draft.markdown,
        revision: 1
    ))])

}

@Test func documentStoreEvictsOldestDraftsToStayWithinQuotas() async throws {
    let store = DocumentArtifactStore(maximumDrafts: 2, maximumStoredCharacters: 8)
    let first = try await store.create(title: "One", markdown: "1111")
    let second = try await store.create(title: "Two", markdown: "22")
    let third = try await store.create(title: "Three", markdown: "3333")

    #expect(await store.draft(id: first.id) == nil)
    #expect(await store.allDrafts().map(\.id) == [second.id, third.id])
    #expect(await store.retainedCharacterCount() == 6)
    await #expect(throws: DocumentToolError.storeQuotaExceeded(maximumCharacters: 8)) {
        try await store.create(title: "Too large", markdown: "123456789")
    }
}

private actor StubSearchProvider: WebSearching {
    let sources: [WebSource]
    var lastLimit: Int?

    init(sources: [WebSource]) { self.sources = sources }

    func search(query: String, maximumResults: Int) async throws -> [WebSource] {
        lastLimit = maximumResults
        return sources
    }
}

private actor CountingSearchProvider: WebSearching {
    var callCount = 0

    func search(query: String, maximumResults: Int) async throws -> [WebSource] {
        callCount += 1
        return [WebSource(
            title: "Result",
            url: URL(string: "https://example.com/result")!,
            snippet: "Untrusted evidence"
        )]
    }
}

private actor RecoveringSearchProvider: WebSearching {
    private let failuresBeforeSuccess: Int
    var callCount = 0

    init(failuresBeforeSuccess: Int) { self.failuresBeforeSuccess = failuresBeforeSuccess }

    func search(query: String, maximumResults: Int) async throws -> [WebSource] {
        callCount += 1
        if callCount <= failuresBeforeSuccess { throw WebToolError.invalidStatus(503) }
        return [WebSource(
            title: "Recovered result",
            url: URL(string: "https://example.com/recovered")!,
            snippet: "Available after retry"
        )]
    }
}

private actor FailingSearchProvider: WebSearching {
    private let error: WebToolError
    var callCount = 0

    init(error: WebToolError) { self.error = error }

    func search(query: String, maximumResults: Int) async throws -> [WebSource] {
        callCount += 1
        throw error
    }
}

private func nextApproval(in journal: AgentEventJournal, after index: Int = 0) async throws -> AgentApprovalRequest {
    for await event in await journal.stream(after: index) {
        if case .approvalRequested(let request) = event { return request }
    }
    throw CancellationError()
}

private struct StubWebFetcher: WebFetching {
    let response: WebFetchResponse

    func fetch(url: URL, maximumBytes: Int, allowedMIMETypes: Set<String>) async throws -> WebFetchResponse {
        response
    }
}

private actor RecordingWebFetcher: WebFetching {
    let response: WebFetchResponse
    var requestedURL: URL?
    var maximumBytes: Int?
    var allowedMIMETypes = Set<String>()

    init(response: WebFetchResponse) { self.response = response }

    func fetch(url: URL, maximumBytes: Int, allowedMIMETypes: Set<String>) async throws -> WebFetchResponse {
        requestedURL = url
        self.maximumBytes = maximumBytes
        self.allowedMIMETypes = allowedMIMETypes
        return response
    }
}

private actor SequenceWebFetcher: WebFetching {
    private var responses: [WebFetchResponse]
    var requestedHosts: [String] = []

    init(responses: [WebFetchResponse]) { self.responses = responses }

    func fetch(url: URL, maximumBytes: Int, allowedMIMETypes: Set<String>) throws -> WebFetchResponse {
        requestedHosts.append(url.host ?? "")
        guard !responses.isEmpty else { throw WebToolError.invalidStatus(0) }
        return responses.removeFirst()
    }
}
