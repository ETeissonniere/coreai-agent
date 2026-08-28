import Foundation
import FoundationModels

@Generable(description: "Text whose characters should be counted")
public struct CharacterCountArguments: Sendable, Equatable {
    @Guide(description: "The exact text to count")
    public var text: String

    public init(text: String) {
        self.text = text
    }
}

public enum CharacterCountToolError: Error, LocalizedError, Equatable {
    case inputTooLarge(maximumCharacters: Int)

    public var errorDescription: String? {
        switch self {
        case .inputTooLarge(let maximumCharacters):
            "The text exceeds the tool limit of \(maximumCharacters) characters."
        }
    }
}

public struct CharacterCountTool: Tool {
    public let name = "countCharacters"
    public let description = "Counts the characters in text exactly."
    public let maximumCharacters: Int

    public init(maximumCharacters: Int = 16_384) {
        self.maximumCharacters = maximumCharacters
    }

    public func call(arguments: CharacterCountArguments) async throws -> String {
        try Task.checkCancellation()
        guard arguments.text.count <= maximumCharacters else {
            throw CharacterCountToolError.inputTooLarge(maximumCharacters: maximumCharacters)
        }
        return "Character count: \(arguments.text.count)"
    }
}
