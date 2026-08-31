import Foundation
import Testing
@testable import CoreAIAgent

@MainActor
@Test func selectingFastProfileLoadsItAndPersistsTheConversationPreference() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = JSONAppStateStore(fileURL: root.appending(path: "state.json"))
    let harness = JSONHarnessStore(rootURL: root.appending(path: "harness"))
    let conversation = Conversation()
    try store.save(PersistedAppState(
        conversations: [conversation], folders: [], openConversationIDs: [conversation.id],
        selectedConversationID: conversation.id
    ))
    let service = ProfileModelServiceStub()
    let model = AppModel(
        modelService: service,
        appStateStore: store,
        harnessStore: harness,
        modelResourceURLs: [.deep: root.appending(path: "deep"), .fast: root.appending(path: "fast")]
    )
    try await waitForProfile { model.isSelectedModelReady }

    model.selectModelProfile(.fast)
    try await waitForProfile { model.selectedModelProfile == .fast && model.isSelectedModelReady }

    #expect(model.selectedReasoningEnabled == false)
    #expect(await service.loadedProfiles == [.deep, .fast])
    try await Task.sleep(for: .milliseconds(400))
    let restored = try #require(try store.load()?.conversations.first)
    #expect(restored.modelProfile == .fast)
}

@MainActor
@Test func newConversationUsesTheCurrentlySelectedModelProfile() async throws {
    let root = try makeProfileTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let conversation = Conversation(modelProfile: .fast)
    let store = JSONAppStateStore(fileURL: root.appending(path: "state.json"))
    try store.save(PersistedAppState(
        conversations: [conversation], folders: [], openConversationIDs: [conversation.id],
        selectedConversationID: conversation.id
    ))
    let model = AppModel(
        modelService: ProfileModelServiceStub(),
        appStateStore: store,
        harnessStore: JSONHarnessStore(rootURL: root.appending(path: "harness")),
        modelResourceURLs: [.deep: root.appending(path: "deep"), .fast: root.appending(path: "fast")]
    )
    try await waitForProfile { model.isSelectedModelReady }

    model.newConversation()

    #expect(model.selectedModelProfile == .fast)
    #expect(model.conversations.first?.modelProfile == .fast)
}

@MainActor
@Test func deletingConversationDuringModelSwitchSettlesOnAUsableModel() async throws {
    let root = try makeProfileTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let conversation = Conversation()
    let store = JSONAppStateStore(fileURL: root.appending(path: "state.json"))
    try store.save(PersistedAppState(
        conversations: [conversation], folders: [], openConversationIDs: [conversation.id],
        selectedConversationID: conversation.id
    ))
    let service = ProfileModelServiceStub(delayedProfiles: [.fast])
    let model = AppModel(
        modelService: service,
        appStateStore: store,
        harnessStore: JSONHarnessStore(rootURL: root.appending(path: "harness")),
        modelResourceURLs: [.deep: root.appending(path: "deep"), .fast: root.appending(path: "fast")]
    )
    try await waitForProfile { model.isSelectedModelReady }

    model.selectModelProfile(.fast)
    #expect(model.loadingModelProfile == .fast)
    model.deleteConversation(conversation.id)
    try await waitForProfile { model.modelPhase == .ready }

    #expect(model.modelPhase == .ready)
    #expect(model.loadingModelProfile == nil)
}

@Test func composerModelControlNamesThePendingProfileWithoutASecondSpinner() {
    let presentation = ModelProfileControlPresentation(
        profile: .deep,
        loadingProfile: .fast,
        phase: .loading,
        isSelectedModelReady: false,
        reasoningEnabled: false,
        notice: "Loading Nemotron 3 Nano 4B…"
    )

    #expect(presentation.label == "Fast…")
    #expect(presentation.systemImage == "hourglass")
    #expect(presentation.isLoading)
    #expect(presentation.accessibilityValue.contains("Fast"))
    #expect(presentation.accessibilityValue.contains("loading"))
}

@Test func composerModelControlReportsActiveFastReasoningState() {
    let presentation = ModelProfileControlPresentation(
        profile: .fast,
        loadingProfile: nil,
        phase: .generating,
        isSelectedModelReady: false,
        reasoningEnabled: true,
        notice: nil
    )

    #expect(presentation.label == "Fast · Think")
    #expect(presentation.systemImage == "bolt.fill")
    #expect(presentation.accessibilityValue.contains("in use"))
    #expect(presentation.accessibilityValue.contains("reasoning on"))
}

