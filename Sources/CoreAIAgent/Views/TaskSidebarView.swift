import SwiftUI

struct TaskSidebarView: View {
    @Bindable var model: AppModel
    @State private var search = ""
    @State private var workspaceBeingRenamed: UUID?
    @State private var workspaceName = ""
    @State private var pendingDeletion: PendingDeletion?
    @State private var expandedWorkspaceIDs = Set<UUID>()

    private enum PendingDeletion: Identifiable {
        case conversation(Conversation)
        case workspace(ConversationFolder)

        var id: UUID {
            switch self {
            case .conversation(let conversation): conversation.id
            case .workspace(let workspace): workspace.id
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search tasks", text: $search)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    taskSection("Needs Attention", attentionTasks)
                    taskSection("Pinned", pinnedTasks)
                    if !model.folders.isEmpty { workspaceSection }
                    taskSection("Recents", recentTasks)
                }
                .padding(.horizontal, 10)
                .padding(.top, 2)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .onChange(of: model.selectedConversationID) {
            if let id = model.selectedConversationID { model.selectConversation(id) }
        }
        .toolbar {
            Button("New Task", systemImage: "square.and.pencil") { model.newConversation() }
            Menu("Add", systemImage: "plus") {
                Button("New Workspace", systemImage: "folder.badge.plus") { model.addFolder() }
            }
        }
        .alert("Rename Workspace", isPresented: Binding(
            get: { workspaceBeingRenamed != nil },
            set: { if !$0 { workspaceBeingRenamed = nil } }
        )) {
            TextField("Workspace name", text: $workspaceName)
            Button("Cancel", role: .cancel) { workspaceBeingRenamed = nil }
            Button("Rename") {
                if let id = workspaceBeingRenamed { model.renameFolder(id, to: workspaceName) }
                workspaceBeingRenamed = nil
            }
        }
        .confirmationDialog(
            deletionTitle,
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(deletionButtonTitle, role: .destructive) { performPendingDeletion() }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text(deletionMessage)
        }
    }

    private func beginRenaming(_ folder: ConversationFolder) {
        workspaceName = folder.name
        workspaceBeingRenamed = folder.id
    }

