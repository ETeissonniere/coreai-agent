import Foundation
import Observation
import CoreAIAgentRuntime
import CryptoKit
import AppKit

@MainActor
@Observable
final class AppModel {
    var conversations = [Conversation()]
    var folders = [ConversationFolder]()
    var openConversationIDs = [UUID]()
    var selectedConversationID: UUID?
    var modelPhase: ModelPhase = .missing
    private var drafts = [UUID: String]()
    var modelURL: URL?
    var modelSelectionNotice: String?
    private(set) var loadingModelProfile: ModelProfile?
    private var modelURLs = [ModelProfile: URL]()
    private var activeModelProfile: ModelProfile?
    var showInspector = false
    var lastMetrics: GenerationMetrics?
    var lastModelLoadDuration: Duration?
    var contextByConversation = [UUID: ContextStatus]()
    var kvCacheByConversation = [UUID: KVCacheSnapshot]()
    var inspectorSection: TaskInspectorSection = .artifacts
    var selectedArtifactID: UUID?
    var enabledSkillIDs = Set<String>()
    var availableSkills = [AgentSkillMetadata]()
    var taskPlans = [UUID: [TaskPlanStep]]()
    var artifactsByConversation = [UUID: [TaskArtifact]]()
    var approvalsByConversation = [UUID: [TaskApprovalRequest]]()
    var toolActivitiesByConversation = [UUID: [ToolActivityPresentation]]()
    var executionTraceByMessage = [UUID: AssistantExecutionTrace]()
    var runStatusByConversation = [UUID: AgentRunStatus]()
    var recoveryCheckpointByConversation = [UUID: AgentRunCheckpoint]()
    var recoveredConversationIDs = Set<UUID>()
    var persistenceRecoveryNotice: String?
    var draftAttachmentsByConversation = [UUID: [ComposerAttachment]]()
    var attachmentNotice: String?
    var titleGenerationFailuresByConversation = [UUID: TitleGenerationFailure]()
    private var attachmentIngestionConversationIDs = Set<UUID>()

    private let modelService: any ModelServing
    private let appStateStore: any AppStateStoring
    private let harnessStore: any HarnessStoring
    private let titleService: any TitleGenerating
    private var persistenceTask: Task<Void, Never>?
    private var modelLoadTask: Task<Void, Never>?
    private var requestedModelLoad: ModelLoadRequest?
    private var generationTask: Task<Void, Never>?
    private var generatingConversationID: UUID?
    private var generatingResponseID: UUID?
    private var harnessBootstrapTask: Task<Void, Never>?
    private var taskIDByConversation = [UUID: UUID]()
    private var runIDByConversation = [UUID: UUID]()
    private var enabledSkillIDsByConversation = [UUID: Set<String>]()
    private var compactionByConversation = [UUID: StructuredCompactionState]()
    private var approvalInvocationIDs = [UUID: UUID]()
    private var durableArtifactsByConversation = [UUID: [AgentArtifact]]()
    private var queuedSubmissions = [UUID: QueuedSubmission]()

    private struct ModelLoadRequest {
        let profile: ModelProfile
        let conversationID: UUID?
    }

    init(
        modelService: any ModelServing = CoreAIModelService(),
        appStateStore: any AppStateStoring = JSONAppStateStore(),
        harnessStore: any HarnessStoring = JSONHarnessStore.shared,
        titleService: (any TitleGenerating)? = nil,
        modelResourceURLs: [ModelProfile: URL]? = nil
    ) {
        self.modelService = modelService
        self.appStateStore = appStateStore
        self.harnessStore = harnessStore
        let titlePath = "Models/TitleModel/qwen3_0_6b_4bit_dynamic"
        let titleCandidates = [
            Bundle.main.resourceURL?.appending(path: titlePath),
            URL(filePath: FileManager.default.currentDirectoryPath).appending(path: titlePath),
            Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
                .appending(path: titlePath).standardizedFileURL,
        ].compactMap { $0 }
        self.titleService = titleService ?? TitleModelService(resourcesURL: titleCandidates.first(where: {
            FileManager.default.fileExists(atPath: $0.appending(path: "metadata.json").path)
        }))
        let restoredState: PersistedAppState?
        do {
            restoredState = try appStateStore.load()
        } catch {
            restoredState = nil
            persistenceRecoveryNotice = "The chat index could not be decoded. Recovering from durable task history instead of overwriting it. \(error.localizedDescription)"
        }
        if let restored = restoredState {
            conversations = restored.conversations
            folders = restored.folders
            openConversationIDs = restored.openConversationIDs
            selectedConversationID = restored.selectedConversationID
            draftAttachmentsByConversation = restored.draftAttachments ?? [:]
            queuedSubmissions = restored.queuedSubmissions ?? [:]
            for (conversationID, submission) in queuedSubmissions {
                drafts[conversationID] = submission.prompt
                draftAttachmentsByConversation[conversationID] = submission.attachments
            }
        } else {
            selectedConversationID = conversations.first?.id
            openConversationIDs = conversations.map(\.id)
        }
        if let modelResourceURLs {
            modelURLs = modelResourceURLs
        } else {
            for profile in ModelProfile.allCases {
                if let localBundle = Self.modelCandidates(for: profile).first(where: {
                    FileManager.default.fileExists(atPath: $0.appending(path: "metadata.json").path)
                }) {
                    modelURLs[profile] = localBundle
                }
            }
        }
        let initialProfile = selectedModelProfile
        let loadProfile = modelURLs[initialProfile] == nil
            ? ([ModelProfile.deep, .fast].first { modelURLs[$0] != nil } ?? initialProfile)
            : initialProfile
        if loadProfile != initialProfile, let index = selectedIndex {
            queuedSubmissions[conversations[index].id] = nil
            conversations[index].modelProfile = loadProfile
            conversations[index].reasoningEnabled = loadProfile.defaultReasoningEnabled
            modelSelectionNotice = "\(initialProfile.modelName) is not bundled. Using \(loadProfile.modelName)."
            schedulePersistence()
        }
        if let localBundle = modelURLs[loadProfile] {
            loadModel(from: localBundle, for: loadProfile)
        } else {
            modelSelectionNotice = "No bundled model is available. Run make download, then repackage the app."
        }
        harnessBootstrapTask = Task { [weak self] in
            guard let self else { return }
            await self.bootstrapHarness(from: restoredState)
        }
        discoverSkills()
    }

    var selectedIndex: Int? {
        guard let selectedConversationID else { return nil }
        return conversations.firstIndex { $0.id == selectedConversationID }
    }

    private static func modelCandidates(for profile: ModelProfile) -> [URL] {
        let path = profile.resourcePath
        return [
            Bundle.main.resourceURL?.appending(path: path),
            URL(filePath: FileManager.default.currentDirectoryPath).appending(path: path),
            Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
                .appending(path: path).standardizedFileURL,
        ].compactMap { $0 }
    }

    var selectedModelProfile: ModelProfile {
        selectedIndex.map { conversations[$0].modelProfile } ?? .deep
    }

    var selectedReasoningEnabled: Bool {
        selectedIndex.map { conversations[$0].reasoningEnabled } ?? true
    }

    var isSelectedModelReady: Bool {
        modelPhase == .ready && activeModelProfile == selectedModelProfile
    }

    var isSelectedSubmissionQueued: Bool {
        selectedConversationID.map { queuedSubmissions[$0] != nil } ?? false
    }

    func isModelAvailable(_ profile: ModelProfile) -> Bool { modelURLs[profile] != nil }

    var draft: String {
        get { selectedConversationID.flatMap { drafts[$0] } ?? "" }
        set {
            guard let selectedConversationID else { return }
            drafts[selectedConversationID] = newValue
        }
    }

    var selectedContext: ContextStatus? {
        selectedConversationID.flatMap { conversationID in
            contextByConversation[conversationID]
                ?? conversations.first(where: { $0.id == conversationID })?.messages
                    .reversed().compactMap(\.contextSnapshot).first
        }
    }

    var selectedKVCache: KVCacheSnapshot? {
        selectedConversationID.flatMap { conversationID in
            kvCacheByConversation[conversationID]
                ?? conversations.first(where: { $0.id == conversationID })?.messages
                    .reversed().compactMap(\.kvCacheSnapshot).first
        }
    }

    var draftAttachments: [ComposerAttachment] {
        selectedConversationID.flatMap { draftAttachmentsByConversation[$0] } ?? []
    }

    var isAttachingFiles: Bool {
        selectedConversationID.map { attachmentIngestionConversationIDs.contains($0) } ?? false
    }

