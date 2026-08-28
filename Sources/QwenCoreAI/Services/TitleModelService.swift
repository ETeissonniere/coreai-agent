import CoreAILanguageModels
import Foundation
import FoundationModels

actor TitleModelService {
    private let resourcesURL: URL?
    private var model: CoreAILanguageModel?

    init(resourcesURL: URL?) {
        self.resourcesURL = resourcesURL
    }

    func generateTitle(for firstMessage: String) async -> String? {
        guard let resourcesURL else { return nil }
        do {
            let loadedModel: CoreAILanguageModel
            if let model {
                loadedModel = model
            } else {
                loadedModel = try await CoreAILanguageModel(resourcesAt: resourcesURL)
                model = loadedModel
            }

            let session = LanguageModelSession(model: loadedModel, instructions: """
                Create a short conversation title from the user's first message. \
                Use 2 to 6 words. Preserve the user's language. Return only the title, \
                without quotes, Markdown, punctuation at the end, or reasoning.
                """)
            let response = try await session.respond(
                to: "User message:\n\(firstMessage)",
                options: GenerationOptions(maximumResponseTokens: 20)
            ).content
            return Self.clean(response)
        } catch {
            return nil
        }
    }

    static func clean(_ generated: String) -> String? {
        let firstLine = generated
            .replacingOccurrences(of: "</think>", with: "")
            .split(whereSeparator: \.isNewline)
            .last
            .map(String.init) ?? generated
        let title = firstLine
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\r\"'`#*.:;!?—–-"))
        guard !title.isEmpty else { return nil }
        return String(title.prefix(72))
    }
}
