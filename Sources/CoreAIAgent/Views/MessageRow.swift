import AppKit
import SwiftUI

struct MessageRow: View {
    let message: ChatMessage
    var toolActivities: [ToolActivityPresentation] = []
    var executionTrace: AssistantExecutionTrace? = nil
    var activePhase: ModelPhase? = nil
    var retry: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if message.role == .user { Spacer(minLength: 80) }
            if message.role == .assistant {
                Image(systemName: "apple.intelligence")
                    .frame(width: 28, height: 28)
                    .background(.quaternary, in: Circle())
                    .accessibilityHidden(true)
            }
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 10) {
                if message.role == .assistant {
                    if message.reasoning?.isEmpty == false || !toolActivities.isEmpty {
                        ReasoningDisclosureView(
                            text: message.reasoning ?? "",
                            toolActivities: toolActivities,
                            executionTrace: executionTrace,
                            state: message.generationState ?? .complete,
                            isActivelyThinking: message.generationState == .streaming && message.text.isEmpty,
                            metrics: message.metrics
                        )
                    }
                    if message.generationState == .streaming,
                       message.text.isEmpty, message.reasoning == nil {
                        GenerationWaitingView(
                            phase: activePhase ?? .generating,
                            startedAt: message.createdAt
                        )
                    } else if !message.text.isEmpty {
                        MarkdownContentView(source: message.text)
                            .padding(.top, message.reasoning?.isEmpty == false ? 8 : 0)
                    }
                } else {
                    Text(message.text)
                        .textSelection(.enabled)
                        .padding(12)
                        .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 16))
                }
                if message.wasStopped {
                    Label("Stopped", systemImage: "stop.fill").font(.caption).foregroundStyle(.secondary)
                }
                if let retry, message.generationState == .failed {
                    Button("Edit and Try Again", systemImage: "arrow.clockwise", action: retry)
                        .buttonStyle(.bordered)
                }
                if let metrics = message.metrics {
                    Text("\(metrics.generatedTokens) tokens · prefill \(metrics.prefillTokensPerSecond, format: .number.precision(.fractionLength(1))) tok/s · decode \(metrics.decodeTokensPerSecond, format: .number.precision(.fractionLength(1))) tok/s · TTFT \(metrics.timeToFirstToken.formatted(.time(pattern: .minuteSecond(padMinuteToLength: 1))))")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            if message.role == .assistant { Spacer(minLength: 40) }
        }
    }
}

private struct GenerationWaitingView: View {
    let phase: ModelPhase
    let startedAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 14, height: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.callout)
                    if elapsed(at: context.date) >= 3 {
                        Text("\(formattedElapsed(at: context.date)) elapsed")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(label)
            .accessibilityValue("\(formattedElapsed(at: context.date)) elapsed")
        }
    }

    private var label: String {
        switch phase {
        case .compacting: "Compacting context…"
        case .generating: "Reading conversation…"
        case .loading: "Loading model…"
        case .missing: "Waiting for model…"
        case .ready: "Preparing response…"
        case .failed: "Generation unavailable"
        }
    }

    private func elapsed(at date: Date) -> Int {
        max(0, Int(date.timeIntervalSince(startedAt)))
    }

    private func formattedElapsed(at date: Date) -> String {
        let seconds = elapsed(at: date)
        let minutes = seconds / 60
        let remainder = seconds % 60
        return minutes > 0 ? "\(minutes)m \(remainder)s" : "\(seconds)s"
    }
}

private struct ReasoningDisclosureView: View {
    let text: String
    let toolActivities: [ToolActivityPresentation]
    let executionTrace: AssistantExecutionTrace?
    let state: MessageGenerationState
    let isActivelyThinking: Bool
    let metrics: GenerationMetrics?
    @State private var isExpanded: Bool

