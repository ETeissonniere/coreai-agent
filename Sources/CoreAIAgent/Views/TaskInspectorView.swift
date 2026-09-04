import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TaskInspectorView: View {
    @Bindable var model: AppModel
    @State private var saveError: String?

    var body: some View {
        VStack(spacing: 0) {
            Picker("Inspector", selection: $model.inspectorSection) {
                ForEach(TaskInspectorSection.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().padding(12)
            Divider()
            switch model.inspectorSection {
            case .artifacts: artifacts
            case .context: context
            case .timing: timing
            case .activity: activity
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .alert("Couldn’t Save Document", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK") { saveError = nil }
        } message: {
            Text(saveError ?? "Unknown error")
        }
    }

    private var timing: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                InspectorGroup("Model") {
                    LabeledContent("State", value: model.modelPhase.label)
                    if let duration = model.lastModelLoadDuration {
                        timingRow("Last load", duration)
                    }
                    Text("Model loading happens before a response and is not included in its total.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                InspectorGroup("Response") {
                    if let metrics = model.lastMetrics {
                        timingRow("Total", metrics.elapsed)
                        timingRow("Time to first token", metrics.timeToFirstToken)
                    } else {
                        Text("Timing appears after a response.").foregroundStyle(.secondary)
                    }
                }
                if let metrics = model.lastMetrics {
                    InspectorGroup("Breakdown") {
                        timingRow("Initial prefill", metrics.initialPrefill)
                        timingRow("Tool-call generation", metrics.toolCallGeneration)
                        timingRow("Tool execution", metrics.toolExecution)
                        timingRow("Prefill after tools", metrics.continuationPrefill)
                        timingRow("Answer decode", metrics.decode)
                        let measured = metrics.initialPrefill + metrics.toolCallGeneration
                            + metrics.toolExecution + metrics.continuationPrefill + metrics.decode
                        timingRow("Other", max(.zero, metrics.elapsed - measured))
                    }
                }
            }.padding(12)
        }
    }

    private func timingRow(_ label: String, _ duration: Duration) -> some View {
        LabeledContent(label, value: duration.formatted(.units(
            allowed: [.seconds, .milliseconds], width: .abbreviated,
            maximumUnitCount: 1, zeroValueUnits: .show(length: 1)
        )))
    }

    @ViewBuilder private var artifacts: some View {
        let items = model.selectedConversationID.flatMap { model.artifactsByConversation[$0] } ?? []
        if items.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "doc.on.doc").font(.title).foregroundStyle(.tertiary)
                Text("No Artifacts Yet").font(.headline)
                Text("Documents, files, and research outputs created by this task appear here.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .top)
        } else {
            List(items, selection: $model.selectedArtifactID) { artifact in
                Label {
                    VStack(alignment: .leading) {
                        Text(artifact.title)
                        if !artifact.detail.isEmpty { Text(artifact.detail).font(.caption).foregroundStyle(.secondary) }
                    }
                } icon: { Image(systemName: artifact.kind.systemImage) }
                .tag(artifact.id)
            }
            if let artifact = selectedArtifact {
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text(artifact.title).font(.headline)
                    LabeledContent("Version", value: artifact.revision.formatted())
                    if let content = artifact.content, !content.isEmpty {
                        ScrollView {
                            MarkdownContentView(source: content)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 260)
                        .padding(10)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                    } else {
                        Text("Preview isn’t available for this artifact.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if let url = artifact.fileURL {
                        HStack {
                            Button("Open") { NSWorkspace.shared.open(url) }
                            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                            Spacer()
                            Button("Save As…") { presentSavePanel(for: artifact) }
                        }
                    } else if artifact.kind == .document, artifact.content != nil {
                        Button("Save…") { presentSavePanel(for: artifact) }
                            .buttonStyle(.borderedProminent)
                    }
                }.padding(12)
            }
        }
    }

    private var selectedArtifact: TaskArtifact? {
        guard let conversationID = model.selectedConversationID, let artifactID = model.selectedArtifactID else { return nil }
        return model.artifactsByConversation[conversationID]?.first { $0.id == artifactID }
    }

    private func presentSavePanel(for artifact: TaskArtifact) {
        guard let conversationID = model.selectedConversationID else { return }
        let panel = NSSavePanel()
        panel.title = "Save Markdown Document"
        panel.prompt = "Save"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowsOtherFileTypes = false
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        let safeName = artifact.title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = safeName.hasSuffix(".md") ? safeName : "\(safeName).md"
        panel.begin { response in
            guard response == .OK, var destination = panel.url else { return }
            if destination.pathExtension.lowercased() != "md" {
                destination.appendPathExtension("md")
            }
            Task { @MainActor in
                do {
                    try await model.saveMarkdownArtifact(artifact.id, in: conversationID, to: destination)
                } catch {
                    saveError = error.localizedDescription
                }
            }
        }
    }

    private var context: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                InspectorGroup("Context Window") {
                    if let context = model.selectedContext {
                        ContextUsageView(
                            context: context,
                            cache: model.selectedKVCache
                        )
                        LabeledContent("Compactions", value: context.compactionCount.formatted())
                    } else { Text("Context statistics appear after the task starts.").foregroundStyle(.secondary) }
                }
                InspectorGroup("Performance") {
                    if let metrics = model.lastMetrics {
                        LabeledContent("Generated", value: "\(metrics.generatedTokens) tokens")
                        LabeledContent("Prefill", value: "\(String(format: "%.1f", metrics.prefillTokensPerSecond)) tok/s")
                        LabeledContent("Decode", value: "\(String(format: "%.1f", metrics.decodeTokensPerSecond)) tok/s")
                        LabeledContent("Reasoning", value: "\(metrics.reasoningTokens) tokens")
                    } else { Text("Performance statistics appear after a response.").foregroundStyle(.secondary) }
                }
                if !model.enabledSkills.isEmpty {
                    InspectorGroup("Pinned Skills") {
                        ForEach(model.enabledSkills) { skill in
                            SkillIdentityView(skill: skill)
                        }
                    }
                }
                InspectorGroup("Skills") {
                    Text("Selected automatically for each request. Type / to invoke one explicitly.")
                        .font(.caption).foregroundStyle(.secondary)
                    if model.availableSkills.isEmpty {
                        Text("No skills were discovered in the app, user, or workspace skill folders.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.availableSkills) { skill in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: skill.systemImage)
                                    .frame(width: 18, alignment: .center)
                                    .padding(.top, 2)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(skill.name).lineLimit(1)
                                    Text(skill.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Text("Auto")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                    .background(.quaternary, in: Capsule())
                            }
                        }
                    }
                }
            }.padding(12)
        }
    }

    private var activity: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                InspectorGroup("Privacy") {
                    Label("Model inference stays on this Mac", systemImage: "lock.fill")
                    Text("Network tools must disclose that boundary before running.").font(.caption).foregroundStyle(.secondary)
                }
                InspectorGroup("Task") {
                    if let conversation = selectedConversation {
                        let state = conversation.taskState(hasPendingApproval: model.hasPendingApproval(for: conversation.id))
                        LabeledContent("State", value: state.label)
                        LabeledContent("Messages", value: conversation.messages.count.formatted())
                        LabeledContent("Updated", value: conversation.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                if let conversationID = model.selectedConversationID,
                   let failure = model.titleGenerationFailuresByConversation[conversationID] {
                    InspectorGroup("Conversation title") {
                        Label(failure.userMessage, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }
                }
                InspectorGroup("Permissions") {
                    let approvals = model.selectedConversationID.flatMap { model.approvalsByConversation[$0] } ?? []
                    if approvals.isEmpty { Text("No permission requests in this task.").foregroundStyle(.secondary) }
                    else { ForEach(approvals) { Label($0.title, systemImage: $0.decision == .pending ? "hand.raised" : "checkmark.circle") } }
                }
                InspectorGroup("Tools") {
                    let tools = model.selectedConversationID.flatMap { model.toolActivitiesByConversation[$0] } ?? []
                    if tools.isEmpty {
                        Text("No tools used in this task.").foregroundStyle(.secondary)
                    } else {
                        ForEach(tools) { tool in
                            HStack {
                                Image(systemName: tool.state.systemImage)
                                Text(tool.displayName).lineLimit(1)
                                Spacer()
                                Text(tool.state.label).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }.padding(12)
        }
    }

    private var selectedConversation: Conversation? {
        guard let index = model.selectedIndex else { return nil }
        return model.conversations[index]
    }
}

private struct SkillIdentityView: View {
    let skill: AgentSkillMetadata

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: skill.systemImage).frame(width: 18, alignment: .center)
            Text(skill.name).lineLimit(1)
            Spacer(minLength: 0)
        }
    }
}

private struct InspectorGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 9) { content }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
        }
    }
}
