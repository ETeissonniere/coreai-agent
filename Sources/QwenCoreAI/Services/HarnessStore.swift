import Foundation

struct HarnessIndex: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int = Self.currentVersion
    var workspaces: [AgentWorkspace] = []
    var tasks: [AgentTaskRecord] = []
    var runs: [AgentRunRecord] = []
}

protocol HarnessStoring: Sendable {
    func loadIndex() async throws -> HarnessIndex
    func upsertWorkspace(_ workspace: AgentWorkspace) async throws -> AgentWorkspace
    func upsertTask(_ task: AgentTaskRecord) async throws -> AgentTaskRecord
    func createTask(_ task: AgentTaskRecord) async throws -> AgentTaskRecord
    func createRun(_ run: AgentRunRecord) async throws -> AgentRunRecord
    func currentOrCreateRun(taskID: UUID, initialStatus: AgentRunStatus) async throws -> AgentRunRecord
    func append(
        _ payload: AgentRunEventPayload,
        to runID: UUID,
        idempotencyKey: String?,
        timestamp: Date
    ) async throws -> AgentRunEvent
    func events(for runID: UUID) async throws -> [AgentRunEvent]
    func projection(for runID: UUID) async throws -> AgentRunProjection
    func saveCheckpoint(_ checkpoint: AgentRunCheckpoint) async throws -> AgentRunCheckpoint
    func latestCheckpoint(for runID: UUID) async throws -> AgentRunCheckpoint?
    func deleteTask(_ taskID: UUID) async throws
    func migrateLegacyConversations(
        from state: PersistedAppState,
        workspaceID: UUID?
    ) async throws -> [AgentTaskRecord]
}

enum HarnessStoreError: LocalizedError {
    case unsupportedVersion(Int)
    case missingWorkspace(UUID)
    case missingTask(UUID)
    case missingRun(UUID)
    case invalidEventSchema(Int)
    case invalidEventSequence(runID: UUID, sequence: Int)
    case invalidStateTransition(from: AgentRunStatus, to: AgentRunStatus)
    case invalidToolLifecycle(String)
    case checkpointDoesNotMatchRun

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            "The agent state uses unsupported format version \(version)."
        case .missingWorkspace(let id):
            "No agent workspace exists with ID \(id)."
        case .missingTask(let id):
            "No agent task exists with ID \(id)."
        case .missingRun(let id):
            "No agent run exists with ID \(id)."
        case .invalidEventSchema(let version):
            "The run log contains unsupported event schema version \(version)."
        case .invalidEventSequence(let runID, let sequence):
            "Run \(runID) contains an invalid event at sequence \(sequence)."
        case .invalidStateTransition(let from, let to):
            "The run cannot transition from \(from.rawValue) to \(to.rawValue)."
        case .invalidToolLifecycle(let detail):
            "The run contains an invalid tool lifecycle: \(detail)."
        case .checkpointDoesNotMatchRun:
            "The checkpoint does not belong to the run being saved."
        }
    }
}