    init(
        text: String,
        toolActivities: [ToolActivityPresentation],
        executionTrace: AssistantExecutionTrace?,
        state: MessageGenerationState,
        isActivelyThinking: Bool,
        metrics: GenerationMetrics?
    ) {
        self.text = text
        self.toolActivities = toolActivities
        self.executionTrace = executionTrace
        self.state = state
        self.isActivelyThinking = isActivelyThinking
        self.metrics = metrics
        _isExpanded = State(initialValue: isActivelyThinking)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    if isActivelyThinking {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 14, height: 14)
                    }

                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 5)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(orderedEntries) { entry in
                        switch entry.content {
                        case .reasoning(let reasoning):
                            ExecutionTraceStep(icon: "brain.head.profile", tint: .secondary) {
                                reasoningView(reasoning)
                            }
                        case .tool(let invocationID):
                            if let activity = toolActivities.first(where: { $0.id == invocationID }) {
                                ExecutionTraceStep(icon: activity.isWebActivity ? "globe" : "wrench.and.screwdriver", tint: statusColor(activity.state)) {
                                    InlineToolActivityView(activity: activity)
                                }
                            }
                        }
                    }

                    HStack(spacing: 12) {
                        Spacer()
                        if !text.isEmpty {
                            Button("Copy thinking", systemImage: "doc.on.doc") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(text, forType: .string)
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.plain)
                            .foregroundStyle(.tertiary)
                            .help("Copy thinking")
                        }
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Divider()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: isActivelyThinking) {
            withAnimation(.easeInOut(duration: 0.15)) {
                isExpanded = isActivelyThinking
            }
        }
        .onChange(of: text) {
            if isActivelyThinking, !isExpanded {
                isExpanded = true
            }
        }
    }

    private var orderedEntries: [AssistantExecutionTrace.Entry] {
        if let executionTrace, !executionTrace.entries.isEmpty { return executionTrace.entries }
        var fallback: [AssistantExecutionTrace.Entry] = []
        if !text.isEmpty { fallback.append(.init(content: .reasoning(text))) }
        fallback.append(contentsOf: toolActivities.map { .init(content: .tool($0.id)) })
        return fallback
    }

    private func reasoningView(_ reasoning: String) -> some View {
        Text(reasoning)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineSpacing(3)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var summary: String {
        switch state {
        case .streaming: "Working…"
        case .stopped: "Work stopped"
        case .failed: "Work interrupted"
        case .complete:
            metrics.map { "Worked for \(formatted($0.elapsed))" } ?? "View work"
        }
    }

    private func statusColor(_ state: ToolActivityState) -> Color {
        switch state {
        case .succeeded: .green
        case .waitingForApproval, .unavailable: .orange
        case .failed: .red
        default: .secondary
        }
    }

    private func formatted(_ duration: Duration) -> String {
        let components = duration.components
        let totalSeconds = max(0, Int(components.seconds))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return minutes > 0 ? "\(minutes)m \(seconds)s" : "\(seconds)s"
    }
}

private struct ExecutionTraceStep<Content: View>: View {
    let icon: String
    let tint: Color
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.caption.weight(.medium))
                .foregroundStyle(tint)
                .frame(width: 18, height: 18)
                .background(tint.opacity(0.1), in: Circle())
            content
        }
    }
}

private struct InlineToolActivityView: View {
    let activity: ToolActivityPresentation
    @State private var isExpanded: Bool

    init(activity: ToolActivityPresentation) {
        self.activity = activity
        _isExpanded = State(initialValue: activity.state == .failed || activity.state == .unavailable)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(activity.displayName)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.primary)
                        Text(activity.state.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if activity.state == .running {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: activity.state.systemImage)
                            .font(.caption)
                            .foregroundStyle(statusColor)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !isExpanded, let preview = collapsedErrorPreview {
                Text(preview)
                    .font(.caption)
                    .foregroundStyle(activity.state == .failed || activity.result?.isError == true ? Color.red : Color.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 7) {
                    LabeledContent("Effect", value: effectLabel)
                    if !activity.invocation.argumentsJSON.isEmpty {
                        Text(activity.invocation.argumentsJSON)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
                    }
                    if let result = activity.displayResult {
                        Text(result)
                            .font(.caption)
                            .foregroundStyle(activity.result?.isError == true ? Color.red : Color.secondary)
                            .textSelection(.enabled)
                    }
                    ForEach(activity.sourceURLs, id: \.self) { url in
                        Link(url.host() ?? url.absoluteString, destination: url)
                            .font(.caption)
                    }
                }
                .padding(.top, 2)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tool: \(activity.displayName), \(activity.state.label)")
    }

    private var collapsedErrorPreview: String? {
        guard activity.state == .failed || activity.state == .unavailable else { return nil }
        return activity.displayResult
    }

    private var statusColor: Color {
        switch activity.state {
        case .succeeded: .green
        case .waitingForApproval, .unavailable: .orange
        case .failed: .red
        default: .secondary
        }
    }

    private var effectLabel: String {
        switch activity.invocation.sideEffect {
        case .none: "Read only"
        case .localWrite: "Writes on this Mac"
        case .networkRead: "Uses the network"
        case .externalMutation: "Changes an external service"
        }
    }
}
