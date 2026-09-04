import SwiftUI

struct ConversationTabStrip: View {
    @Bindable var model: AppModel
    @State private var hoveredTabID: UUID?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                ForEach(openConversations) { conversation in tab(conversation) }
                Button("New Chat", systemImage: "plus") { model.newConversation() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .frame(width: 28, height: 28)
                    .help("New Chat")
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
        .frame(height: 36)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var openConversations: [Conversation] {
        model.openConversationIDs.compactMap { id in model.conversations.first { $0.id == id } }
    }

    private func tab(_ conversation: Conversation) -> some View {
        let isActive = conversation.id == model.selectedConversationID
        return HStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "message").font(.caption).foregroundStyle(.secondary)
                Text(conversation.title)
                    .font(.callout.weight(isActive ? .medium : .regular))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isActive || hoveredTabID == conversation.id {
                Button("Close \(conversation.title)", systemImage: "xmark") {
                    model.closeTab(conversation.id)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .font(.caption2)
                .frame(width: 20, height: 20)
            } else {
                Color.clear.frame(width: 20, height: 20)
            }
        }
        .padding(.horizontal, 10)
        .frame(minWidth: 160, idealWidth: 176, maxWidth: 220, minHeight: 28)
        .background(
            isActive ? Color(nsColor: .textBackgroundColor)
                : (hoveredTabID == conversation.id ? Color.secondary.opacity(0.1) : .clear),
            in: RoundedRectangle(cornerRadius: 7)
        )
        .overlay {
            if isActive { RoundedRectangle(cornerRadius: 7).stroke(.separator.opacity(0.5), lineWidth: 0.5) }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.selectConversation(conversation.id) }
        .onHover { isHovering in hoveredTabID = isHovering ? conversation.id : nil }
        .contextMenu {
            Button("Close Tab") { model.closeTab(conversation.id) }
            Button("Close Other Tabs") { model.closeOtherTabs(keeping: conversation.id) }
                .disabled(model.openConversationIDs.count < 2)
            Button("Close Tabs to the Right") { model.closeTabsToRight(of: conversation.id) }
                .disabled(model.openConversationIDs.last == conversation.id)
        }
    }
}