@Test func composerModelControlShowsLoadFailuresButNotSuccessNoticesAsWarnings() {
    let failure = ModelProfileControlPresentation(
        profile: .deep,
        loadingProfile: nil,
        phase: .ready,
        isSelectedModelReady: true,
        reasoningEnabled: true,
        notice: "Nemotron 3 Nano 4B is not bundled in this build."
    )
    let success = ModelProfileControlPresentation(
        profile: .fast,
        loadingProfile: nil,
        phase: .ready,
        isSelectedModelReady: true,
        reasoningEnabled: false,
        notice: "Nemotron 3 Nano 4B is ready. Existing turns will be re-prefilled."
    )

    #expect(failure.hasWarning)
    #expect(failure.label == "Deep !")
    #expect(!success.hasWarning)
    #expect(success.label == "Fast")
}

@MainActor
@Test func failedAutomaticSwitchFallsBackToTheLoadedProfile() async throws {
    let root = try makeProfileTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let deep = Conversation(title: "Deep", modelProfile: .deep)
    let fast = Conversation(title: "Fast", modelProfile: .fast)
    let store = JSONAppStateStore(fileURL: root.appending(path: "state.json"))
    try store.save(PersistedAppState(
        conversations: [deep, fast], folders: [], openConversationIDs: [deep.id, fast.id],
        selectedConversationID: deep.id
    ))
    let service = ProfileModelServiceStub(failingProfiles: [.fast])
    let model = AppModel(
        modelService: service,
        appStateStore: store,
        harnessStore: JSONHarnessStore(rootURL: root.appending(path: "harness")),
        modelResourceURLs: [.deep: root.appending(path: "deep"), .fast: root.appending(path: "fast")]
    )
    try await waitForProfile { model.isSelectedModelReady }

    model.selectConversation(fast.id)
    try await waitForProfile { model.modelPhase == .ready && model.selectedModelProfile == .deep }

    #expect(model.isSelectedModelReady)
    #expect(model.modelSelectionNotice?.contains("Could not load") == true)
}

@MainActor
@Test func restoredUnavailableProfileFallsBackWithVisibleNotice() throws {
    let root = try makeProfileTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fast = Conversation(modelProfile: .fast)
    let store = JSONAppStateStore(fileURL: root.appending(path: "state.json"))
    try store.save(PersistedAppState(
        conversations: [fast], folders: [], openConversationIDs: [fast.id],
        selectedConversationID: fast.id
    ))
    let model = AppModel(
        modelService: ProfileModelServiceStub(),
        appStateStore: store,
        harnessStore: JSONHarnessStore(rootURL: root.appending(path: "harness")),
        modelResourceURLs: [.deep: root.appending(path: "deep")]
    )

    #expect(model.selectedModelProfile == .deep)
    #expect(model.modelSelectionNotice?.contains("not bundled") == true)
}

private actor ProfileModelServiceStub: ModelServing {
    private(set) var loadedProfiles = [ModelProfile]()
    private let failingProfiles: Set<ModelProfile>
    private let delayedProfiles: Set<ModelProfile>

    init(failingProfiles: Set<ModelProfile> = [], delayedProfiles: Set<ModelProfile> = []) {
        self.failingProfiles = failingProfiles
        self.delayedProfiles = delayedProfiles
    }

    func load(resourcesAt url: URL) async throws {}
    func load(resourcesAt url: URL, for profile: ModelProfile) async throws {
        loadedProfiles.append(profile)
        if delayedProfiles.contains(profile) { try await Task.sleep(for: .milliseconds(100)) }
        if failingProfiles.contains(profile) { throw ProfileTestError.loadFailed }
    }
    nonisolated func generate(conversationID: UUID, prompt: String) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    nonisolated func generate(
        conversationID: UUID, prompt: String, enabledSkillIDs: Set<String>
    ) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    nonisolated func generate(request: ModelGenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func cancel() async {}
    func resolveApproval(id: UUID, approved: Bool) async -> Bool { false }
}

private func makeProfileTestRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@MainActor
private func waitForProfile(
    timeout: Duration = .seconds(5),
    _ condition: @escaping @MainActor () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        guard clock.now < deadline else { throw ProfileTestError.timedOut }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private enum ProfileTestError: Error { case timedOut, loadFailed }
