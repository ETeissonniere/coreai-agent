import Foundation

public enum ToolApprovalError: Error, Equatable {
    case denied
}

public actor ToolExecutionBroker {
    private struct Pending {
        let request: AgentApprovalRequest
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let journal: AgentEventJournal
    private var pending: [UUID: Pending] = [:]
    private var decisions: [String: Bool] = [:]
    private var completedOutputs: [String: String] = [:]
    private var inFlightOutputs: [String: Task<String, Error>] = [:]
    private var invocationQueues: [String: [String]] = [:]

    public init(journal: AgentEventJournal) {
        self.journal = journal
    }

    public func registerInvocation(toolName: String, toolCallID: String) {
        invocationQueues[toolName, default: []].append(toolCallID)
    }

    public func claimInvocation(toolName: String) -> String? {
        guard !invocationQueues[toolName, default: []].isEmpty else { return nil }
        return invocationQueues[toolName]?.removeFirst()
    }

    public func authorize(_ request: AgentApprovalRequest) async throws {
        if let approved = decisions[request.idempotencyKey] {
            guard approved else { throw ToolApprovalError.denied }
            return
        }
        let approved = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pending[request.id] = Pending(request: request, continuation: continuation)
                if Task.isCancelled {
                    pending.removeValue(forKey: request.id)
                    continuation.resume(returning: false)
                } else {
                    Task { await journal.record(.approvalRequested(request)) }
                }
            }
        } onCancel: {
            Task { await self.cancel(request.id) }
        }
        try Task.checkCancellation()
        guard approved else { throw ToolApprovalError.denied }
    }

    public func execute(
        _ request: AgentApprovalRequest,
        operation: @escaping @Sendable () async throws -> String
    ) async throws -> String {
        try await authorize(request)
        if let output = completedOutputs[request.idempotencyKey] { return output }
        if let task = inFlightOutputs[request.idempotencyKey] { return try await task.value }
        let task = Task { try await operation() }
        inFlightOutputs[request.idempotencyKey] = task
        do {
            let output = try await task.value
            completedOutputs[request.idempotencyKey] = output
            inFlightOutputs.removeValue(forKey: request.idempotencyKey)
            return output
        } catch {
            inFlightOutputs.removeValue(forKey: request.idempotencyKey)
            throw error
        }
    }

    @discardableResult
    public func resolve(id: UUID, approved: Bool) async -> Bool {
        guard let value = pending.removeValue(forKey: id) else { return false }
        decisions[value.request.idempotencyKey] = approved
        await journal.record(.approvalResolved(id: id, approved: approved))
        value.continuation.resume(returning: approved)
        return true
    }

    private func cancel(_ id: UUID) async {
        guard let value = pending.removeValue(forKey: id) else { return }
        value.continuation.resume(returning: false)
    }
}