/// Durable local state for the agent harness.
///
/// Current entities live in one atomically replaced index, while each run's immutable history is
/// newline-delimited JSON. Checkpoints are replaceable derived state; the event log remains the
/// audit source of truth. Actor isolation serializes access within this process; the store does not
/// claim or implement cross-process locking.
actor JSONHarnessStore: HarnessStoring {
    /// The production owner. AppModel uses this singleton so two store actors cannot concurrently
    /// mutate the same default files. Explicit instances are reserved for isolated/test roots.
    static let shared = JSONHarnessStore()

    let rootURL: URL

    private var cachedIndex: HarnessIndex?
    private var eventCache = [UUID: [AgentRunEvent]]()

    init(rootURL: URL? = nil) {
        self.rootURL = rootURL ?? Self.defaultRootURL
    }

    func loadIndex() throws -> HarnessIndex {
        if let cachedIndex { return cachedIndex }
        let indexURL = rootURL.appending(path: "index.json")
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            let recovered = try reconcileIndex(HarnessIndex())
            cachedIndex = recovered
            if !recovered.tasks.isEmpty || !recovered.runs.isEmpty { try saveIndex(recovered) }
            return recovered
        }

        var index: HarnessIndex
        do {
            index = try JSONDecoder.harness.decode(HarnessIndex.self, from: Data(contentsOf: indexURL))
            guard index.version == HarnessIndex.currentVersion else {
                throw HarnessStoreError.unsupportedVersion(index.version)
            }
        } catch {
            try quarantine(fileAt: indexURL, reason: "corrupt-index")
            index = HarnessIndex()
        }
        index = try reconcileIndex(index)
        cachedIndex = index
        try saveIndex(index)
        return index
    }

    @discardableResult
    func upsertWorkspace(_ workspace: AgentWorkspace) throws -> AgentWorkspace {
        var index = try loadIndex()
        if let position = index.workspaces.firstIndex(where: { $0.id == workspace.id }) {
            index.workspaces[position] = workspace
        } else {
            index.workspaces.append(workspace)
        }
        try saveIndex(index)
        return workspace
    }

    @discardableResult
    func createTask(_ task: AgentTaskRecord) throws -> AgentTaskRecord {
        var index = try loadIndex()
        if let workspaceID = task.workspaceID,
           !index.workspaces.contains(where: { $0.id == workspaceID }) {
            throw HarnessStoreError.missingWorkspace(workspaceID)
        }
        if !index.tasks.contains(where: { $0.id == task.id }) {
            index.tasks.append(task)
            try saveIndex(index)
        }
        return task
    }

    @discardableResult
    func upsertTask(_ task: AgentTaskRecord) throws -> AgentTaskRecord {
        var index = try loadIndex()
        if let workspaceID = task.workspaceID,
           !index.workspaces.contains(where: { $0.id == workspaceID }) {
            throw HarnessStoreError.missingWorkspace(workspaceID)
        }
        if let position = index.tasks.firstIndex(where: { $0.id == task.id }) {
            index.tasks[position] = task
        } else {
            index.tasks.append(task)
        }
        try saveIndex(index)
        return task
    }

    @discardableResult
    func createRun(_ run: AgentRunRecord) throws -> AgentRunRecord {
        var index = try loadIndex()
        guard index.tasks.contains(where: { $0.id == run.taskID }) else {
            throw HarnessStoreError.missingTask(run.taskID)
        }
        if !index.runs.contains(where: { $0.id == run.id }) {
            index.runs.append(run)
            try saveIndex(index)
        }
        let task = index.tasks.first(where: { $0.id == run.taskID })!
        _ = try append(
            .runRegistered(run: run, task: task),
            to: run.id,
            idempotencyKey: "run-registered:\(run.id)"
        )
        return run
    }

    /// Atomically selects the task's active run or creates one. Keeping this operation inside the
    /// store actor prevents concurrent UI mutations (for example skill selection and approval)
    /// from creating sibling runs after the same completed checkpoint.
    @discardableResult
    func currentOrCreateRun(
        taskID: UUID,
        initialStatus: AgentRunStatus
    ) throws -> AgentRunRecord {
        let index = try loadIndex()
        guard index.tasks.contains(where: { $0.id == taskID }) else {
            throw HarnessStoreError.missingTask(taskID)
        }
        if let active = index.runs.last(where: {
            $0.taskID == taskID
                && $0.status != .completed
                && $0.status != .cancelled
                && $0.status != .failed
                && $0.status != .suspended
        }) {
            return active
        }
        let interrupted = index.runs.last(where: { $0.taskID == taskID && $0.status == .suspended })
        return try createRun(AgentRunRecord(
            taskID: taskID,
            status: initialStatus,
            parentRunID: interrupted?.id
        ))
    }

    @discardableResult
    func append(
        _ payload: AgentRunEventPayload,
        to runID: UUID,
        idempotencyKey: String? = nil,
        timestamp: Date = .now
    ) throws -> AgentRunEvent {
        var index = try loadIndex()
        guard let runPosition = index.runs.firstIndex(where: { $0.id == runID }) else {
            throw HarnessStoreError.missingRun(runID)
        }

        let existingEvents = try events(for: runID)
        if let idempotencyKey,
           let existing = existingEvents.first(where: { $0.idempotencyKey == idempotencyKey }) {
            return existing
        }

        let nextSequence = max(index.runs[runPosition].lastSequence, existingEvents.last?.sequence ?? 0) + 1
        let event = AgentRunEvent(
            runID: runID,
            sequence: nextSequence,
            timestamp: timestamp,
            idempotencyKey: idempotencyKey,
            payload: payload
        )
        _ = try fold(events: existingEvents + [event], initialStatus: index.runs[runPosition].status)
        try appendEventLine(event)
        eventCache[runID, default: []].append(event)

        index.runs[runPosition].lastSequence = nextSequence
        index.runs[runPosition].updatedAt = timestamp
        if case .statusChanged(let status) = payload { index.runs[runPosition].status = status }
        if case .completed = payload { index.runs[runPosition].status = .completed }
        if case .cancelled = payload { index.runs[runPosition].status = .cancelled }
        if case .failed = payload { index.runs[runPosition].status = .failed }
        try saveIndex(index)
        return event
    }

    func events(for runID: UUID) throws -> [AgentRunEvent] {
        if let cached = eventCache[runID] { return cached }
        let loaded = try readEventLog(runID: runID)
        eventCache[runID] = loaded
        return loaded
    }

    func projection(for runID: UUID) throws -> AgentRunProjection {
        let index = try loadIndex()
        let initialStatus = index.runs.first(where: { $0.id == runID })?.status ?? .queued
        return try fold(events: events(for: runID), initialStatus: initialStatus)
    }

    @discardableResult
    func saveCheckpoint(_ checkpoint: AgentRunCheckpoint) throws -> AgentRunCheckpoint {
        var index = try loadIndex()
        guard let runPosition = index.runs.firstIndex(where: { $0.id == checkpoint.runID }) else {
            throw HarnessStoreError.missingRun(checkpoint.runID)
        }
        guard index.runs[runPosition].resumeKey == checkpoint.resumeKey else {
            throw HarnessStoreError.checkpointDoesNotMatchRun
        }
        guard checkpoint.sequence == index.runs[runPosition].lastSequence else {
            throw HarnessStoreError.checkpointDoesNotMatchRun
        }

        let directory = checkpointDirectoryURL(for: checkpoint.runID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appending(path: "\(checkpoint.sequence)-\(checkpoint.id).json")
        try JSONEncoder.harness.encode(checkpoint).write(to: fileURL, options: .atomic)

        index.runs[runPosition].activeCheckpointID = checkpoint.id
        index.runs[runPosition].updatedAt = checkpoint.createdAt
        try saveIndex(index)
        _ = try append(
            .checkpointSaved(checkpointID: checkpoint.id),
            to: checkpoint.runID,
            idempotencyKey: "checkpoint:\(checkpoint.id)",
            timestamp: checkpoint.createdAt
        )
        return checkpoint
    }

    func latestCheckpoint(for runID: UUID) throws -> AgentRunCheckpoint? {
        let index = try loadIndex()
        guard let run = index.runs.first(where: { $0.id == runID }) else {
            throw HarnessStoreError.missingRun(runID)
        }
        let events = try events(for: runID)
        var committed = [UUID: Int]()
        for event in events {
            if case .checkpointSaved(let id) = event.payload { committed[id] = event.sequence }
        }
        let directory = checkpointDirectoryURL(for: runID)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return nil }

        let candidates = files.filter { $0.pathExtension == "json" }.sorted {
            Self.checkpointSequence(from: $0) > Self.checkpointSequence(from: $1)
        }
        for fileURL in candidates {
            do {
                let checkpoint = try JSONDecoder.harness.decode(
                    AgentRunCheckpoint.self,
                    from: Data(contentsOf: fileURL)
                )
                guard checkpoint.version == AgentRunCheckpoint.currentVersion,
                      checkpoint.runID == runID,
                      checkpoint.resumeKey == run.resumeKey,
                      let commitSequence = committed[checkpoint.id],
                      checkpoint.sequence < commitSequence else {
                    try quarantine(fileAt: fileURL, reason: "invalid-checkpoint")
                    continue
                }
                return checkpoint
            } catch {
                try quarantine(fileAt: fileURL, reason: "corrupt-checkpoint")
            }
        }
        return nil
    }

    func deleteTask(_ taskID: UUID) throws {
        var index = try loadIndex()
        let runIDs = index.runs.filter { $0.taskID == taskID }.map(\.id)
        index.tasks.removeAll { $0.id == taskID }
        index.runs.removeAll { $0.taskID == taskID }

        for runID in runIDs {
            eventCache[runID] = nil
            let eventURL = eventFileURL(for: runID)
            if FileManager.default.fileExists(atPath: eventURL.path) {
                try FileManager.default.removeItem(at: eventURL)
            }
            let checkpointURL = checkpointDirectoryURL(for: runID)
            if FileManager.default.fileExists(atPath: checkpointURL.path) {
                try FileManager.default.removeItem(at: checkpointURL)
            }
        }
        try saveIndex(index)
    }

    /// Imports existing chat state once. Conversation and message identifiers are preserved so the
    /// legacy UI and the harness can be correlated during the transition.
    @discardableResult
    func migrateLegacyConversations(
        from state: PersistedAppState,
        workspaceID: UUID? = nil
    ) throws -> [AgentTaskRecord] {
        var index = try loadIndex()
        var imported = [AgentTaskRecord]()

        for conversation in state.conversations {
            let createdAt = conversation.messages.map(\.createdAt).min() ?? conversation.updatedAt
            let existingTask = index.tasks.first(where: { $0.legacyConversationID == conversation.id })
            let task = existingTask ?? AgentTaskRecord(
                workspaceID: workspaceID,
                legacyConversationID: conversation.id,
                title: conversation.title,
                createdAt: createdAt,
                updatedAt: conversation.updatedAt
            )
            if existingTask == nil {
                index.tasks.append(task)
                try saveIndex(index)
                imported.append(task)
            }
            var run = index.runs.first(where: { $0.taskID == task.id })
                ?? AgentRunRecord(taskID: task.id, status: .queued, createdAt: createdAt, updatedAt: conversation.updatedAt)
            if !index.runs.contains(where: { $0.id == run.id }) {
                index.runs.append(run)
                try saveIndex(index)
            }
            _ = try createRun(run)
            let existingEvents = try events(for: run.id)
            let hasModernTranscript = existingEvents.contains { event in
                switch event.payload {
                case .userInput, .responseMessage, .toolRequested, .approvalRequested, .artifactCreated:
                    true
                default:
                    false
                }
            }
            if hasModernTranscript {
                // Once a task has harness-native history, stale AppState is only a UI projection
                // and must never append, reorder, or terminalize the durable run.
                continue
            }
            for message in conversation.messages {
                _ = try append(
                    .legacyMessage(message),
                    to: run.id,
                    idempotencyKey: "legacy-message:\(message.id)",
                    timestamp: message.createdAt
                )
            }
            _ = try append(.completed, to: run.id, idempotencyKey: "legacy-complete:\(conversation.id)", timestamp: conversation.updatedAt)
            index = try loadIndex()
            if let restoredRun = index.runs.first(where: { $0.id == run.id }) { run = restoredRun }
        }
        return imported
    }

    private func saveIndex(_ index: HarnessIndex) throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try JSONEncoder.harness.encode(index).write(
            to: rootURL.appending(path: "index.json"),
            options: .atomic
        )
        cachedIndex = index
    }

    private func appendEventLine(_ event: AgentRunEvent) throws {
        let directory = rootURL.appending(path: "events", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = eventFileURL(for: event.runID)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        var line = try JSONEncoder.harnessLine.encode(event)
        line.append(UInt8(ascii: "\n"))
        try handle.write(contentsOf: line)
        try handle.synchronize()
    }

    private func eventFileURL(for runID: UUID) -> URL {
        rootURL.appending(path: "events", directoryHint: .isDirectory)
            .appending(path: "\(runID).jsonl")
    }

    private func checkpointDirectoryURL(for runID: UUID) -> URL {
        rootURL.appending(path: "checkpoints", directoryHint: .isDirectory)
            .appending(path: runID.uuidString, directoryHint: .isDirectory)
    }

    private func reconcileIndex(_ input: HarnessIndex) throws -> HarnessIndex {
        var index = input
        let eventsDirectory = rootURL.appending(path: "events", directoryHint: .isDirectory)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: eventsDirectory,
            includingPropertiesForKeys: nil
        )) ?? []

        for fileURL in files where fileURL.pathExtension == "jsonl" {
            guard let runID = UUID(uuidString: fileURL.deletingPathExtension().lastPathComponent) else { continue }
            let events = try readEventLog(runID: runID)
            eventCache[runID] = events
            if let registration = events.compactMap({ event -> (AgentRunRecord, AgentTaskRecord)? in
                if case .runRegistered(let run, let task) = event.payload { return (run, task) }
                return nil
            }).first {
                if !index.tasks.contains(where: { $0.id == registration.1.id }) {
                    index.tasks.append(registration.1)
                }
                if !index.runs.contains(where: { $0.id == registration.0.id }) {
                    index.runs.append(registration.0)
                }
            }
            guard let runPosition = index.runs.firstIndex(where: { $0.id == runID }) else { continue }
            let projection = try fold(events: events, initialStatus: index.runs[runPosition].status)
            index.runs[runPosition].lastSequence = projection.lastSequence
            index.runs[runPosition].status = projection.status
            index.runs[runPosition].activeCheckpointID = projection.activeCheckpointID
            if let timestamp = events.last?.timestamp { index.runs[runPosition].updatedAt = timestamp }
        }
        return index
    }

    private func readEventLog(runID: UUID) throws -> [AgentRunEvent] {
        let fileURL = eventFileURL(for: runID)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty else { return [] }

        let endsWithNewline = data.last == UInt8(ascii: "\n")
        let rawLines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        var events = [AgentRunEvent]()
        var validByteCount = 0
        for (lineIndex, rawLine) in rawLines.enumerated() {
            do {
                let event = try JSONDecoder.harness.decode(AgentRunEvent.self, from: Data(rawLine))
                guard event.schemaVersion == AgentRunEvent.currentSchemaVersion else {
                    throw HarnessStoreError.invalidEventSchema(event.schemaVersion)
                }
                guard event.runID == runID, event.sequence == events.count + 1 else {
                    throw HarnessStoreError.invalidEventSequence(runID: runID, sequence: event.sequence)
                }
                events.append(event)
                validByteCount += rawLine.count + 1
            } catch {
                let isTornTail = lineIndex == rawLines.count - 1 && !endsWithNewline
                guard isTornTail else { throw error }
                let tornData = data.suffix(from: min(validByteCount, data.count))
                try quarantine(data: Data(tornData), named: "\(runID)-torn-tail.json")
                try Data(data.prefix(validByteCount)).write(to: fileURL, options: .atomic)
            }
        }
        if !endsWithNewline, validByteCount >= data.count {
            var repaired = data
            repaired.append(UInt8(ascii: "\n"))
            try repaired.write(to: fileURL, options: .atomic)
        }
        _ = try fold(events: events, initialStatus: .queued)
        return events
    }

    private func fold(
        events: [AgentRunEvent],
        initialStatus fallbackStatus: AgentRunStatus
    ) throws -> AgentRunProjection {
        var status = events.compactMap { event -> AgentRunStatus? in
            if case .runRegistered(let run, _) = event.payload { return run.status }
            return nil
        }.first ?? (events.isEmpty ? fallbackStatus : .queued)
        var pendingInvocations = [UUID: ToolInvocation]()
        var approvals = [UUID: ApprovalRequestRecord]()
        var artifacts = [UUID: AgentArtifact]()
        var skills = [String]()
        var plan: AgentPlan?
        var compaction: StructuredCompactionState?
        var completedKeys = Set<String>()
        var checkpointID: UUID?

        for event in events {
            switch event.payload {
            case .statusChanged(let next):
                guard Self.canTransition(from: status, to: next) else {
                    throw HarnessStoreError.invalidStateTransition(from: status, to: next)
                }
                status = next
            case .toolRequested(let invocation):
                guard pendingInvocations[invocation.id] == nil else {
                    throw HarnessStoreError.invalidToolLifecycle("duplicate request \(invocation.id)")
                }
                pendingInvocations[invocation.id] = invocation
            case .toolStarted(let invocationID):
                guard pendingInvocations[invocationID] != nil else {
                    throw HarnessStoreError.invalidToolLifecycle("start before request \(invocationID)")
                }
            case .toolCompleted(let result):
                guard let invocation = pendingInvocations.removeValue(forKey: result.invocationID) else {
                    throw HarnessStoreError.invalidToolLifecycle("completion before request \(result.invocationID)")
                }
                completedKeys.insert(invocation.idempotencyKey)
            case .approvalRequested(let approval):
                guard pendingInvocations[approval.invocationID] != nil else {
                    throw HarnessStoreError.invalidToolLifecycle("approval without pending invocation \(approval.invocationID)")
                }
                approvals[approval.id] = approval
            case .approvalResolved(let approvalID, let decision):
                guard var approval = approvals[approvalID], approval.decision == .pending else {
                    throw HarnessStoreError.invalidToolLifecycle("approval resolved more than once or before request \(approvalID)")
                }
                approval.decision = decision
                approval.resolvedAt = event.timestamp
                approvals[approvalID] = approval
            case .artifactCreated(let artifact):
                if let existing = artifacts[artifact.id], artifact.revision < existing.revision { break }
                artifacts[artifact.id] = artifact
            case .skillsChanged(let selected):
                skills = selected
            case .skillSelected(let skillID):
                if !skills.contains(skillID) { skills.append(skillID) }
            case .planUpdated(let value):
                plan = value
            case .compactionUpdated(let value):
                compaction = value
            case .checkpointSaved(let id):
                checkpointID = id
            case .completed:
                guard Self.canTransition(from: status, to: .completed) else {
                    throw HarnessStoreError.invalidStateTransition(from: status, to: .completed)
                }
                status = .completed
            case .cancelled:
                guard Self.canTransition(from: status, to: .cancelled) else {
                    throw HarnessStoreError.invalidStateTransition(from: status, to: .cancelled)
                }
                status = .cancelled
            case .failed:
                guard Self.canTransition(from: status, to: .failed) else {
                    throw HarnessStoreError.invalidStateTransition(from: status, to: .failed)
                }
                status = .failed
            case .runCreated, .runRegistered, .userInput, .reasoningDelta, .responseDelta,
                 .reasoningMessage, .responseMessage, .legacyMessage:
                break
            }
        }

        return AgentRunProjection(
            status: status,
            lastSequence: events.last?.sequence ?? 0,
            pendingInvocations: pendingInvocations.values.sorted { $0.id.uuidString < $1.id.uuidString },
            approvals: approvals.values.sorted { $0.requestedAt < $1.requestedAt },
            artifacts: artifacts.values.sorted { $0.createdAt < $1.createdAt },
            selectedSkillIDs: skills,
            plan: plan,
            compaction: compaction,
            completedIdempotencyKeys: completedKeys.sorted(),
            activeCheckpointID: checkpointID
        )
    }

    private static func canTransition(from: AgentRunStatus, to: AgentRunStatus) -> Bool {
        if from == to { return true }
        switch from {
        case .queued:
            return [.preparing, .running, .awaitingApproval, .completed, .cancelled, .failed].contains(to)
        case .preparing:
            return [.running, .awaitingApproval, .suspended, .cancelled, .failed].contains(to)
        case .running:
            return [.awaitingApproval, .compacting, .suspended, .completed, .cancelled, .failed].contains(to)
        case .awaitingApproval:
            return [.running, .suspended, .cancelled, .failed].contains(to)
        case .compacting:
            return [.running, .suspended, .completed, .cancelled, .failed].contains(to)
        case .suspended:
            return [.running, .cancelled, .failed].contains(to)
        case .completed, .cancelled, .failed:
            return false
        }
    }

    private func quarantine(fileAt fileURL: URL, reason: String) throws {
        let data = try Data(contentsOf: fileURL)
        try quarantine(data: data, named: "\(reason)-\(fileURL.lastPathComponent)")
        try FileManager.default.removeItem(at: fileURL)
    }

    private func quarantine(data: Data, named name: String) throws {
        let directory = rootURL.appending(path: "quarantine", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appending(path: "\(UUID().uuidString)-\(name)")
        try data.write(to: fileURL, options: .atomic)
    }

    private static var defaultRootURL: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return applicationSupport
            .appending(path: "Qwen Core AI", directoryHint: .isDirectory)
            .appending(path: "AgentHarness", directoryHint: .isDirectory)
    }

    private static func checkpointSequence(from fileURL: URL) -> Int {
        Int(fileURL.deletingPathExtension().lastPathComponent.split(separator: "-").first ?? "") ?? -1
    }
}

private extension JSONEncoder {
    static var harness: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static var harnessLine: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

private extension JSONDecoder {
    static var harness: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
