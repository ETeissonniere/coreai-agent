import SwiftUI

struct TaskTimelineView: View {
    @Bindable var model: AppModel
    let conversation: Conversation

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if let checkpoint = model.recoveryCheckpointByConversation[conversation.id],
                       model.recoveredConversationIDs.contains(conversation.id) {
                        RecoveryBanner(checkpoint: checkpoint) {
                            model.dismissRecoveryNotice(in: conversation.id)
                        }
                    }
                    if let steps = model.taskPlans[conversation.id], !steps.isEmpty,
                       !(steps.count == 1 && steps[0].title == "Complete the request") {
                        TaskPlanCard(steps: steps)
                    }
                    ForEach(conversation.messages) { message in
                        if message.role == .user { request(message) }
                        else {
                            MessageRow(
                                message: message,
                                toolActivities: toolActivities(for: message),
                                activePhase: message.id == conversation.messages.last?.id
                                    && message.generationState == .streaming
                                    ? model.modelPhase
                                    : nil,
                                retry: message.id == conversation.messages.last?.id
                                    && message.generationState == .failed
                                    ? { model.prepareRetry(in: conversation.id) }
                                    : nil
                            )
                            .id(message.id)
                        }
                    }
                    ForEach((model.approvalsByConversation[conversation.id] ?? []).filter {
                        $0.decision == .pending
                    }) { approval in
                        TaskApprovalCard(approval: approval) {
                            model.decideApproval(approval.id, in: conversation.id, decision: $0)
                        }
                    }
                    ForEach(model.artifactsByConversation[conversation.id] ?? []) { artifact in
                        ArtifactActivityCard(artifact: artifact) {
                            model.selectedArtifactID = artifact.id
                            model.inspectorSection = .artifacts
                            model.showInspector = true
                        }
                    }
                }
                .frame(maxWidth: 820)
                .padding(.horizontal, 28).padding(.vertical, 24)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .onChange(of: conversation.messages.last?.text) {
                if let id = conversation.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }

    private func toolActivities(for message: ChatMessage) -> [ToolActivityPresentation] {
        guard message.role == .assistant else { return [] }
        let nextUserMessageDate = conversation.messages.first {
            $0.role == .user && $0.createdAt > message.createdAt
        }?.createdAt
        return (model.toolActivitiesByConversation[conversation.id] ?? []).filter { activity in
            activity.requestedAt >= message.createdAt
                && nextUserMessageDate.map { activity.requestedAt < $0 } ?? true
        }
    }

    private func request(_ message: ChatMessage) -> some View {
        HStack(alignment: .top) {
            Spacer(minLength: 80)
            Text(message.text).textSelection(.enabled)
                .padding(.horizontal, 14).padding(.vertical, 11)
                .background(Color.accentColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 16))
        }
        .id(message.id)
        .accessibilityLabel("Your request")
    }
}

private struct RecoveryBanner: View {
    let checkpoint: AgentRunCheckpoint
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Recovered saved context").font(.headline)
                Text("Saved through activity \(checkpoint.sequence). Continue from the saved conversation in a new run.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button("Dismiss", action: retry)
                .buttonStyle(.bordered)
        }
        .padding(12)
        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

struct TaskPlanCard: View {
    let steps: [TaskPlanStep]
    var body: some View {
        GroupBox("Plan") {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(steps) { step in
                    Label(step.title, systemImage: icon(step.state))
                        .foregroundStyle(step.state == .active ? Color.accentColor : step.state == .blocked ? Color.orange : Color.primary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
        }
    }
    private func icon(_ state: TaskPlanStep.State) -> String {
        switch state {
        case .pending: "circle"
        case .active: "circle.dotted"
        case .complete: "checkmark.circle.fill"
        case .blocked: "exclamationmark.circle.fill"
        }
    }
}

struct TaskApprovalCard: View {
    let approval: TaskApprovalRequest
    let onDecision: (TaskApprovalRequest.Decision) -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label(approval.title, systemImage: "hand.raised.fill").font(.headline).foregroundStyle(.orange)
                Text(approval.explanation)
                LabeledContent("Target", value: approval.target).font(.callout)
                Label(
                    approval.sendsDataOffDevice ? "This action sends data off this Mac" : "This action stays on this Mac",
                    systemImage: approval.sendsDataOffDevice ? "network" : "lock.fill"
                ).font(.caption).foregroundStyle(.secondary)
                if approval.decision == .pending {
                    HStack {
                        Button("Deny", role: .cancel) { onDecision(.denied) }
                        Spacer()
                        Button("Allow Once") { onDecision(.allowedOnce) }.buttonStyle(.borderedProminent)
                    }
                } else {
                    Text(approval.decision.rawValue).font(.callout).foregroundStyle(.secondary)
                }
            }.padding(4)
        }
        .accessibilityLabel("Permission request: \(approval.title)")
    }
}

struct ArtifactActivityCard: View {
    let artifact: TaskArtifact
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Image(systemName: artifact.kind.systemImage).font(.title2).foregroundStyle(Color.accentColor)
                    .frame(width: 36, height: 36).background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text(artifact.title).font(.headline)
                    Text(artifact.detail.isEmpty ? "Artifact" : artifact.detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }.padding(10).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityHint("Shows this artifact in the inspector")
    }
}
