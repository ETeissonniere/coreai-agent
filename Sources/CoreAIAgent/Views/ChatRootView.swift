import SwiftUI

struct ChatRootView: View {
    @Bindable var model: AppModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            TaskSidebarView(model: model)
        } detail: {
            VStack(spacing: 0) {
                ConversationTabStrip(model: model)
                if let conversation = selectedConversation {
                    taskHeader(conversation)
                    Divider()
                    if conversation.messages.isEmpty { TaskWelcomeView(model: model) }
                    else { TaskTimelineView(model: model, conversation: conversation) }
                    Divider()
                    ComposerView(model: model)
                } else {
                    ContentUnavailableView(
                        "No Open Task", systemImage: "rectangle.stack",
                        description: Text("Open a task from the sidebar or start a new one.")
                    ).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .navigationTitle(selectedConversation?.title ?? "CoreAI Agent")
            .toolbar {
                ToolbarItem {
                    Button("Task Inspector", systemImage: "sidebar.trailing") { model.showInspector.toggle() }
                }
            }
            .inspector(isPresented: $model.showInspector) {
                TaskInspectorView(model: model).inspectorColumnWidth(min: 280, ideal: 320, max: 420)
            }
        }
    }

    private var selectedConversation: Conversation? {
        guard let index = model.selectedIndex else { return nil }
        return model.conversations[index]
    }

    private func taskHeader(_ conversation: Conversation) -> some View {
        let state = conversation.taskState(
            hasPendingApproval: model.hasPendingApproval(for: conversation.id),
            durableRunStatus: model.runStatusByConversation[conversation.id]
        )
        return HStack(spacing: 10) {
            Label("Local agent", systemImage: "apple.intelligence")
            Text("\(conversation.modelProfile.modelName) · \(conversation.modelProfile.quantization)")
                .foregroundStyle(.secondary)
            Label("On-device", systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary)
            Spacer()
            if state == .working {
                ProgressView().controlSize(.small)
                Text(state.label).font(.callout).foregroundStyle(.secondary)
            } else {
                Label(state.label, systemImage: state.systemImage)
                    .font(.callout).foregroundStyle(state == .failed ? Color.red : Color.secondary)
            }
        }
        .font(.callout).padding(.horizontal, 18).padding(.vertical, 10)
    }
}

private struct TaskWelcomeView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "apple.intelligence").font(.system(size: 38)).foregroundStyle(.secondary)
            VStack(spacing: 6) {
                Text("What should we work on?").font(.title2.weight(.semibold))
                Text(statusText).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            HStack(spacing: 10) {
                suggestion("Research a topic", icon: "globe")
                suggestion("Create a document", icon: "doc.richtext")
                suggestion("Analyze files", icon: "doc.text.magnifyingglass")
            }
            Spacer()
        }
        .padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statusText: String {
        switch model.modelPhase {
        case .missing: "The bundled model is unavailable."
        case let .failed(message): "The bundled model could not load: \(message)"
        case .loading: "Preparing the local model…"
        default: "Describe an outcome. The agent can plan work, use skills, and create artifacts."
        }
    }

    private func suggestion(_ title: String, icon: String) -> some View {
        Button { model.draft = title } label: {
            Label(title, systemImage: icon).padding(.horizontal, 12).padding(.vertical, 8)
        }.buttonStyle(.bordered)
    }
}
