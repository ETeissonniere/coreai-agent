import Foundation
import FoundationModels

public enum AgentLifecycleEvent: Sendable, Equatable {
    case reasoning(String)
    case toolCall(id: String, name: String, argumentsJSON: String)
    case toolOutput(id: String, name: String, content: String)
    case response(String)
    case artifact(AgentArtifactEvent)
    case approvalRequested(AgentApprovalRequest)
    case approvalResolved(id: UUID, approved: Bool)
}

public struct AgentApprovalRequest: Sendable, Equatable {
    public let id: UUID
    public let invocationID: String
    public let toolCallID: String
    public let idempotencyKey: String
    public let title: String
    public let detail: String
    public let target: String

    public init(id: UUID, invocationID: String, toolCallID: String, idempotencyKey: String, title: String, detail: String, target: String) {
        self.id = id
        self.invocationID = invocationID
        self.toolCallID = toolCallID
        self.idempotencyKey = idempotencyKey
        self.title = title
        self.detail = detail
        self.target = target
    }
}

public enum ToolIdentity {
    public static func uuid(forOpaqueID value: String) -> UUID {
        var first = UInt64(0xcbf29ce484222325)
        var second = UInt64(0x84222325cbf29ce4)
        for byte in value.utf8 {
            first = (first ^ UInt64(byte)) &* 0x100000001b3
            second = (second ^ UInt64(byte &+ 31)) &* 0x100000001b3
        }
        var bytes = withUnsafeBytes(of: first.bigEndian, Array.init)
            + withUnsafeBytes(of: second.bigEndian, Array.init)
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

public struct AgentArtifactEvent: Sendable, Equatable {
    public let id: UUID
    public let title: String
    public let mediaType: String
    public let content: String
    public let revision: Int

    public init(id: UUID, title: String, mediaType: String, content: String, revision: Int) {
        self.id = id
        self.title = title
        self.mediaType = mediaType
        self.content = content
        self.revision = revision
    }
}

public actor AgentEventJournal {
    private var events: [AgentLifecycleEvent] = []
    private var subscribers: [UUID: AsyncStream<AgentLifecycleEvent>.Continuation] = [:]

    public init() {}

    public func record(_ event: AgentLifecycleEvent) {
        events.append(event)
        for continuation in subscribers.values { continuation.yield(event) }
    }

    public func snapshot() -> [AgentLifecycleEvent] {
        events
    }

    public func removeAll() {
        events.removeAll(keepingCapacity: true)
    }

    public func stream(after index: Int) -> AsyncStream<AgentLifecycleEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            for event in events.dropFirst(min(index, events.count)) { continuation.yield(event) }
            subscribers[id] = continuation
            continuation.onTermination = { _ in
                Task { await self.removeSubscriber(id) }
            }
        }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }
}

public enum TranscriptEventMapper {
    public static func events(from entries: some Sequence<Transcript.Entry>) -> [AgentLifecycleEvent] {
        entries.flatMap { entry -> [AgentLifecycleEvent] in
            switch entry {
            case .reasoning(let reasoning):
                let content = text(in: reasoning.segments)
                return content.isEmpty ? [] : [AgentLifecycleEvent.reasoning(content)]
            case .toolCalls(let calls):
                return calls.map {
                    .toolCall(id: $0.id, name: $0.toolName, argumentsJSON: $0.arguments.jsonString)
                }
            case .toolOutput(let output):
                return [.toolOutput(
                    id: output.id,
                    name: output.toolName,
                    content: text(in: output.segments)
                )]
            case .response(let response):
                let content = text(in: response.segments)
                return content.isEmpty ? [] : [.response(content)]
            default:
                return []
            }
        }
    }

    private static func text(in segments: [Transcript.Segment]) -> String {
        segments.compactMap { segment in
            guard case .text(let text) = segment else { return nil }
            return text.content
        }.joined()
    }
}
