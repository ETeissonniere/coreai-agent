import CoreAILanguageModels
import Foundation
import FoundationModels
import OSLog

enum TitleGenerationFailure: Equatable, Sendable {
    case assetMissing
    case modelLoadFailed
    case generationFailed
    case invalidOutput

    var userMessage: String {
        switch self {
        case .assetMissing:
            "The bundled title model is missing. Using the first message as the title."
        case .modelLoadFailed:
            "The title model could not be loaded. Using the first message as the title."
        case .generationFailed, .invalidOutput:
            "A title could not be generated. Using the first message as the title."
        }
    }
}

enum TitleGenerationResult: Equatable, Sendable {
    case generated(String)
    case fallback(TitleGenerationFailure)
}

protocol TitleGenerating: Sendable {
    func generateTitle(for firstMessage: String) async -> TitleGenerationResult
}

actor TitleModelService: TitleGenerating {
    typealias GenerationOverride = @Sendable (String) async throws -> String

    private static let logger = Logger(
        subsystem: "com.eliottteissonniere.CoreAIAgent",
        category: "TitleModel"
    )

    private let resourcesURL: URL?
    private let generationOverride: GenerationOverride?
    private var model: CoreAILanguageModel?

    init(resourcesURL: URL?, generationOverride: GenerationOverride? = nil) {
        self.resourcesURL = resourcesURL
        self.generationOverride = generationOverride
    }

    func generateTitle(for firstMessage: String) async -> TitleGenerationResult {
        guard let resourcesURL else {
            Self.logger.error("Bundled title-model assets were not found")
            return .fallback(.assetMissing)
        }

        if let generationOverride {
            do {
                return Self.result(from: try await generationOverride(firstMessage))
            } catch {
                Self.logger.error("Title generation failed: \(error.localizedDescription, privacy: .public)")
                return .fallback(.generationFailed)
            }
        }

        let loadedModel: CoreAILanguageModel
        do {
            if let model {
                loadedModel = model
            } else {
                loadedModel = try await CoreAILanguageModel(resourcesAt: resourcesURL)
                model = loadedModel
            }
        } catch {
            Self.logger.error(
                "Bundled title model failed to load from \(resourcesURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return .fallback(.modelLoadFailed)
        }

        do {
            let session = LanguageModelSession(model: loadedModel, instructions: """
                Create a short conversation title from the user's first message. \
                Use 2 to 6 words. Preserve the user's language. Return only the title, \
                without quotes, Markdown, punctuation at the end, or reasoning.
                """)
            let response = try await session.respond(
                to: "User message:\n\(firstMessage)",
                options: GenerationOptions(maximumResponseTokens: 20)
            ).content
            return Self.result(from: response)
        } catch {
            Self.logger.error("Title generation failed: \(error.localizedDescription, privacy: .public)")
            return .fallback(.generationFailed)
        }
    }

    private static func result(from generated: String) -> TitleGenerationResult {
        guard let title = clean(generated) else {
            logger.error("Title model returned no usable title")
            return .fallback(.invalidOutput)
        }
        logger.debug("Generated a conversation title with the bundled title model")
        return .generated(title)
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
