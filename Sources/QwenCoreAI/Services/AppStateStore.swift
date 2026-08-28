import Foundation

struct PersistedAppState: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int = Self.currentVersion
    var conversations: [Conversation]
    var folders: [ConversationFolder]
    var openConversationIDs: [UUID]
    var selectedConversationID: UUID?
    var draftAttachments: [UUID: [ComposerAttachment]]?

    init(
        conversations: [Conversation],
        folders: [ConversationFolder],
        openConversationIDs: [UUID],
        selectedConversationID: UUID?,
        draftAttachments: [UUID: [ComposerAttachment]]? = nil
    ) {
        self.conversations = conversations
        self.folders = folders
        self.openConversationIDs = openConversationIDs
        self.selectedConversationID = selectedConversationID
        self.draftAttachments = draftAttachments
    }

    func restored() -> Self {
        let conversationIDs = Set(conversations.map(\.id))
        let validFolderIDs = Set(folders.map(\.id))
        var restoredConversations = conversations

        for conversationIndex in restoredConversations.indices {
            if let folderID = restoredConversations[conversationIndex].folderID,
               !validFolderIDs.contains(folderID) {
                restoredConversations[conversationIndex].folderID = nil
            }
            for messageIndex in restoredConversations[conversationIndex].messages.indices
            where restoredConversations[conversationIndex].messages[messageIndex].generationState == .streaming {
                restoredConversations[conversationIndex].messages[messageIndex].generationState = .stopped
                restoredConversations[conversationIndex].messages[messageIndex].wasStopped = true
            }
            for messageIndex in restoredConversations[conversationIndex].messages.indices {
                restoredConversations[conversationIndex].messages[messageIndex].reasoning = nil
            }
        }

        let restoredOpenIDs = openConversationIDs.reduce(into: [UUID]()) { result, id in
            if conversationIDs.contains(id), !result.contains(id) { result.append(id) }
        }
        let restoredSelection = selectedConversationID.flatMap {
            conversationIDs.contains($0) ? $0 : nil
        } ?? restoredOpenIDs.first ?? restoredConversations.first?.id

        return Self(
            conversations: restoredConversations,
            folders: folders,
            openConversationIDs: restoredOpenIDs.isEmpty
                ? restoredSelection.map { [$0] } ?? []
                : restoredOpenIDs,
            selectedConversationID: restoredSelection,
            draftAttachments: draftAttachments?.filter { conversationIDs.contains($0.key) }
        )
    }
}

protocol AppStateStoring: Sendable {
    func load() throws -> PersistedAppState?
    func save(_ state: PersistedAppState) throws
}

struct JSONAppStateStore: AppStateStoring, Sendable {
    let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL
    }

    func load() throws -> PersistedAppState? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let state = try JSONDecoder.appState.decode(
            PersistedAppState.self,
            from: Data(contentsOf: fileURL)
        )
        guard state.version == PersistedAppState.currentVersion else {
            throw AppStateStoreError.unsupportedVersion(state.version)
        }
        return state.restored()
    }

    func save(_ state: PersistedAppState) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder.appState.encode(state.withoutReasoning())
        try data.write(to: fileURL, options: .atomic)
    }

    private static var defaultFileURL: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return applicationSupport
            .appending(path: "Qwen Core AI", directoryHint: .isDirectory)
            .appending(path: "AppState.json", directoryHint: .notDirectory)
    }
}

private extension PersistedAppState {
    func withoutReasoning() -> Self {
        var redacted = self
        for conversationIndex in redacted.conversations.indices {
            for messageIndex in redacted.conversations[conversationIndex].messages.indices {
                redacted.conversations[conversationIndex].messages[messageIndex].reasoning = nil
            }
        }
        return redacted
    }
}

enum AppStateStoreError: LocalizedError {
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            "The saved app state uses unsupported format version \(version)."
        }
    }
}

private extension JSONEncoder {
    static var appState: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var appState: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
