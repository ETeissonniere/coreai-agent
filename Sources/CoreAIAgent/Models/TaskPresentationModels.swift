import Foundation

enum AgentTaskState: String, Sendable {
    case ready, working, waitingForApproval, waitingForInput, completed, stopped, failed

    var label: String {
        switch self {
        case .ready: "Ready"
        case .working: "Working"
        case .waitingForApproval: "Needs approval"
        case .waitingForInput: "Needs input"
        case .completed: "Completed"
        case .stopped: "Stopped"
        case .failed: "Failed"
        }
    }

    var systemImage: String {
        switch self {
        case .ready: "circle"
        case .working: "progress.indicator"
        case .waitingForApproval: "hand.raised.fill"
        case .waitingForInput: "questionmark.bubble"
        case .completed: "checkmark.circle.fill"
        case .stopped: "stop.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }
}

enum TaskInspectorSection: String, CaseIterable, Identifiable {
    case artifacts = "Artifacts"
    case context = "Context"
    case activity = "Activity"
    var id: Self { self }
}

struct TaskPlanStep: Identifiable, Equatable, Sendable {
    enum State: Equatable, Sendable { case pending, active, complete, blocked }
    let id: UUID
    var title: String
    var state: State
    init(id: UUID = UUID(), title: String, state: State = .pending) {
        self.id = id; self.title = title; self.state = state
    }
}

struct TaskArtifact: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case document, file, webpage
        var systemImage: String {
            switch self { case .document: "doc.richtext"; case .file: "doc"; case .webpage: "globe" }
        }
    }
    let id: UUID
    var title: String
    var kind: Kind
    var detail: String
    var content: String? = nil
    var fileURL: URL?
    var revision: Int = 1
}

struct TaskApprovalRequest: Identifiable, Equatable, Sendable {
    enum Decision: String, Equatable, Sendable { case pending, allowedOnce, allowedForTask, denied }
    let id: UUID
    var title: String
    var explanation: String
    var target: String
    var sendsDataOffDevice: Bool
    var decision: Decision
}

enum ToolActivityState: Sendable {
    case requested, waitingForApproval, running, succeeded, unavailable, failed

    var label: String {
        switch self {
        case .requested: "Requested"
        case .waitingForApproval: "Needs approval"
        case .running: "Running"
        case .succeeded: "Completed"
        case .unavailable: "Unavailable after retries"
        case .failed: "Failed"
        }
    }

    var systemImage: String {
        switch self {
        case .requested: "clock"
        case .waitingForApproval: "hand.raised"
        case .running: "progress.indicator"
        case .succeeded: "checkmark.circle.fill"
        case .unavailable: "exclamationmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }
}

struct ToolActivityPresentation: Identifiable, Sendable {
    let invocation: ToolInvocation
    var id: UUID { invocation.id }
    let state: ToolActivityState
    let result: ToolResultRecord?
    let requestedAt: Date
    let completedAt: Date?

    var displayName: String {
        invocation.toolID
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ".", with: " · ")
    }

    var isWebActivity: Bool {
        let value = invocation.toolID.lowercased()
        return value.contains("web") || value.contains("search") || value.contains("browser")
    }

    var sourceURLs: [URL] {
        guard let content = result?.content,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        let range = NSRange(content.startIndex..., in: content)
        var seen = Set<URL>()
        return detector.matches(in: content, range: range).compactMap(\.url).filter { seen.insert($0).inserted }
    }

    var displayResult: String? {
        guard let content = result?.content, !content.isEmpty else { return nil }
        return Self.sanitizedToolOutput(content)
    }

    static func sanitizedToolOutput(_ content: String) -> String {
        content
            .replacingOccurrences(of: #"</?web_(search|fetch)_status[^>]*>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"</?untrusted_web_result[^>]*>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Ephemeral, display-only chronology for one assistant turn. Tool payloads and
/// private reasoning intentionally remain outside `ChatMessage` and canonical model history.
struct AssistantExecutionTrace: Equatable, Sendable {
    struct Entry: Identifiable, Equatable, Sendable {
        enum Content: Equatable, Sendable {
            case reasoning(String)
            case tool(UUID)
        }

        let id: UUID
        var content: Content

        init(id: UUID = UUID(), content: Content) {
            self.id = id
            self.content = content
        }
    }

    private(set) var entries: [Entry] = []

    mutating func recordTool(_ invocationID: UUID) {
        guard !entries.contains(where: { $0.content == .tool(invocationID) }) else { return }
        entries.append(Entry(content: .tool(invocationID)))
    }

    mutating func recordReasoningSegment(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let lastIndex = entries.indices.last,
           case .reasoning(let existing) = entries[lastIndex].content {
            if text == existing || existing.hasSuffix(text) { return }
            if text.hasPrefix(existing) {
                entries[lastIndex].content = .reasoning(text)
            } else {
                entries[lastIndex].content = .reasoning(existing + "\n\n" + text)
            }
        } else {
            entries.append(Entry(content: .reasoning(text)))
        }
    }

    /// Reconciles the aggregate reasoning snapshot emitted by generation with
    /// segments already frozen around tool boundaries.
    mutating func recordReasoningSnapshot(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let recorded = reasoningText
        guard text != recorded else { return }
        guard !recorded.isEmpty, text.hasPrefix(recorded) else {
            if recorded.isEmpty { recordReasoningSegment(text) }
            return
        }
        let suffix = text.dropFirst(recorded.count).trimmingCharacters(in: .whitespacesAndNewlines)
        if !suffix.isEmpty { recordReasoningSegment(suffix) }
    }

    var reasoningText: String {
        entries.compactMap {
            guard case .reasoning(let text) = $0.content else { return nil }
            return text
        }.joined(separator: "\n\n")
    }
}

extension AgentSkillMetadata {
    var systemImage: String {
        let value = name.lowercased()
        if value.contains("web") || value.contains("research") { return "globe" }
        if value.contains("document") || value.contains("pdf") { return "doc.richtext" }
        if value.contains("sheet") || value.contains("data") { return "tablecells" }
        return "shippingbox"
    }
}

extension AgentArtifact {
    var fileURL: URL { URL(filePath: path) }
    var systemImage: String {
        if mediaType.contains("pdf") { return "doc.richtext" }
        if mediaType.contains("html") { return "globe" }
        if mediaType.hasPrefix("image/") { return "photo" }
        return "doc"
    }
}

extension Conversation {
    func taskState(hasPendingApproval: Bool = false, durableRunStatus: AgentRunStatus? = nil) -> AgentTaskState {
        if hasPendingApproval { return .waitingForApproval }
        if let durableRunStatus {
            switch durableRunStatus {
            case .queued, .preparing, .running, .compacting: return .working
            case .awaitingApproval: return .waitingForApproval
            case .suspended: return .waitingForInput
            case .completed: return .completed
            case .cancelled: return .stopped
            case .failed: return .failed
            }
        }
        guard let response = messages.last(where: { $0.role == .assistant }) else { return .ready }
        switch response.generationState {
        case .streaming: return .working
        case .failed: return .failed
        case .stopped: return .stopped
        case .complete: return .completed
        case nil: return response.text.isEmpty ? .ready : .completed
        }
    }
}
