import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            WebSearchSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }

            AcknowledgmentsView()
                .tabItem { Label("Acknowledgments", systemImage: "doc.text") }
        }
    }
}

private struct WebSearchSettingsView: View {
    @AppStorage(AppPreferences.allowWebSearchByDefaultKey)
    private var allowWebSearchByDefault = false

    var body: some View {
        Form {
            Section("Web Search") {
                Toggle("Allow web searches without asking", isOn: $allowWebSearchByDefault)
                Text("Search terms are sent to api.duckduckgo.com. Turn this off to approve each search before any data leaves this Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 520, height: 220)
    }
}