    func chooseAttachments() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.prompt = "Attach"
        guard panel.runModal() == .OK else { return }
        addAttachments(from: panel.urls)
    }

    func addAttachments(from urls: [URL]) {
        guard let conversationID = selectedConversationID, queuedSubmissions[conversationID] == nil,
              !urls.isEmpty else { return }
        attachmentNotice = nil
        attachmentIngestionConversationIDs.insert(conversationID)
        Task {
            defer { attachmentIngestionConversationIDs.remove(conversationID) }
            do {
                let ingested = try await Task.detached { try AttachmentIngestion().ingest(urls) }.value
                guard !ingested.isEmpty else {
                    attachmentNotice = "No supported UTF-8 text files under 128 KB were found."
                    return
                }
                var current = draftAttachmentsByConversation[conversationID] ?? []
                let existing = Set(current.map(\.sourcePath))
                let remainingBytes = max(
                    AttachmentIngestion.maximumTotalBytes - current.reduce(0) { $0 + $1.byteCount },
                    0
                )
                var addedBytes = 0
                for attachment in ingested where
                    !existing.contains(attachment.sourcePath)
                    && current.count < AttachmentIngestion.maximumFiles
                    && addedBytes + attachment.byteCount <= remainingBytes {
                    current.append(attachment)
                    addedBytes += attachment.byteCount
                }
                draftAttachmentsByConversation[conversationID] = current
                schedulePersistence()
            } catch {
                attachmentNotice = "Could not attach those items: \(error.localizedDescription)"
            }
        }
    }

    func removeAttachment(_ id: UUID) {
        guard let conversationID = selectedConversationID else { return }
        draftAttachmentsByConversation[conversationID]?.removeAll { $0.id == id }
        schedulePersistence()
    }

    var enabledSkills: [AgentSkillMetadata] {
        availableSkills.filter { enabledSkillIDs.contains($0.id) }
    }

    var skillCommandSuggestions: [AgentSkillMetadata] {
        SkillRouter().suggestions(for: draft, in: availableSkills)
    }

    func invokeSkillCommand(_ skill: AgentSkillMetadata) {
        draft = SkillRouter().inserting(skill, into: draft)
    }

    private func discoverSkills() {
        let workingDirectory = URL(filePath: FileManager.default.currentDirectoryPath)
        let optionalRoots = [
            Bundle.main.resourceURL.map { SkillSearchRoot(url: $0.appending(path: "Skills"), scope: .bundled) },
            SkillSearchRoot(url: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex/skills"), scope: .user),
            SkillSearchRoot(url: workingDirectory.appending(path: ".agents/skills"), scope: .workspace),
            SkillSearchRoot(url: workingDirectory.appending(path: ".codex/skills"), scope: .workspace),
        ]
        let discovered = (try? SkillDiscovery().discover(in: optionalRoots.compactMap { $0 })) ?? []
        var skillsByName = Dictionary(uniqueKeysWithValues: discovered.map { ($0.name, $0) })
        for skill in Self.builtInSkills { skillsByName[skill.name] = skill }
        availableSkills = skillsByName.values.sorted { $0.name < $1.name }
    }

    func toggleSkill(_ id: String) {
        let id = Self.canonicalSkillID(id)
        if enabledSkillIDs.contains(id) { enabledSkillIDs.remove(id) }
        else { enabledSkillIDs.insert(id) }
        guard let conversationID = selectedConversationID else { return }
        enabledSkillIDsByConversation[conversationID] = enabledSkillIDs
    }

    func hasPendingApproval(for conversationID: UUID) -> Bool {
        approvalsByConversation[conversationID]?.contains { $0.decision == .pending } == true
    }

    func decideApproval(
        _ approvalID: UUID,
        in conversationID: UUID,
        decision: TaskApprovalRequest.Decision
    ) {
        if let status = runStatusByConversation[conversationID],
           status == .completed || status == .cancelled || status == .failed {
            persistenceRecoveryNotice = "This approval belongs to a finished run and can no longer change its state."
            return
        }
        guard let index = approvalsByConversation[conversationID]?.firstIndex(where: { $0.id == approvalID }) else { return }
        guard approvalsByConversation[conversationID]?[index].decision == .pending else { return }
        Task {
            let resolvedAt = Date.now
            guard await persistApprovalDecision(
                approvalID,
                in: conversationID,
                decision: decision,
                resolvedAt: resolvedAt
            ) else { return }
            approvalsByConversation[conversationID]?[index].decision = decision
            let approved = decision != .denied
            await persistApprovalOutcomeStatus(
                approvalID,
                in: conversationID,
                shouldRun: approved,
                timestamp: resolvedAt
            )
            let accepted = await modelService.resolveApproval(id: approvalID, approved: decision != .denied)
            if let invocationID = approvalInvocationIDs[approvalID],
               let activity = toolActivitiesByConversation[conversationID]?
                    .first(where: { $0.invocation.id == invocationID }) {
                let shouldRun = accepted && decision != .denied
                let result = shouldRun ? nil : ToolResultRecord(
                    invocationID: invocationID,
                    content: decision == .denied ? "Permission denied." : "The original run is no longer active.",
                    isError: true
                )
                upsertToolActivity(
                    activity.invocation,
                    state: shouldRun ? .running : .failed,
                    result: result,
                    in: conversationID
                )
                if shouldRun, let runID = runIDByConversation[conversationID] {
                    _ = try? await harnessStore.append(
                        .toolStarted(invocationID: invocationID),
                        to: runID,
                        idempotencyKey: "tool-started:\(activity.invocation.idempotencyKey)",
                        timestamp: resolvedAt
                    )
                }
            }
            if approved && !accepted {
                await persistApprovalOutcomeStatus(
                    approvalID,
                    in: conversationID,
                    shouldRun: false,
                    timestamp: resolvedAt
                )
            }
            if !accepted {
                persistenceRecoveryNotice = "The permission decision was saved, but its original run is no longer active. No external action was started."
            }
        }
    }

    func newConversation() {
        newConversation(in: nil)
    }

    func newConversation(in folderID: UUID?) {
        let conversation = Conversation(
            folderID: folderID,
            modelProfile: selectedModelProfile
        )
        conversations.insert(conversation, at: 0)
        openConversationIDs.append(conversation.id)
        selectConversationID(conversation.id)
        draft = ""
        schedulePersistence()
        activateSelectedModelIfNeeded()
        Task { _ = try? await ensureTask(for: conversation.id) }
    }

    func selectConversation(_ id: UUID) {
        if !openConversationIDs.contains(id) { openConversationIDs.append(id) }
        selectConversationID(id)
        schedulePersistence()
        activateSelectedModelIfNeeded()
        sendQueuedSubmissionIfReady()
    }

    /// Restores the last request to the composer so a failed response can be
    /// reviewed or edited before starting a replacement run.
    func prepareRetry(in conversationID: UUID) {
        guard modelPhase == .ready,
              let conversation = conversations.first(where: { $0.id == conversationID }),
              conversation.taskState(
                hasPendingApproval: hasPendingApproval(for: conversationID),
                durableRunStatus: runStatusByConversation[conversationID]
              ) == .failed,
              let request = conversation.messages.last(where: { $0.role == .user }) else { return }
        selectConversation(conversationID)
        draft = request.text
        recoveredConversationIDs.remove(conversationID)
    }

    func dismissRecoveryNotice(in conversationID: UUID) {
        recoveredConversationIDs.remove(conversationID)
    }

    func closeTab(_ id: UUID) {
        guard let tabIndex = openConversationIDs.firstIndex(of: id) else { return }
        queuedSubmissions[id] = nil
        openConversationIDs.remove(at: tabIndex)
        if selectedConversationID == id {
            selectConversationID(openConversationIDs.indices.contains(tabIndex)
                ? openConversationIDs[tabIndex]
                : openConversationIDs.last)
        }
        schedulePersistence()
        activateSelectedModelIfNeeded()
    }

    func closeOtherTabs(keeping id: UUID) {
        guard openConversationIDs.contains(id) else { return }
        openConversationIDs = [id]
        selectConversationID(id)
        schedulePersistence()
        activateSelectedModelIfNeeded()
    }

    func closeTabsToRight(of id: UUID) {
        guard let index = openConversationIDs.firstIndex(of: id),
              index < openConversationIDs.index(before: openConversationIDs.endIndex) else { return }
        let retained = Array(openConversationIDs.prefix(through: index))
        if let selectedConversationID, !retained.contains(selectedConversationID) {
            selectConversationID(id)
        }
        openConversationIDs = retained
        schedulePersistence()
        activateSelectedModelIfNeeded()
    }

    func deleteConversation(_ id: UUID) {
        if generatingConversationID == id { stop() }
        let taskID = taskIDByConversation[id]
        let removedTabIndex = openConversationIDs.firstIndex(of: id)
        let removedMessageIDs = conversations.first(where: { $0.id == id })?.messages.map(\.id) ?? []

        conversations.removeAll { $0.id == id }
        openConversationIDs.removeAll { $0 == id }
        drafts[id] = nil
        draftAttachmentsByConversation[id] = nil
        attachmentIngestionConversationIDs.remove(id)
        contextByConversation[id] = nil
        kvCacheByConversation[id] = nil
        taskPlans[id] = nil
        artifactsByConversation[id] = nil
        approvalsByConversation[id] = nil
        toolActivitiesByConversation[id] = nil
        for messageID in removedMessageIDs {
            executionTraceByMessage[messageID] = nil
        }
        runStatusByConversation[id] = nil
        recoveryCheckpointByConversation[id] = nil
        recoveredConversationIDs.remove(id)
        taskIDByConversation[id] = nil
        runIDByConversation[id] = nil
        enabledSkillIDsByConversation[id] = nil
        compactionByConversation[id] = nil
        durableArtifactsByConversation[id] = nil
        queuedSubmissions[id] = nil

        if selectedConversationID == id {
            if let removedTabIndex, openConversationIDs.indices.contains(removedTabIndex) {
                selectConversationID(openConversationIDs[removedTabIndex])
            } else if let openID = openConversationIDs.last {
                selectConversationID(openID)
            } else {
                selectConversationID(conversations.first?.id)
                if let selectedConversationID { openConversationIDs = [selectedConversationID] }
            }
        }
        schedulePersistence()
        activateSelectedModelIfNeeded()
        if let taskID {
            Task { try? await harnessStore.deleteTask(taskID) }
        }
    }

    func addFolder() {
        folders.append(ConversationFolder(name: "New Folder"))
        schedulePersistence()
    }

    func renameFolder(_ id: UUID, to name: String) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { folders[index].name = trimmed }
        schedulePersistence()
    }

    func deleteFolder(_ id: UUID) {
        for index in conversations.indices where conversations[index].folderID == id {
            conversations[index].folderID = nil
        }
        folders.removeAll { $0.id == id }
        schedulePersistence()
    }

    func moveConversation(_ conversationID: UUID, to folderID: UUID?) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        conversations[index].folderID = folderID
        schedulePersistence()
    }

    func togglePin(_ conversationID: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        conversations[index].isPinned.toggle()
        schedulePersistence()
    }

    func reorderFolders(from offsets: IndexSet, to destination: Int) {
        folders = Self.moving(folders, from: offsets, to: destination)
        schedulePersistence()
    }

    func reorderConversations(_ visibleIDs: [UUID], from offsets: IndexSet, to destination: Int) {
        let reorderedIDs = Self.moving(visibleIDs, from: offsets, to: destination)
        let visibleIDSet = Set(visibleIDs)
        let conversationsByID = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0) })
        var reordered = reorderedIDs.makeIterator()
        for index in conversations.indices where visibleIDSet.contains(conversations[index].id) {
            guard let id = reordered.next(), let conversation = conversationsByID[id] else { continue }
            conversations[index] = conversation
        }
        schedulePersistence()
    }

    private static func moving<Element>(
        _ elements: [Element],
        from offsets: IndexSet,
        to destination: Int
    ) -> [Element] {
        let selected = offsets.sorted().map { elements[$0] }
        var remainder = elements
        for offset in offsets.sorted(by: >) { remainder.remove(at: offset) }
        let removedBeforeDestination = offsets.filter { $0 < destination }.count
        let insertionIndex = min(max(0, destination - removedBeforeDestination), remainder.count)
        remainder.insert(contentsOf: selected, at: insertionIndex)
        return remainder
    }

    private func selectConversationID(_ id: UUID?) {
        if selectedConversationID != id, let selectedConversationID {
            queuedSubmissions[selectedConversationID] = nil
        }
        selectedConversationID = id
        enabledSkillIDs = id.flatMap { enabledSkillIDsByConversation[$0] } ?? []
    }

    func loadModel(from url: URL, for profile: ModelProfile = .deep) {
        modelURLs[profile] = url
        requestedModelLoad = ModelLoadRequest(profile: profile, conversationID: selectedConversationID)
        loadingModelProfile = profile
        modelPhase = .loading
        guard modelLoadTask == nil else { return }
        modelLoadTask = Task { [weak self] in
            await self?.processModelLoads()
        }
    }

    private func processModelLoads() async {
        while let request = requestedModelLoad {
            requestedModelLoad = nil
            let profile = request.profile
            guard let url = modelURLs[profile] else { continue }
            let previousProfile = activeModelProfile
            let previousURL = modelURL
            loadingModelProfile = profile
            modelPhase = .loading
            do {
                let loadStartedAt = ContinuousClock().now
                try await modelService.load(resourcesAt: url, for: profile)
                lastModelLoadDuration = loadStartedAt.duration(to: ContinuousClock().now)
                activeModelProfile = profile
                modelURL = url
                if requestedModelLoad?.profile == profile {
                    requestedModelLoad = nil
                }
                if requestedModelLoad == nil {
                    loadingModelProfile = nil
                    modelPhase = .ready
                    if modelSelectionNotice?.hasPrefix("Loading ") == true {
                        modelSelectionNotice = nil
                    }
                    activateSelectedModelIfNeeded()
                    sendQueuedSubmissionIfReady()
                }
            } catch {
                if requestedModelLoad == nil {
                    loadingModelProfile = nil
                    activeModelProfile = previousProfile
                    modelURL = previousURL
                    cancelQueuedSubmissions(for: profile)
                    if let previousProfile {
                        if let conversationID = request.conversationID,
                           let index = conversations.firstIndex(where: { $0.id == conversationID }),
                           conversations[index].modelProfile == profile {
                            conversations[index].modelProfile = previousProfile
                            conversations[index].reasoningEnabled = previousProfile.defaultReasoningEnabled
                            conversations[index].updatedAt = .now
                            schedulePersistence()
                        }
                        modelPhase = .ready
                        modelSelectionNotice = "Could not load \(profile.modelName): \(error.localizedDescription)"
                    } else {
                        modelPhase = .failed(error.localizedDescription)
                    }
                }
            }
        }
        modelLoadTask = nil
    }

    func selectModelProfile(_ profile: ModelProfile) {
        guard profile != selectedModelProfile,
              modelPhase != .generating, modelPhase != .compacting,
              let index = selectedIndex else { return }
        guard let url = modelURLs[profile] else {
            modelSelectionNotice = "\(profile.modelName) is not bundled in this build."
            return
        }
        cancelQueuedSubmission(in: conversations[index].id)
        conversations[index].modelProfile = profile
        conversations[index].reasoningEnabled = profile.defaultReasoningEnabled
        conversations[index].updatedAt = .now
        modelSelectionNotice = "Loading \(profile.modelName)…"
        schedulePersistence()
        loadModel(from: url, for: profile)
    }

    func setFastReasoningEnabled(_ enabled: Bool) {
        guard selectedModelProfile == .fast, let index = selectedIndex else { return }
        conversations[index].reasoningEnabled = enabled
        conversations[index].updatedAt = .now
        schedulePersistence()
    }

    private func activateSelectedModelIfNeeded() {
        let profile = selectedModelProfile
        guard activeModelProfile != profile, modelPhase == .ready else { return }
        guard let url = modelURLs[profile] else {
            guard let activeModelProfile, let index = selectedIndex else {
                modelPhase = .missing
                modelSelectionNotice = "\(profile.modelName) is not bundled in this build."
                return
            }
            conversations[index].modelProfile = activeModelProfile
            conversations[index].reasoningEnabled = activeModelProfile.defaultReasoningEnabled
            modelSelectionNotice = "\(profile.modelName) is not bundled. Using \(activeModelProfile.modelName)."
            schedulePersistence()
            return
        }
        loadModel(from: url, for: profile)
    }

    func send() {
        let rawPrompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedID = selectedConversationID
        let pinnedSkills = selectedID.flatMap { enabledSkillIDsByConversation[$0] } ?? enabledSkillIDs
        guard !rawPrompt.isEmpty, !isAttachingFiles, let selectedID else { return }
        if !isSelectedModelReady {
            guard modelPhase == .loading else { return }
            guard queuedSubmissions[selectedID] == nil else { return }
            queuedSubmissions[selectedID] = QueuedSubmission(
                prompt: rawPrompt,
                attachments: draftAttachments,
                pinnedSkillIDs: pinnedSkills,
                modelProfile: selectedModelProfile
            )
            schedulePersistence()
            return
        }
        startSubmission(rawPrompt, attachments: draftAttachments, pinnedSkillIDs: pinnedSkills, in: selectedID)
    }

    private func startSubmission(
        _ rawPrompt: String,
        attachments: [ComposerAttachment],
        pinnedSkillIDs: Set<String>,
        in conversationID: UUID
    ) {
        guard selectedConversationID == conversationID, isSelectedModelReady,
              let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        let routing = SkillRouter().route(rawPrompt, availableSkills: availableSkills, pinnedSkillIDs: pinnedSkillIDs)
        let prompt = routing.prompt
        guard !prompt.isEmpty else { return }

        let attachmentContext = attachments.modelContext
        draft = ""
        draftAttachmentsByConversation[conversationID] = []
        let userMessage = ChatMessage(
            role: .user,
            text: prompt,
            attachmentContext: attachmentContext.isEmpty ? nil : attachmentContext
        )
        conversations[index].messages.append(userMessage)
        conversations[index].messages.append(ChatMessage(role: .assistant, text: "", generationState: .streaming))
        let shouldGenerateTitle = conversations[index].title == "New Chat"
        if shouldGenerateTitle {
            conversations[index].title = String(prompt.prefix(48))
        }
        conversations[index].updatedAt = .now
        schedulePersistence()
        let conversationID = conversations[index].id
        let generationProfile = conversations[index].modelProfile
        let generationReasoningEnabled = conversations[index].reasoningEnabled
        recoveredConversationIDs.remove(conversationID)
        let responseID = conversations[index].messages.last!.id
        let selectedSkillIDs = Set(routing.selectedSkillIDs.map(Self.canonicalSkillID))
        let skillContext = selectedSkillInstructions(for: selectedSkillIDs)
        let requestEnvelope = "<user_request>\n\(prompt)\n</user_request>"
        let modelPrompt = [skillContext, attachmentContext, requestEnvelope]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        generatingConversationID = conversationID
        generatingResponseID = responseID
        modelPhase = .generating
        let clock = ContinuousClock()
        let start = clock.now

        generationTask = Task {
            do {
                await harnessBootstrapTask?.value
                let run = try await prepareRun(for: conversationID)
                _ = try await harnessStore.append(
                    .statusChanged(.running),
                    to: run.id,
                    idempotencyKey: "run-start:\(responseID)",
                    timestamp: .now
                )
                runStatusByConversation[conversationID] = .running
                _ = try await harnessStore.append(
                    .userInput(messageID: userMessage.id, text: prompt),
                    to: run.id,
                    idempotencyKey: "user-message:\(userMessage.id)",
                    timestamp: userMessage.createdAt
                )
                _ = try await harnessStore.append(
                    .legacyMessage(userMessage),
                    to: run.id,
                    idempotencyKey: "user-message-with-context:\(userMessage.id)",
                    timestamp: userMessage.createdAt
                )
                _ = try await harnessStore.append(
                    .skillsChanged(selectedSkillIDs.sorted()),
                    to: run.id,
                    idempotencyKey: "skills:\(responseID)",
                    timestamp: .now
                )
                if let plan = durablePlan(for: conversationID) {
                    _ = try await harnessStore.append(
                        .planUpdated(plan),
                        to: run.id,
                        idempotencyKey: "plan:\(responseID)",
                        timestamp: .now
                    )
                }

                var finalMetrics: GenerationMetrics?
                var latestResponse = ""
                var wasCompacting = false
                var invocationsByExternalID = [String: ToolInvocation]()
                var generationAttemptID = responseID
                var hasStartedGenerationAttempt = false
                let request = ModelGenerationRequest(
                    conversationID: conversationID,
                    prompt: modelPrompt,
                    enabledSkillIDs: selectedSkillIDs,
                    history: modelHistory(for: conversationID, excluding: [userMessage.id, responseID]),
                    compaction: modelCompaction(for: conversationID),
                    userMessageID: userMessage.id,
                    assistantMessageID: responseID,
                    promptComponents: [
                        ContextPromptComponent(category: .systemAndMemory, text: skillContext),
                        ContextPromptComponent(category: .attachments, text: attachmentContext),
                        ContextPromptComponent(id: userMessage.id, category: .user, text: requestEnvelope),
                    ],
                    modelProfile: generationProfile,
                    reasoningEnabled: generationReasoningEnabled
                )
                for try await event in modelService.generate(request: request) {
                    guard !Task.isCancelled else { break }
                    switch event {
                    case .attemptStarted(let attemptID):
                        if hasStartedGenerationAttempt {
                            let abandoned = (toolActivitiesByConversation[conversationID] ?? []).filter {
                                $0.state == .running || $0.state == .waitingForApproval
                            }
                            failActiveToolActivities(
                                in: conversationID,
                                message: "The generation attempt ended before this tool completed."
                            )
                            for activity in abandoned {
                                _ = try await harnessStore.append(
                                    .toolCompleted(ToolResultRecord(
                                        invocationID: activity.id,
                                        content: "The generation attempt ended before this tool completed.",
                                        isError: true
                                    )),
                                    to: run.id,
                                    idempotencyKey: "tool-abandoned:\(activity.invocation.idempotencyKey)",
                                    timestamp: .now
                                )
                            }
                            invocationsByExternalID.removeAll()
                        }
                        generationAttemptID = attemptID
                        hasStartedGenerationAttempt = true
                    case .context(let context):
                        contextByConversation[conversationID] = context
                        updateMessage(responseID, in: conversationID) { $0.contextSnapshot = context }
                        modelPhase = context.state == .compacting ? .compacting : .generating
                        if context.state == .compacting, !wasCompacting {
                            wasCompacting = true
                            let compaction = compactionState(from: context, for: conversationID, phase: .summarizing)
                            compactionByConversation[conversationID] = compaction
                            _ = try await harnessStore.append(
                                .compactionUpdated(compaction),
                                to: run.id,
                                idempotencyKey: "compaction-start:\(responseID):\(context.compactionCount)",
                                timestamp: .now
                            )
                        } else if context.state != .compacting, wasCompacting {
                            wasCompacting = false
                            // Completion is committed only by `.compaction(snapshot)`, which carries
                            // the exact memory and source IDs. Context telemetry is not authoritative.
                        }
                    case .content(let update):
                        finalMetrics = update.metrics
                        latestResponse = update.text
                        kvCacheByConversation[conversationID] = update.kvCache
                        updateMessage(responseID, in: conversationID) {
                            $0.text = update.text
                            if let reasoning = update.reasoning {
                                $0.reasoning = reasoning
                            }
                            $0.metrics = update.metrics
                            $0.kvCacheSnapshot = update.kvCache
                        }
                        if let reasoning = update.reasoning {
                            executionTraceByMessage[responseID, default: AssistantExecutionTrace()]
                                .recordReasoningSnapshot(reasoning)
                        }
                        // Give AppKit a rendering opportunity between streamed
                        // snapshots instead of visually coalescing a whole turn.
                        await Task.yield()
                    case .agent(let lifecycle):
                        switch lifecycle {
                        case .reasoning(let reasoning):
                            executionTraceByMessage[responseID, default: AssistantExecutionTrace()]
                                .recordReasoningSegment(reasoning)
                        case .toolCall(let externalID, let name, let argumentsJSON):
                            let invocation = ToolInvocation(
                                id: ToolIdentity.uuid(
                                    forOpaqueID: externalID,
                                    scope: generationAttemptID.uuidString
                                ),
                                toolID: name,
                                argumentsJSON: argumentsJSON,
                                idempotencyKey: "tool:\(run.id):\(generationAttemptID):\(externalID)",
                                sideEffect: Self.sideEffect(forToolNamed: name)
                            )
                            invocationsByExternalID[externalID] = invocation
                            executionTraceByMessage[responseID, default: AssistantExecutionTrace()]
                                .recordTool(invocation.id)
                            _ = try await harnessStore.append(
                                .toolRequested(invocation),
                                to: run.id,
                                idempotencyKey: "tool-requested:\(invocation.idempotencyKey)",
                                timestamp: .now
                            )
                            if invocation.sideEffect == .none {
                                _ = try await harnessStore.append(
                                    .toolStarted(invocationID: invocation.id),
                                    to: run.id,
                                    idempotencyKey: "tool-started:\(invocation.idempotencyKey)",
                                    timestamp: .now
                                )
                            }
                            upsertToolActivity(
                                invocation,
                                state: .running,
                                result: nil,
                                in: conversationID
                            )
                            try await saveHarnessCheckpoint(
                                for: conversationID,
                                run: run,
                                pendingInvocations: Array(invocationsByExternalID.values)
                            )
                        case .toolOutput(let externalID, _, let content):
                            guard let invocation = invocationsByExternalID[externalID] else { continue }
                            _ = try await harnessStore.append(
                                .toolCompleted(ToolResultRecord(invocationID: invocation.id, content: content)),
                                to: run.id,
                                idempotencyKey: "tool-completed:\(invocation.idempotencyKey)",
                                timestamp: .now
                            )
                            let result = ToolResultRecord(invocationID: invocation.id, content: content)
                            upsertToolActivity(
                                invocation,
                                state: Self.isDegradedToolResult(content) ? .unavailable : .succeeded,
                                result: result,
                                in: conversationID
                            )
                            try await saveHarnessCheckpoint(
                                for: conversationID,
                                run: run,
                                completedIdempotencyKeys: [invocation.idempotencyKey],
                                pendingInvocations: invocationsByExternalID
                                    .filter { $0.key != externalID }
                                    .map(\.value)
                            )
                            invocationsByExternalID.removeValue(forKey: externalID)
                        case .artifact(let artifactEvent):
                            let artifact = AgentArtifact(
                                id: artifactEvent.id,
                                runID: run.id,
                                name: artifactEvent.title,
                                path: "",
                                mediaType: artifactEvent.mediaType,
                                inlineContent: artifactEvent.content,
                                contentHash: Self.contentHash(artifactEvent.content),
                                revision: artifactEvent.revision
                            )
                            _ = try await harnessStore.append(
                                .artifactCreated(artifact),
                                to: run.id,
                                idempotencyKey: "artifact:\(artifact.id):\(artifact.revision)",
                                timestamp: .now
                            )
                            durableArtifactsByConversation[conversationID, default: []].removeAll {
                                $0.id == artifact.id
                            }
                            durableArtifactsByConversation[conversationID, default: []].append(artifact)
                            artifactsByConversation[conversationID, default: []].removeAll {
                                $0.id == artifact.id
                            }
                            artifactsByConversation[conversationID, default: []].append(Self.uiArtifact(artifact))
                            try await saveHarnessCheckpoint(for: conversationID, run: run)
                        case .approvalRequested(let approvalEvent):
                            guard let invocation = invocationsByExternalID[approvalEvent.toolCallID] else { continue }
                            let request = TaskApprovalRequest(
                                id: approvalEvent.id,
                                title: approvalEvent.title,
                                explanation: approvalEvent.detail,
                                target: approvalEvent.target,
                                sendsDataOffDevice: true,
                                decision: .pending
                            )
                            approvalsByConversation[conversationID, default: []].removeAll { $0.id == request.id }
                            approvalsByConversation[conversationID, default: []].append(request)
                            approvalInvocationIDs[request.id] = invocation.id
                            let durable = durableApproval(request, invocationID: invocation.id)
                            _ = try await harnessStore.append(
                                .approvalRequested(durable),
                                to: run.id,
                                idempotencyKey: "approval-requested:\(approvalEvent.idempotencyKey)",
                                timestamp: durable.requestedAt
                            )
                            _ = try await harnessStore.append(
                                .statusChanged(.awaitingApproval),
                                to: run.id,
                                idempotencyKey: "awaiting-approval:\(approvalEvent.id)",
                                timestamp: durable.requestedAt
                            )
                            runStatusByConversation[conversationID] = .awaitingApproval
                            upsertToolActivity(invocation, state: .waitingForApproval, result: nil, in: conversationID)
                            try await saveHarnessCheckpoint(for: conversationID, run: run)
                        case .approvalResolved:
                            break
                        case .response:
                            break
                        }
                    case .compaction(let snapshot):
                        let compaction = StructuredCompactionState(
                            generation: snapshot.generation,
                            phase: .completed,
                            triggerTokenCount: snapshot.sourceTokenEstimate,
                            targetTokenCount: max(0, snapshot.sourceTokenEstimate / 2),
                            conversationMemory: snapshot.memory,
                            currentGoal: conversations.first(where: { $0.id == conversationID })?.title ?? "",
                            recentEventIDs: snapshot.retainedHistoryIDs,
                            retainedHistoryIDs: snapshot.retainedHistoryIDs,
                            sourceHistoryIDs: snapshot.sourceHistoryIDs,
                            sourceTokenEstimate: snapshot.sourceTokenEstimate
                        )
                        compactionByConversation[conversationID] = compaction
                        _ = try await harnessStore.append(
                            .compactionUpdated(compaction),
                            to: run.id,
                            idempotencyKey: "compaction:\(run.id):\(snapshot.generation)",
                            timestamp: .now
                        )
                        try await saveHarnessCheckpoint(for: conversationID, run: run)
                    }
                }
                guard !Task.isCancelled else { return }
                _ = start.duration(to: clock.now)
                lastMetrics = finalMetrics
                updateMessage(responseID, in: conversationID) { $0.generationState = .complete }
                _ = try await harnessStore.append(
                    .responseMessage(messageID: responseID, text: latestResponse),
                    to: run.id,
                    idempotencyKey: "response:\(responseID)",
                    timestamp: conversations.first(where: { $0.id == conversationID })?
                        .messages.first(where: { $0.id == responseID })?.createdAt ?? .now
                )
                _ = try await harnessStore.append(
                    .completed,
                    to: run.id,
                    idempotencyKey: "completed:\(responseID)",
                    timestamp: .now
                )
                runStatusByConversation[conversationID] = .completed
                if var steps = taskPlans[conversationID] {
                    for stepIndex in steps.indices where steps[stepIndex].state == .active {
                        steps[stepIndex].state = .complete
                    }
                    taskPlans[conversationID] = steps
                }
                try await saveHarnessCheckpoint(for: conversationID, run: run)
                generatingConversationID = nil
                generatingResponseID = nil
                modelPhase = .ready
                activateSelectedModelIfNeeded()
                // Persist final runtime telemetry with the assistant turn so
                // context/KV history survives a normal relaunch.
                schedulePersistence()
                if shouldGenerateTitle {
                    switch await titleService.generateTitle(for: prompt) {
                    case .generated(let generatedTitle):
                        titleGenerationFailuresByConversation[conversationID] = nil
                        if let conversationIndex = conversations.firstIndex(where: { $0.id == conversationID }) {
                            conversations[conversationIndex].title = generatedTitle
                            conversations[conversationIndex].updatedAt = .now
                            schedulePersistence()
                            await persistTaskTitle(for: conversationID, title: generatedTitle)
                        }
                    case .fallback(let failure):
                        titleGenerationFailuresByConversation[conversationID] = failure
                    }
                }
            } catch {
                let failedAt = Date.now
                let pendingIDs = (approvalsByConversation[conversationID] ?? [])
                    .filter { $0.decision == .pending }.map(\.id)
                for approvalID in pendingIDs {
                    _ = await persistApprovalDecision(
                        approvalID, in: conversationID, decision: .denied, resolvedAt: failedAt)
                    if let index = approvalsByConversation[conversationID]?
                        .firstIndex(where: { $0.id == approvalID }) {
                        approvalsByConversation[conversationID]?[index].decision = .denied
                    }
                    _ = await modelService.resolveApproval(id: approvalID, approved: false)
                }
                failActiveToolActivities(in: conversationID, message: Self.friendlyGenerationError(error))
                updateMessage(responseID, in: conversationID) { message in
                    message.text = message.text.isEmpty
                        ? "Generation failed: \(Self.friendlyGenerationError(error))"
                        : message.text
                    message.generationState = .failed
                }
                generatingConversationID = nil
                generatingResponseID = nil
                modelPhase = .ready
                activateSelectedModelIfNeeded()
                if let runID = runIDByConversation[conversationID] {
                    _ = try? await harnessStore.append(
                        .failed(message: error.localizedDescription, retryable: true),
                        to: runID,
                        idempotencyKey: "failed:\(responseID)",
                        timestamp: .now
                    )
                    runStatusByConversation[conversationID] = .failed
                    await saveCurrentHarnessCheckpoint(for: conversationID)
                }
            }
        }
    }

    private func sendQueuedSubmissionIfReady() {
        guard let conversationID = selectedConversationID,
              isSelectedModelReady,
              let queued = queuedSubmissions[conversationID],
              queued.modelProfile == selectedModelProfile else { return }
        queuedSubmissions[conversationID] = nil
        startSubmission(
            queued.prompt,
            attachments: queued.attachments,
            pinnedSkillIDs: queued.pinnedSkillIDs,
            in: conversationID
        )
    }

    func cancelQueuedSubmission() {
        guard let conversationID = selectedConversationID else { return }
        cancelQueuedSubmission(in: conversationID)
    }

    private func cancelQueuedSubmission(in conversationID: UUID) {
        guard queuedSubmissions.removeValue(forKey: conversationID) != nil else { return }
        schedulePersistence()
    }

    private func cancelQueuedSubmissions(for profile: ModelProfile) {
        let queuedIDs = queuedSubmissions.compactMap { id, submission in
            submission.modelProfile == profile ? id : nil
        }
        guard !queuedIDs.isEmpty else { return }
        for id in queuedIDs { queuedSubmissions[id] = nil }
        schedulePersistence()
    }

    func stop() {
        let stoppedConversationID = generatingConversationID
        generationTask?.cancel()
        generationTask = nil
        if let conversationID = generatingConversationID, let responseID = generatingResponseID {
            updateMessage(responseID, in: conversationID) {
                $0.wasStopped = true
                $0.generationState = .stopped
            }
            let pendingIDs = (approvalsByConversation[conversationID] ?? [])
                .filter { $0.decision == .pending }.map(\.id)
            for approvalID in pendingIDs {
                if let index = approvalsByConversation[conversationID]?
                    .firstIndex(where: { $0.id == approvalID }) {
                    approvalsByConversation[conversationID]?[index].decision = .denied
                }
                Task { _ = await modelService.resolveApproval(id: approvalID, approved: false) }
            }
            failActiveToolActivities(in: conversationID, message: "Stopped by the user.")
        }
        generatingConversationID = nil
        generatingResponseID = nil
        Task { await modelService.cancel() }
        if let conversationID = stoppedConversationID,
           let runID = runIDByConversation[conversationID] {
            Task {
                _ = try? await harnessStore.append(
                    .cancelled,
                    to: runID,
                    idempotencyKey: "cancelled:\(runID)",
                    timestamp: .now
                )
                runStatusByConversation[conversationID] = .cancelled
                await saveCurrentHarnessCheckpoint(for: conversationID)
            }
        }
        modelPhase = .ready
        activateSelectedModelIfNeeded()
    }

    private func updateMessage(_ id: UUID, in conversationID: UUID, update: (inout ChatMessage) -> Void) {
        guard let conversationIndex = conversations.firstIndex(where: { $0.id == conversationID }),
              let messageIndex = conversations[conversationIndex].messages.firstIndex(where: { $0.id == id }) else { return }
        update(&conversations[conversationIndex].messages[messageIndex])
        schedulePersistence()
    }

    func waitForHarnessBootstrap() async {
        await harnessBootstrapTask?.value
    }

    func recordApprovalRequest(
        _ request: TaskApprovalRequest,
        invocationID: UUID,
        in conversationID: UUID
    ) async {
        approvalsByConversation[conversationID, default: []].append(request)
        approvalInvocationIDs[request.id] = invocationID
        guard let run = try? await currentOrCreateRun(for: conversationID, initialStatus: .awaitingApproval) else { return }
        let record = durableApproval(request, invocationID: invocationID)
        let projection = try? await harnessStore.projection(for: run.id)
        if projection?.pendingInvocations.contains(where: { $0.id == invocationID }) != true {
            let invocation = ToolInvocation(
                id: invocationID,
                toolID: "external.approval",
                argumentsJSON: "{}",
                idempotencyKey: "external-approval:\(invocationID)",
                sideEffect: request.sendsDataOffDevice ? .networkRead : .localWrite
            )
            _ = try? await harnessStore.append(
                .toolRequested(invocation),
                to: run.id,
                idempotencyKey: "tool-requested:\(invocation.idempotencyKey)",
                timestamp: record.requestedAt
            )
        }
        _ = try? await harnessStore.append(
            .approvalRequested(record),
            to: run.id,
            idempotencyKey: "approval-requested:\(request.id)",
            timestamp: record.requestedAt
        )
        _ = try? await harnessStore.append(
            .statusChanged(.awaitingApproval),
            to: run.id,
            idempotencyKey: "awaiting-approval:\(request.id)",
            timestamp: record.requestedAt
        )
        try? await saveHarnessCheckpoint(for: conversationID, run: run)
    }

    func recordArtifact(_ artifact: TaskArtifact, in conversationID: UUID) async {
        artifactsByConversation[conversationID, default: []].append(artifact)
        guard let run = try? await currentOrCreateRun(for: conversationID, initialStatus: .running) else { return }
        let record = durableArtifact(artifact, runID: run.id)
        durableArtifactsByConversation[conversationID, default: []].removeAll { $0.id == record.id }
        durableArtifactsByConversation[conversationID, default: []].append(record)
        _ = try? await harnessStore.append(
            .artifactCreated(record),
            to: run.id,
            idempotencyKey: "artifact:\(artifact.id):\(record.revision)",
            timestamp: .now
        )
        try? await saveHarnessCheckpoint(for: conversationID, run: run)
    }

    func saveMarkdownArtifact(
        _ artifactID: UUID,
        in conversationID: UUID,
        to destination: URL
    ) async throws {
        guard destination.isFileURL,
              destination.pathExtension.lowercased() == "md" else {
            throw ArtifactSaveError.markdownDestinationRequired
        }
        guard let index = artifactsByConversation[conversationID]?.firstIndex(where: { $0.id == artifactID }),
              let content = artifactsByConversation[conversationID]?[index].content else {
            throw ArtifactSaveError.missingDraft
        }

        try Data(content.utf8).write(to: destination, options: .atomic)
        artifactsByConversation[conversationID]?[index].fileURL = destination

        guard let run = try? await currentOrCreateRun(for: conversationID, initialStatus: .running) else { return }
        var durable = durableArtifactsByConversation[conversationID]?.first(where: { $0.id == artifactID })
            ?? durableArtifact(artifactsByConversation[conversationID]![index], runID: run.id)
        durable.path = destination.path
        durable.inlineContent = content
        durable.contentHash = Self.contentHash(content)
        durableArtifactsByConversation[conversationID, default: []].removeAll { $0.id == artifactID }
        durableArtifactsByConversation[conversationID, default: []].append(durable)
        _ = try await harnessStore.append(
            .artifactCreated(durable),
            to: run.id,
            idempotencyKey: "artifact-saved:\(artifactID):\(durable.revision):\(durable.contentHash ?? "")",
            timestamp: .now
        )
        try await saveHarnessCheckpoint(for: conversationID, run: run)
    }

    private func bootstrapHarness(from legacyState: PersistedAppState?) async {
        do {
            if let legacyState {
                _ = try await harnessStore.migrateLegacyConversations(from: legacyState, workspaceID: nil)
            }
            var index = try await harnessStore.loadIndex()
            let recovered = try await recoverConversations(from: index)
            if !recovered.isEmpty {
                mergeRecoveredConversations(recovered)
                if legacyState == nil {
                    openConversationIDs = recovered.map(\.id)
                    selectedConversationID = recovered.first?.id
                    persistenceRecoveryNotice = persistenceRecoveryNotice
                        ?? "Recovered chats from durable agent history."
                }
            }
            for task in index.tasks {
                guard let conversationID = task.legacyConversationID,
                      conversations.contains(where: { $0.id == conversationID }) else { continue }
                taskIDByConversation[conversationID] = task.id
                // Runs are append-only in creation order. Prefer the last matching run rather than
                // comparing ISO-8601 timestamps, whose persisted precision may be one second.
                if let run = index.runs.last(where: { $0.taskID == task.id }) {
                    if [.preparing, .running, .compacting, .awaitingApproval].contains(run.status) {
                        if run.status == .awaitingApproval {
                            let orphaned = try await harnessStore.projection(for: run.id)
                            let cancelledAt = Date.now
                            for approval in orphaned.approvals where approval.decision == .pending {
                                _ = try await harnessStore.append(
                                    .approvalResolved(approvalID: approval.id, decision: .rejected),
                                    to: run.id,
                                    idempotencyKey: "recovery-rejected:\(approval.id)",
                                    timestamp: cancelledAt
                                )
                            }
                            for invocation in orphaned.pendingInvocations {
                                _ = try await harnessStore.append(
                                    .toolCompleted(ToolResultRecord(
                                        invocationID: invocation.id,
                                        content: "Cancelled because the app restarted before approval.",
                                        isError: true,
                                        completedAt: cancelledAt
                                    )),
                                    to: run.id,
                                    idempotencyKey: "recovery-cancelled-tool:\(invocation.id)",
                                    timestamp: cancelledAt
                                )
                            }
                        }
                        _ = try await harnessStore.append(
                            .statusChanged(.suspended),
                            to: run.id,
                            idempotencyKey: "recovery-suspended:\(run.id)",
                            timestamp: .now
                        )
                        index = try await harnessStore.loadIndex()
                        persistenceRecoveryNotice = "An interrupted run was recovered as suspended. Continuing starts a new run from its saved context; partial generation is not resumed."
                    }
                    runIDByConversation[conversationID] = run.id
                    let events = try await harnessStore.events(for: run.id)
                    let projection = try await harnessStore.projection(for: run.id)
                    runStatusByConversation[conversationID] = projection.status
                    restoreToolActivities(events, for: conversationID)
                    if let checkpoint = try await harnessStore.latestCheckpoint(for: run.id) {
                        recoveryCheckpointByConversation[conversationID] = checkpoint
                        if projection.status == .suspended {
                            recoveredConversationIDs.insert(conversationID)
                        }
                        restore(checkpoint, for: conversationID)
                    }
                    restore(projection, for: conversationID)
                }
            }
            if let selectedConversationID {
                enabledSkillIDs = enabledSkillIDsByConversation[selectedConversationID] ?? []
            }
        } catch {
            persistenceRecoveryNotice = "Durable task history could not be fully restored: \(error.localizedDescription)"
        }
    }

    private func recoverConversations(from index: HarnessIndex) async throws -> [Conversation] {
        var recovered = [Conversation]()
        for task in index.tasks where task.legacyConversationID != nil {
            guard let conversationID = task.legacyConversationID else { continue }
            var messages = [ChatMessage]()
            for run in index.runs.filter({ $0.taskID == task.id }) {
                if let checkpoint = try await harnessStore.latestCheckpoint(for: run.id) {
                    var checkpointMessages = [ChatMessage]()
                    for entry in checkpoint.transcript {
                        switch entry.kind {
                        case .reasoning:
                            // Decode compatibility only. Private reasoning is never rehydrated.
                            continue
                        case .user:
                            checkpointMessages.append(ChatMessage(
                                id: entry.id, role: .user, text: entry.content,
                                createdAt: entry.createdAt ?? checkpoint.createdAt
                            ))
                        case .assistant:
                            checkpointMessages.append(ChatMessage(
                                id: entry.id,
                                role: .assistant,
                                text: entry.content,
                                generationState: .complete,
                                createdAt: entry.createdAt ?? checkpoint.createdAt
                            ))
                        default:
                            continue
                        }
                    }
                    // Every committed checkpoint is a complete transcript projection. A newer
                    // checkpoint supersedes the older projection before subsequent events merge.
                    messages = checkpointMessages
                }
                for event in try await harnessStore.events(for: run.id) {
                    switch event.payload {
                    case .legacyMessage(let message):
                        messages.removeAll { $0.id == message.id }
                        messages.append(message)
                    case .userInput(let messageID, let text):
                        messages.removeAll { $0.id == messageID }
                        messages.append(ChatMessage(
                            id: messageID, role: .user, text: text, createdAt: event.timestamp
                        ))
                    case .reasoningMessage:
                        // Decode compatibility only. Old private reasoning is intentionally ignored.
                        continue
                    case .responseMessage(let messageID, let text):
                        messages.removeAll { $0.id == messageID }
                        messages.append(ChatMessage(
                            id: messageID,
                            role: .assistant,
                            text: text,
                            generationState: .complete,
                            createdAt: event.timestamp
                        ))
                    default:
                        break
                    }
                }
            }
            recovered.append(Conversation(
                id: conversationID,
                title: task.title,
                messages: messages,
                isPinned: false
            ))
        }
        return recovered.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func mergeRecoveredConversations(_ recovered: [Conversation]) {
        for durable in recovered {
            if let index = conversations.firstIndex(where: { $0.id == durable.id }) {
                var messages = Dictionary(uniqueKeysWithValues: conversations[index].messages.map { ($0.id, $0) })
                for var message in durable.messages {
                    if message.attachmentContext == nil {
                        message.attachmentContext = messages[message.id]?.attachmentContext
                    }
                    messages[message.id] = message
                }
                conversations[index].messages = messages.values.sorted { $0.createdAt < $1.createdAt }
                if conversations[index].title == "New Chat" { conversations[index].title = durable.title }
            } else {
                conversations.append(durable)
            }
        }
        conversations.sort { $0.updatedAt > $1.updatedAt }
    }

    private func ensureTask(for conversationID: UUID) async throws -> AgentTaskRecord {
        if let taskID = taskIDByConversation[conversationID],
           let existing = try await harnessStore.loadIndex().tasks.first(where: { $0.id == taskID }) {
            return existing
        }
        guard let conversation = conversations.first(where: { $0.id == conversationID }) else {
            throw HarnessStoreError.missingTask(conversationID)
        }
        let task = AgentTaskRecord(
            legacyConversationID: conversationID,
            title: conversation.title,
            createdAt: conversation.messages.map(\.createdAt).min() ?? conversation.updatedAt,
            updatedAt: conversation.updatedAt
        )
        _ = try await harnessStore.createTask(task)
        taskIDByConversation[conversationID] = task.id
        return task
    }

    private func prepareRun(for conversationID: UUID) async throws -> AgentRunRecord {
        let run = try await currentOrCreateRun(for: conversationID, initialStatus: .preparing)
        _ = try await harnessStore.append(
            .statusChanged(.preparing),
            to: run.id,
            idempotencyKey: nil,
            timestamp: .now
        )
        return run
    }

    private func currentOrCreateRun(
        for conversationID: UUID,
        initialStatus: AgentRunStatus
    ) async throws -> AgentRunRecord {
        await harnessBootstrapTask?.value
        let task = try await ensureTask(for: conversationID)
        let run = try await harnessStore.currentOrCreateRun(
            taskID: task.id,
            initialStatus: initialStatus
        )
        runIDByConversation[conversationID] = run.id
        runStatusByConversation[conversationID] = run.status
        return run
    }

    private func saveCurrentHarnessCheckpoint(for conversationID: UUID) async {
        guard let runID = runIDByConversation[conversationID],
              let run = try? await harnessStore.loadIndex().runs.first(where: { $0.id == runID }) else { return }
        try? await saveHarnessCheckpoint(for: conversationID, run: run)
    }

    private func saveHarnessCheckpoint(
        for conversationID: UUID,
        run: AgentRunRecord,
        completedIdempotencyKeys newCompletedKeys: [String] = [],
        pendingInvocations: [ToolInvocation]? = nil
    ) async throws {
        let index = try await harnessStore.loadIndex()
        guard let currentRun = index.runs.first(where: { $0.id == run.id }) else { return }
        let previous = try await harnessStore.latestCheckpoint(for: run.id)
        let projection = try await harnessStore.projection(for: run.id)
        let completedKeys = Array(Set(
            (previous?.completedIdempotencyKeys ?? [])
                + projection.completedIdempotencyKeys
                + newCompletedKeys
        )).sorted()
        let conversation = conversations.first(where: { $0.id == conversationID })
        let transcript = conversation?.messages.flatMap { message -> [HarnessTranscriptEntry] in
            [.init(
                id: message.id,
                kind: message.role == .user ? .user : .assistant,
                content: message.text,
                createdAt: message.createdAt
            )]
        } ?? []
        let approvals = (approvalsByConversation[conversationID] ?? []).map {
            durableApproval($0, invocationID: approvalInvocationIDs[$0.id] ?? $0.id)
        }
        let artifacts = durableArtifactsByConversation[conversationID]
            ?? (artifactsByConversation[conversationID] ?? []).map { durableArtifact($0, runID: run.id) }
        let checkpoint = AgentRunCheckpoint(
            runID: run.id,
            sequence: currentRun.lastSequence,
            resumeKey: run.resumeKey,
            transcript: transcript,
            plan: durablePlan(for: conversationID),
            pendingApprovals: approvals,
            pendingInvocations: pendingInvocations ?? projection.pendingInvocations,
            completedIdempotencyKeys: completedKeys,
            artifacts: artifacts,
            selectedSkillIDs: projection.selectedSkillIDs.sorted(),
            compaction: compactionByConversation[conversationID] ?? projection.compaction
        )
        _ = try await harnessStore.saveCheckpoint(checkpoint)
        recoveryCheckpointByConversation[conversationID] = checkpoint
    }

    private func restore(_ checkpoint: AgentRunCheckpoint, for conversationID: UUID) {
        if let plan = checkpoint.plan {
            taskPlans[conversationID] = plan.steps.map {
                TaskPlanStep(id: $0.id, title: $0.title, state: Self.uiPlanState($0.status))
            }
        }
        compactionByConversation[conversationID] = checkpoint.compaction
        approvalsByConversation[conversationID] = checkpoint.pendingApprovals.map { approval in
            approvalInvocationIDs[approval.id] = approval.invocationID
            return TaskApprovalRequest(
                id: approval.id,
                title: approval.title,
                explanation: approval.detail,
                target: approval.target,
                sendsDataOffDevice: approval.sendsDataOffDevice,
                decision: Self.uiApprovalDecision(approval.decision)
            )
        }
        artifactsByConversation[conversationID] = checkpoint.artifacts.map(Self.uiArtifact)
        durableArtifactsByConversation[conversationID] = checkpoint.artifacts
    }

    private func restore(_ projection: AgentRunProjection, for conversationID: UUID) {
        if let plan = projection.plan {
            taskPlans[conversationID] = plan.steps.map {
                TaskPlanStep(id: $0.id, title: $0.title, state: Self.uiPlanState($0.status))
            }
        }
        compactionByConversation[conversationID] = projection.compaction
        approvalsByConversation[conversationID] = projection.approvals.map { approval in
            approvalInvocationIDs[approval.id] = approval.invocationID
            return TaskApprovalRequest(
                id: approval.id,
                title: approval.title,
                explanation: approval.detail,
                target: approval.target,
                sendsDataOffDevice: approval.sendsDataOffDevice,
                decision: Self.uiApprovalDecision(approval.decision)
            )
        }
        durableArtifactsByConversation[conversationID] = projection.artifacts
        artifactsByConversation[conversationID] = projection.artifacts.map(Self.uiArtifact)
    }

    private func restoreToolActivities(_ events: [AgentRunEvent], for conversationID: UUID) {
        var activities = [UUID: ToolActivityPresentation]()
        for event in events {
            switch event.payload {
            case .toolRequested(let invocation):
                activities[invocation.id] = ToolActivityPresentation(
                    invocation: invocation,
                    state: .requested,
                    result: nil,
                    requestedAt: event.timestamp,
                    completedAt: nil
                )
            case .toolStarted(let invocationID):
                guard let existing = activities[invocationID] else { continue }
                activities[invocationID] = ToolActivityPresentation(
                    invocation: existing.invocation,
                    state: .running,
                    result: nil,
                    requestedAt: existing.requestedAt,
                    completedAt: nil
                )
            case .toolCompleted(let result):
                guard let existing = activities[result.invocationID] else { continue }
                activities[result.invocationID] = ToolActivityPresentation(
                    invocation: existing.invocation,
                    state: result.isError ? .failed : Self.isDegradedToolResult(result.content) ? .unavailable : .succeeded,
                    result: result,
                    requestedAt: existing.requestedAt,
                    completedAt: result.completedAt
                )
            case .approvalRequested(let approval):
                guard let existing = activities[approval.invocationID] else { continue }
                activities[approval.invocationID] = ToolActivityPresentation(
                    invocation: existing.invocation,
                    state: .waitingForApproval,
                    result: existing.result,
                    requestedAt: existing.requestedAt,
                    completedAt: existing.completedAt
                )
            default:
                continue
            }
        }
        toolActivitiesByConversation[conversationID] = activities.values.sorted {
            $0.requestedAt < $1.requestedAt
        }
    }

    private func upsertToolActivity(
        _ invocation: ToolInvocation,
        state: ToolActivityState,
        result: ToolResultRecord?,
        in conversationID: UUID
    ) {
        var activities = toolActivitiesByConversation[conversationID] ?? []
        let previous = activities.first(where: { $0.id == invocation.id })
        let activity = ToolActivityPresentation(
            invocation: invocation,
            state: state,
            result: result,
            requestedAt: previous?.requestedAt ?? .now,
            completedAt: result?.completedAt
        )
        if let index = activities.firstIndex(where: { $0.id == invocation.id }) {
            activities[index] = activity
        } else {
            activities.append(activity)
        }
        toolActivitiesByConversation[conversationID] = activities
    }

    private func failActiveToolActivities(in conversationID: UUID, message: String) {
        guard let activities = toolActivitiesByConversation[conversationID] else { return }
        toolActivitiesByConversation[conversationID] = activities.map { activity in
            switch activity.state {
            case .running, .waitingForApproval:
                break
            default:
                return activity
            }
            return ToolActivityPresentation(
                invocation: activity.invocation,
                state: .failed,
                result: ToolResultRecord(
                    invocationID: activity.invocation.id,
                    content: message,
                    isError: true
                ),
                requestedAt: activity.requestedAt,
                completedAt: .now
            )
        }
    }

    private static func friendlyGenerationError(_ error: any Error) -> String {
        let description = error.localizedDescription
        if description.localizedCaseInsensitiveContains("mime type") {
            return "Web search returned an unsupported response format. Please try again."
        }
        if description.localizedCaseInsensitiveContains("invoking the tool") {
            return "A tool could not complete its work. Expand the failed activity for details, then try again."
        }
        if description.localizedCaseInsensitiveContains("parse generated content") {
            return "The model produced an incomplete response. Please try again."
        }
        return "The request could not be completed. Please try again."
    }

    private static func isDegradedToolResult(_ content: String) -> Bool {
        content.contains("<web_search_status outcome=\"temporarily_unavailable\"")
    }

    private func persistTaskTitle(for conversationID: UUID, title: String) async {
        guard var task = try? await ensureTask(for: conversationID) else { return }
        task.title = title
        task.updatedAt = .now
        _ = try? await harnessStore.upsertTask(task)
    }

    private func persistApprovalDecision(
        _ approvalID: UUID,
        in conversationID: UUID,
        decision: TaskApprovalRequest.Decision,
        resolvedAt: Date
    ) async -> Bool {
        await harnessBootstrapTask?.value
        guard let runID = runIDByConversation[conversationID] else { return false }
        guard let persistedRun = try? await harnessStore.loadIndex().runs.first(where: { $0.id == runID }),
              persistedRun.status != .completed,
              persistedRun.status != .cancelled,
              persistedRun.status != .failed else { return false }
        guard let approval = try? await harnessStore.projection(for: runID).approvals.first(where: { $0.id == approvalID }),
              approval.decision == .pending else { return false }
        do {
            _ = try await harnessStore.append(
                .approvalResolved(approvalID: approvalID, decision: Self.durableApprovalDecision(decision)),
                to: runID,
                idempotencyKey: "approval-resolved:\(approvalID)",
                timestamp: resolvedAt
            )
            return true
        } catch {
            return false
        }
    }

    private func persistApprovalOutcomeStatus(
        _ approvalID: UUID,
        in conversationID: UUID,
        shouldRun: Bool,
        timestamp: Date
    ) async {
        guard let runID = runIDByConversation[conversationID] else { return }
        let nextStatus: AgentRunStatus = shouldRun ? .running : .suspended
        do {
            _ = try await harnessStore.append(
                .statusChanged(nextStatus),
                to: runID,
                idempotencyKey: "approval-status:\(approvalID)",
                timestamp: timestamp
            )
            runStatusByConversation[conversationID] = nextStatus
            if let run = try await harnessStore.loadIndex().runs.first(where: { $0.id == runID }) {
                try await saveHarnessCheckpoint(for: conversationID, run: run)
            }
        } catch {
            persistenceRecoveryNotice = "The permission decision was saved, but its run state could not be finalized."
        }
    }

    private func durablePlan(for conversationID: UUID) -> AgentPlan? {
        guard let steps = taskPlans[conversationID], !steps.isEmpty else { return nil }
        return AgentPlan(steps: steps.map {
            AgentPlanStep(id: $0.id, title: $0.title, status: Self.durablePlanState($0.state))
        })
    }

    private func durableApproval(
        _ approval: TaskApprovalRequest,
        invocationID: UUID
    ) -> ApprovalRequestRecord {
        ApprovalRequestRecord(
            id: approval.id,
            invocationID: invocationID,
            title: approval.title,
            detail: approval.explanation,
            target: approval.target,
            sendsDataOffDevice: approval.sendsDataOffDevice,
            decision: Self.durableApprovalDecision(approval.decision),
            resolvedAt: approval.decision == .pending ? nil : .now
        )
    }

    private func durableArtifact(_ artifact: TaskArtifact, runID: UUID) -> AgentArtifact {
        if let existing = durableArtifactsByConversation.values
            .flatMap({ $0 })
            .first(where: { $0.id == artifact.id }) {
            return existing
        }
        let fingerprint = "\(artifact.title)\n\(artifact.detail)\n\(artifact.fileURL?.path ?? "")"
        return AgentArtifact(
            id: artifact.id,
            runID: runID,
            name: artifact.title,
            path: artifact.fileURL?.path ?? "",
            mediaType: Self.mediaType(for: artifact.kind),
            contentHash: Self.contentHash(fingerprint),
            revision: artifact.revision,
            createdAt: .now
        )
    }

    private func compactionState(
        from context: ContextStatus,
        for conversationID: UUID,
        phase: CompactionPhase
    ) -> StructuredCompactionState {
        StructuredCompactionState(
            generation: context.compactionCount,
            phase: phase,
            triggerTokenCount: context.usedTokens,
            targetTokenCount: context.activeBudget,
            conversationMemory: compactionByConversation[conversationID]?.conversationMemory ?? "",
            currentGoal: conversations.first(where: { $0.id == conversationID })?.title ?? "",
            decisions: compactionByConversation[conversationID]?.decisions ?? [],
            unresolvedItems: compactionByConversation[conversationID]?.unresolvedItems ?? []
        )
    }

    private func modelHistory(for conversationID: UUID, excluding excludedIDs: Set<UUID>) -> [ModelHistoryItem] {
        let messages = conversations.first(where: { $0.id == conversationID })?.messages ?? []
        var history = [ModelHistoryItem]()
        var currentTurnID: UUID?
        for message in messages {
            if message.role == .user { currentTurnID = message.id }
            guard !excludedIDs.contains(message.id), !message.text.isEmpty,
                  message.generationState != .failed else { continue }
            history.append(ModelHistoryItem(
                id: message.id,
                kind: message.role == .user ? .user : .assistant,
                content: [message.attachmentContext, message.text].compactMap { $0 }.joined(separator: "\n\n"),
                turnID: currentTurnID
            ))
        }
        return history
    }

    private func modelCompaction(for conversationID: UUID) -> ModelCompactionSnapshot? {
        guard let compaction = compactionByConversation[conversationID],
              compaction.phase == .completed,
              !compaction.conversationMemory.isEmpty else { return nil }
        return ModelCompactionSnapshot(
            generation: compaction.generation,
            memory: compaction.conversationMemory,
            retainedHistoryIDs: compaction.retainedHistoryIDs,
            sourceHistoryIDs: compaction.sourceHistoryIDs,
            sourceTokenEstimate: compaction.sourceTokenEstimate
        )
    }

    private static func durablePlanState(_ state: TaskPlanStep.State) -> PlanStepStatus {
        switch state {
        case .pending: .pending
        case .active: .inProgress
        case .complete: .completed
        case .blocked: .blocked
        }
    }

    private static func uiPlanState(_ state: PlanStepStatus) -> TaskPlanStep.State {
        switch state {
        case .pending: .pending
        case .inProgress: .active
        case .completed: .complete
        case .blocked: .blocked
        }
    }

    private static func durableApprovalDecision(_ decision: TaskApprovalRequest.Decision) -> ApprovalDecision {
        switch decision {
        case .pending: .pending
        case .allowedOnce: .approvedOnce
        case .allowedForTask: .approvedForRun
        case .denied: .rejected
        }
    }

    private static func uiApprovalDecision(_ decision: ApprovalDecision) -> TaskApprovalRequest.Decision {
        switch decision {
        case .pending: .pending
        case .approvedOnce: .allowedOnce
        case .approvedForRun: .allowedForTask
        case .rejected: .denied
        }
    }

    private static func uiArtifact(_ artifact: AgentArtifact) -> TaskArtifact {
        let kind: TaskArtifact.Kind = artifact.mediaType == "text/html"
            ? .webpage
            : artifact.mediaType.hasPrefix("application/") ? .document : .file
        return TaskArtifact(
            id: artifact.id,
            title: artifact.name,
            kind: kind,
            detail: artifact.mediaType,
            content: artifact.inlineContent,
            fileURL: artifact.path.isEmpty ? nil : URL(filePath: artifact.path),
            revision: artifact.revision
        )
    }

    private static func mediaType(for kind: TaskArtifact.Kind) -> String {
        switch kind {
        case .document: "application/octet-stream"
        case .file: "application/octet-stream"
        case .webpage: "text/html"
        }
    }

    private static func sideEffect(forToolNamed name: String) -> ToolSideEffect {
        let lowercased = name.lowercased()
        if lowercased.contains("search") || lowercased.contains("fetch") || lowercased.contains("web") {
            return .networkRead
        }
        if lowercased.contains("write") || lowercased.contains("create") || lowercased.contains("document") {
            return .localWrite
        }
        return .none
    }

    private static func contentHash(_ content: String) -> String {
        SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static let builtInSkills = [
        AgentSkillMetadata(
            name: "builtin.web-research",
            description: "Search current web sources and return citations.",
            version: "1",
            path: "builtin://web-research",
            scope: .bundled,
            allowedTools: ["searchWeb", "fetchWebPage"],
            modelInvocable: true
        ),
        AgentSkillMetadata(
            name: "builtin.document-authoring",
            description: "Create and revise local documents.",
            version: "1",
            path: "builtin://document-authoring",
            scope: .bundled,
            allowedTools: ["createDocumentDraft"],
            modelInvocable: true
        ),
    ]

    private func selectedSkillInstructions(for ids: Set<String>) -> String {
        var remainingBytes = 8 * 1024
        let instructions = availableSkills.compactMap { skill -> String? in
            guard ids.contains(skill.id), !skill.path.hasPrefix("builtin://") else { return nil }
            let fileURL = URL(filePath: skill.path).appending(path: "SKILL.md")
            guard let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]),
                  data.count <= SkillDiscovery.maximumSkillBytes,
                  remainingBytes > 0 else { return nil }
            let selectedData = data.prefix(remainingBytes)
            let source = String(decoding: selectedData, as: UTF8.self)
            remainingBytes -= selectedData.count
            let escapedName = skill.name
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            return "<skill name=\"\(escapedName)\">\n\(source)\n</skill>"
        }
        guard !instructions.isEmpty else { return "" }
        return "<selected_skills>\n\(instructions.joined(separator: "\n"))\n</selected_skills>"
    }

    private static func canonicalSkillID(_ id: String) -> String {
        switch id {
        case "web-research": "builtin.web-research"
        case "document-authoring": "builtin.document-authoring"
        default: id
        }
    }

    func persistImmediately() {
        persistenceTask?.cancel()
        persistenceTask = nil
        try? appStateStore.save(persistedState)
    }

    private var persistedState: PersistedAppState {
        PersistedAppState(
            conversations: conversations,
            folders: folders,
            openConversationIDs: openConversationIDs,
            selectedConversationID: selectedConversationID,
            draftAttachments: draftAttachmentsByConversation,
            queuedSubmissions: queuedSubmissions
        )
    }

    private func schedulePersistence() {
        persistenceTask?.cancel()
        persistenceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            try? self.appStateStore.save(self.persistedState)
            self.persistenceTask = nil
        }
    }
}

enum ArtifactSaveError: LocalizedError, Equatable {
    case missingDraft
    case markdownDestinationRequired

    var errorDescription: String? {
        switch self {
        case .missingDraft: "The in-memory Markdown draft is no longer available."
        case .markdownDestinationRequired: "Choose a local filename ending in .md."
        }
    }
}
