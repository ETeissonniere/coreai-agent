import AppKit
import SwiftUI

@main
struct QwenCoreAIApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ChatRootView(model: model)
                .frame(minWidth: 760, minHeight: 560)
                .onChange(of: scenePhase) {
                    if scenePhase != .active { model.persistImmediately() }
                }
                .onReceive(NotificationCenter.default.publisher(
                    for: NSApplication.willTerminateNotification
                )) { _ in
                    model.persistImmediately()
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Task") { model.newConversation() }
                    .keyboardShortcut("n")
                Button("New Task Tab") { model.newConversation() }
                    .keyboardShortcut("t")
                Button("New Workspace") { model.addFolder() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Divider()
                Button("Close Task Tab") {
                    if let id = model.selectedConversationID { model.closeTab(id) }
                }
                .keyboardShortcut("w")
                .disabled(model.selectedConversationID == nil)
            }
            CommandMenu("Task") {
                Button(model.modelPhase == .generating || model.modelPhase == .compacting ? "Stop Generating" : "Focus Message") {
                    if model.modelPhase == .generating || model.modelPhase == .compacting { model.stop() }
                }
                .keyboardShortcut(model.modelPhase == .generating || model.modelPhase == .compacting ? .escape : "l")
                Button("Task Inspector") { model.showInspector.toggle() }
                    .keyboardShortcut("i", modifiers: [.command, .option])
            }
        }
    }
}
