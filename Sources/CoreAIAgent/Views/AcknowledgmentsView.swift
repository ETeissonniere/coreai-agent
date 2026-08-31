import SwiftUI

struct AcknowledgmentsView: View {
    private let documents = BundledAcknowledgments.load()

    var body: some View {
        NavigationSplitView {
            List(documents) { document in
                NavigationLink(document.title, value: document.id)
            }
            .navigationTitle("Acknowledgments")
        } detail: {
            if let document = documents.first {
                AcknowledgmentDocumentView(document: document)
            } else {
                ContentUnavailableView(
                    "Acknowledgments Unavailable",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("The packaged license resources could not be found.")
                )
            }
        }
        .navigationDestination(for: String.self) { id in
            if let document = documents.first(where: { $0.id == id }) {
                AcknowledgmentDocumentView(document: document)
            }
        }
        .frame(minWidth: 720, minHeight: 520)
    }
}

private struct AcknowledgmentDocumentView: View {
    let document: BundledAcknowledgment

    var body: some View {
        ScrollView {
            Text(document.contents)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
        }
        .navigationTitle(document.title)
    }
}

struct BundledAcknowledgment: Identifiable, Equatable {
    let id: String
    let title: String
    let contents: String
}

enum BundledAcknowledgments {
    private static let resources: [(directory: String, name: String, title: String)] = [
        (
            "ThirdPartyNotices",
            "Nemotron-3-Nano-4B-NOTICE.txt",
            "NVIDIA Nemotron 3 Nano 4B Notice"
        ),
        (
            "ThirdPartyLicenses",
            "NVIDIA-Nemotron-Open-Model-License.txt",
            "NVIDIA Nemotron Open Model License"
        ),
        (
            "ModelProvenance",
            "Nemotron-3-Nano-4B-CoreAI.json",
            "Nemotron 3 Nano 4B Provenance"
        ),
    ]

    static func load(bundle: Bundle = .main) -> [BundledAcknowledgment] {
        resources.compactMap { resource in
            guard let url = bundle.url(
                forResource: resource.name,
                withExtension: nil,
                subdirectory: resource.directory
            ), let contents = try? String(contentsOf: url, encoding: .utf8) else {
                return nil
            }
            return BundledAcknowledgment(id: resource.name, title: resource.title, contents: contents)
        }
    }
}