    @ViewBuilder private func taskSection(_ title: String, _ items: [Conversation]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                sectionHeader(title)
                ForEach(items) { conversation in
                    taskRow(conversation)
                        .id("\(title):\(conversation.id.uuidString)")
                        .draggable(conversationDragValue(conversation.id))
                        .dropDestination(for: String.self) { values, _ in
                            _ = reorderConversation(
                                values, before: conversation.id, within: items, folderID: conversation.folderID
                            )
                        }
                }
            }
        }
    }

    private var workspaceSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionHeader("Workspaces")
            ForEach(model.folders) { folder in
                workspace(folder)
                    .draggable(workspaceDragValue(folder.id))
                    .dropDestination(for: String.self) { values, _ in
                        _ = reorderWorkspace(values, before: folder.id)
                    }
            }
        }
    }

    private func workspace(_ folder: ConversationFolder) -> some View {
        let items = tasks(in: folder.id)
        let isExpanded = expandedWorkspaceIDs.contains(folder.id)
        return VStack(alignment: .leading, spacing: 3) {
            Button {
                if isExpanded { expandedWorkspaceIDs.remove(folder.id) }
                else { expandedWorkspaceIDs.insert(folder.id) }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 11)
                    Image(systemName: "folder")
                        .foregroundStyle(Color.accentColor)
                    Text(folder.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(height: 30)
            .contextMenu {
                Button("New Task in \(folder.name)") { model.newConversation(in: folder.id) }
                Button("Rename Workspace…") { beginRenaming(folder) }
                Divider()
                Button("Delete Workspace…", role: .destructive) { pendingDeletion = .workspace(folder) }
            }
            .dropDestination(for: String.self) { values, _ in
                _ = moveConversations(values, to: folder.id)
            }

            if isExpanded {
                ForEach(items) { conversation in
                    taskRow(conversation, indentation: 28)
                        .id("workspace:\(folder.id.uuidString):\(conversation.id.uuidString)")
                        .draggable(conversationDragValue(conversation.id))
                        .dropDestination(for: String.self) { values, _ in
                            _ = reorderConversation(values, before: conversation.id, within: items, folderID: folder.id)
                        }
                }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 2)
            .frame(height: 20, alignment: .bottomLeading)
    }

    private var attentionTasks: [Conversation] {
        model.conversations.filter { needsAttention($0) && matches($0) }
    }

    private var pinnedTasks: [Conversation] {
        model.conversations.filter { $0.isPinned && !needsAttention($0) && matches($0) }
    }

    private var recentTasks: [Conversation] {
        model.conversations.filter { !$0.isPinned && $0.folderID == nil && !needsAttention($0) && matches($0) }
    }

    private func tasks(in folderID: UUID) -> [Conversation] {
        model.conversations.filter { !$0.isPinned && $0.folderID == folderID && !needsAttention($0) && matches($0) }
    }

    private func needsAttention(_ conversation: Conversation) -> Bool {
        model.hasPendingApproval(for: conversation.id)
            || conversation.taskState(durableRunStatus: model.runStatusByConversation[conversation.id]) == .failed
    }

    private func matches(_ conversation: Conversation) -> Bool {
        search.isEmpty || conversation.title.localizedCaseInsensitiveContains(search)
            || conversation.messages.contains { $0.text.localizedCaseInsensitiveContains(search) }
            || (model.artifactsByConversation[conversation.id] ?? []).contains {
                $0.title.localizedCaseInsensitiveContains(search) || $0.detail.localizedCaseInsensitiveContains(search)
            }
            || (model.toolActivitiesByConversation[conversation.id] ?? []).contains {
                $0.displayName.localizedCaseInsensitiveContains(search)
                    || ($0.result?.content.localizedCaseInsensitiveContains(search) == true)
            }
    }

    private func taskRow(_ conversation: Conversation, indentation: CGFloat = 0) -> some View {
        let state = conversation.taskState(
            hasPendingApproval: model.hasPendingApproval(for: conversation.id),
            durableRunStatus: model.runStatusByConversation[conversation.id]
        )
        let isSelected = model.selectedConversationID == conversation.id
        return Button {
            model.selectConversation(conversation.id)
        } label: {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(conversation.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                        .lineLimit(1)
                    if let summary = conversation.messages.last?.text, !summary.isEmpty {
                        Text(summary.replacingOccurrences(of: "\n", with: " "))
                            .font(.caption)
                            .foregroundStyle(isSelected ? Color.white.opacity(0.78) : Color.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if state == .working {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(isSelected ? .white : .secondary)
                }
                else if state == .waitingForApproval || state == .failed {
                    Image(systemName: state.systemImage)
                        .foregroundStyle(isSelected ? Color.white : (state == .failed ? Color.red : Color.orange))
                        .accessibilityLabel(state.label)
                }
            }
            .padding(.leading, indentation + 10)
            .padding(.trailing, 10)
            .frame(maxWidth: .infinity, minHeight: 52, maxHeight: 52, alignment: .leading)
            .background(
                isSelected ? Color.accentColor : Color.clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Open in Tab") { model.selectConversation(conversation.id) }
            Button(conversation.isPinned ? "Unpin" : "Pin") { model.togglePin(conversation.id) }
            Menu("Move to Workspace") {
                Button("No Workspace") { model.moveConversation(conversation.id, to: nil) }
                ForEach(model.folders) { folder in
                    Button(folder.name) { model.moveConversation(conversation.id, to: folder.id) }
                }
            }
            Divider()
            Button("Delete Task…", role: .destructive) {
                pendingDeletion = .conversation(conversation)
            }
        }
    }

    private func conversationDragValue(_ id: UUID) -> String { "conversation:\(id.uuidString)" }
    private func workspaceDragValue(_ id: UUID) -> String { "workspace:\(id.uuidString)" }

    private func draggedID(_ values: [String], prefix: String) -> UUID? {
        values.lazy.compactMap { value -> UUID? in
            guard value.hasPrefix(prefix) else { return nil }
            return UUID(uuidString: String(value.dropFirst(prefix.count)))
        }.first
    }

    private func reorderConversation(
        _ values: [String], before targetID: UUID, within items: [Conversation], folderID: UUID?
    ) -> Bool {
        guard let sourceID = draggedID(values, prefix: "conversation:"), sourceID != targetID else { return false }
        if model.conversations.first(where: { $0.id == sourceID })?.folderID != folderID {
            model.moveConversation(sourceID, to: folderID)
        }
        let ids = items.map(\.id)
        guard let source = ids.firstIndex(of: sourceID), let target = ids.firstIndex(of: targetID) else { return true }
        model.reorderConversations(ids, from: IndexSet(integer: source), to: target)
        return true
    }

    private func moveConversations(_ values: [String], to folderID: UUID?) -> Bool {
        guard let id = draggedID(values, prefix: "conversation:") else { return false }
        model.moveConversation(id, to: folderID)
        if let folderID { expandedWorkspaceIDs.insert(folderID) }
        return true
    }

    private func reorderWorkspace(_ values: [String], before targetID: UUID) -> Bool {
        guard let sourceID = draggedID(values, prefix: "workspace:"), sourceID != targetID,
              let source = model.folders.firstIndex(where: { $0.id == sourceID }),
              let target = model.folders.firstIndex(where: { $0.id == targetID }) else { return false }
        model.reorderFolders(from: IndexSet(integer: source), to: target)
        return true
    }

    private var deletionTitle: String {
        switch pendingDeletion {
        case .conversation: "Delete Task?"
        case .workspace: "Delete Workspace?"
        case nil: "Delete?"
        }
    }

    private var deletionButtonTitle: String {
        switch pendingDeletion {
        case .conversation: "Delete Task"
        case .workspace: "Delete Workspace"
        case nil: "Delete"
        }
    }

    private var deletionMessage: String {
        switch pendingDeletion {
        case .conversation(let conversation):
            "\"\(conversation.title)\" and its local history will be permanently deleted."
        case .workspace(let workspace):
            "\"\(workspace.name)\" will be deleted. Its tasks will be kept and moved to Recents."
        case nil:
            ""
        }
    }

    private func performPendingDeletion() {
        switch pendingDeletion {
        case .conversation(let conversation): model.deleteConversation(conversation.id)
        case .workspace(let workspace): model.deleteFolder(workspace.id)
        case nil: break
        }
        pendingDeletion = nil
    }
}
